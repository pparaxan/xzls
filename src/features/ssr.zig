const std = @import("std");
const Ast = std.zig.Ast;
const DocumentStore = @import("../DocumentStore.zig");
const offsets = @import("../offsets.zig");
const Uri = @import("../Uri.zig");
const lsp = @import("lsp");
const types = lsp.types;

pub const SsrParams = struct {
    query: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
    replacement: ?[]const u8 = null,
    uri: ?[]const u8 = null,
};

pub const ParsedQuery = struct {
    pattern: []const u8,
    replacement: []const u8,
};

pub fn parseQuery(arena: std.mem.Allocator, raw: []const u8) !ParsedQuery {
    const delim = "==>>";
    if (std.mem.indexOf(u8, raw, delim)) |idx| {
        const pat = std.mem.trim(u8, raw[0..idx], " \t\r\n");
        const repl = std.mem.trim(u8, raw[idx + delim.len ..], " \t\r\n");
        return .{
            .pattern = try arena.dupe(u8, pat),
            .replacement = try arena.dupe(u8, repl),
        };
    }
    return error.MissingDelimiter;
}

pub fn normalizePattern(arena: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] == '$' and i + 1 < pattern.len and (std.ascii.isAlphabetic(pattern[i + 1]) or pattern[i + 1] == '_')) {
            const start = i + 1;
            var end = start;
            while (end < pattern.len and (std.ascii.isAlphanumeric(pattern[end]) or pattern[end] == '_')) {
                end += 1;
            }
            const var_name = pattern[start..end];
            try out.appendSlice(arena, "__xzls_ssr_");
            try out.appendSlice(arena, var_name);
            try out.appendSlice(arena, "__");
            i = end;
        } else {
            try out.append(arena, pattern[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

pub fn parsePattern(arena: std.mem.Allocator, normalized: []const u8) !struct { Ast, Ast.Node.Index } {
    // 1. Try wrapping as expression: fn __ssr__() void { _ = <expr>; }
    const wrapped_expr = try std.fmt.allocPrint(arena, "fn __ssr__() void {{ _ = {s}; }}\x00", .{normalized});
    var tree = try Ast.parse(arena, wrapped_expr[0 .. wrapped_expr.len - 1 :0], .{ .mode = .zig });
    if (tree.errors.len == 0) {
        for (1..tree.nodes.len) |idx| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
            if (tree.nodeTag(node) == .assign) {
                const data = tree.nodeData(node);
                return .{ tree, data.node_and_node[1] };
            }
        }
    }

    // 2. Try wrapping as statement: fn __ssr__() void { <stmt>; }
    const wrapped_stmt = try std.fmt.allocPrint(arena, "fn __ssr__() void {{\n{s};\n}}\x00", .{normalized});
    tree = try Ast.parse(arena, wrapped_stmt[0 .. wrapped_stmt.len - 1 :0], .{ .mode = .zig });
    if (tree.errors.len == 0) {
        for (1..tree.nodes.len) |idx| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(idx));
            const tag = tree.nodeTag(node);
            if (tag != .fn_proto_simple and tag != .fn_decl and tag != .block_two and tag != .block) {
                return .{ tree, node };
            }
        }
    }

    // 3. Fallback: parse raw as top-level declarations
    const raw_null_term = try std.fmt.allocPrint(arena, "{s}\x00", .{normalized});
    tree = try Ast.parse(arena, raw_null_term[0 .. raw_null_term.len - 1 :0], .{ .mode = .zig });
    const root_decls = tree.rootDecls();
    if (root_decls.len > 0) {
        return .{ tree, root_decls[0] };
    }
    return error.InvalidPattern;
}

const Bindings = std.StringHashMapUnmanaged([]const u8);

fn isWildcard(pat_tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    if (pat_tree.nodeTag(node) != .identifier) return null;
    const token = pat_tree.nodeMainToken(node);
    const slice = pat_tree.tokenSlice(token);
    const prefix = "__xzls_ssr_";
    const suffix = "__";
    if (slice.len > prefix.len + suffix.len and std.mem.startsWith(u8, slice, prefix) and std.mem.endsWith(u8, slice, suffix)) {
        return slice[prefix.len .. slice.len - suffix.len];
    }
    return null;
}

fn matchNodes(
    arena: std.mem.Allocator,
    pat_tree: *const Ast,
    pat_node: Ast.Node.Index,
    tgt_tree: *const Ast,
    tgt_node: Ast.Node.Index,
    bindings: *Bindings,
) error{OutOfMemory}!bool {
    if (isWildcard(pat_tree, pat_node)) |var_name| {
        const tgt_slice = offsets.nodeToSlice(tgt_tree, tgt_node);
        if (bindings.get(var_name)) |existing| {
            return std.mem.eql(u8, existing, tgt_slice);
        }
        try bindings.put(arena, var_name, tgt_slice);
        return true;
    }

    var actual_pat = pat_node;
    while (pat_tree.nodeTag(actual_pat) == .grouped_expression) {
        actual_pat = pat_tree.nodeData(actual_pat).node_and_token[0];
    }
    var actual_tgt = tgt_node;
    while (tgt_tree.nodeTag(actual_tgt) == .grouped_expression) {
        actual_tgt = tgt_tree.nodeData(actual_tgt).node_and_token[0];
    }

    const pat_tag = pat_tree.nodeTag(actual_pat);
    const tgt_tag = tgt_tree.nodeTag(actual_tgt);

    // Call matching: normalize call, call_one, call_comma, call_one_comma
    const pat_is_call = pat_tag == .call or pat_tag == .call_comma or pat_tag == .call_one or pat_tag == .call_one_comma;
    const tgt_is_call = tgt_tag == .call or tgt_tag == .call_comma or tgt_tag == .call_one or tgt_tag == .call_one_comma;
    if (pat_is_call or tgt_is_call) {
        if (!pat_is_call or !tgt_is_call) return false;
        var pbuf: [1]Ast.Node.Index = undefined;
        var tbuf: [1]Ast.Node.Index = undefined;
        const pcall = pat_tree.fullCall(&pbuf, actual_pat) orelse return false;
        const tcall = tgt_tree.fullCall(&tbuf, actual_tgt) orelse return false;
        if (!try matchNodes(arena, pat_tree, pcall.ast.fn_expr, tgt_tree, tcall.ast.fn_expr, bindings)) return false;
        if (pcall.ast.params.len != tcall.ast.params.len) return false;
        for (pcall.ast.params, tcall.ast.params) |pparam, tparam| {
            if (!try matchNodes(arena, pat_tree, pparam, tgt_tree, tparam, bindings)) return false;
        }
        return true;
    }

    if (pat_tag != tgt_tag) return false;

    switch (pat_tag) {
        .identifier => {
            const ptoken = pat_tree.nodeMainToken(actual_pat);
            const ttoken = tgt_tree.nodeMainToken(actual_tgt);
            return std.mem.eql(u8, pat_tree.tokenSlice(ptoken), tgt_tree.tokenSlice(ttoken));
        },
        .number_literal, .string_literal, .char_literal, .enum_literal => {
            const ptoken = pat_tree.nodeMainToken(actual_pat);
            const ttoken = tgt_tree.nodeMainToken(actual_tgt);
            return std.mem.eql(u8, pat_tree.tokenSlice(ptoken), tgt_tree.tokenSlice(ttoken));
        },
        .field_access => {
            const pdata = pat_tree.nodeData(actual_pat);
            const tdata = tgt_tree.nodeData(actual_tgt);
            const pfield = pat_tree.tokenSlice(pdata.node_and_token[1]);
            const tfield = tgt_tree.tokenSlice(tdata.node_and_token[1]);
            if (!std.mem.eql(u8, pfield, tfield)) return false;
            return try matchNodes(arena, pat_tree, pdata.node_and_token[0], tgt_tree, tdata.node_and_token[0], bindings);
        },
        .unwrap_optional => {
            const pdata = pat_tree.nodeData(actual_pat);
            const tdata = tgt_tree.nodeData(actual_tgt);
            return try matchNodes(arena, pat_tree, pdata.node_and_token[0], tgt_tree, tdata.node_and_token[0], bindings);
        },
        .bool_not, .negation, .bit_not, .negation_wrap, .address_of, .@"try", .optional_type => {
            const pdata = pat_tree.nodeData(actual_pat);
            const tdata = tgt_tree.nodeData(actual_tgt);
            return try matchNodes(arena, pat_tree, pdata.node, tgt_tree, tdata.node, bindings);
        },
        .equal_equal,
        .bang_equal,
        .less_than,
        .greater_than,
        .less_or_equal,
        .greater_or_equal,
        .add,
        .sub,
        .mul,
        .div,
        .mod,
        .add_wrap,
        .sub_wrap,
        .mul_wrap,
        .add_sat,
        .sub_sat,
        .mul_sat,
        .shl,
        .shr,
        .shl_sat,
        .bit_and,
        .bit_xor,
        .bit_or,
        .bool_and,
        .bool_or,
        .array_cat,
        .merge_error_sets,
        .assign,
        .assign_add,
        .assign_sub,
        .assign_mul,
        .assign_div,
        .assign_mod,
        => {
            const pdata = pat_tree.nodeData(actual_pat);
            const tdata = tgt_tree.nodeData(actual_tgt);
            if (!try matchNodes(arena, pat_tree, pdata.node_and_node[0], tgt_tree, tdata.node_and_node[0], bindings)) return false;
            return try matchNodes(arena, pat_tree, pdata.node_and_node[1], tgt_tree, tdata.node_and_node[1], bindings);
        },
        else => {
            const pslice = offsets.nodeToSlice(pat_tree, actual_pat);
            const tslice = offsets.nodeToSlice(tgt_tree, actual_tgt);
            return std.mem.eql(u8, pslice, tslice);
        },
    }
}

pub fn substituteReplacement(
    arena: std.mem.Allocator,
    template: []const u8,
    bindings: *const Bindings,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '$' and i + 1 < template.len and (std.ascii.isAlphabetic(template[i + 1]) or template[i + 1] == '_')) {
            const start = i + 1;
            var end = start;
            while (end < template.len and (std.ascii.isAlphanumeric(template[end]) or template[end] == '_')) {
                end += 1;
            }
            const var_name = template[start..end];
            if (bindings.get(var_name)) |val| {
                try out.appendSlice(arena, val);
            } else {
                try out.append(arena, '$');
                try out.appendSlice(arena, var_name);
            }
            i = end;
        } else {
            try out.append(arena, template[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

pub fn searchAndReplaceDocument(
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    pat_tree: *const Ast,
    pat_root: Ast.Node.Index,
    replacement_template: []const u8,
    offset_encoding: offsets.Encoding,
) ![]const types.TextEdit {
    var edits: std.ArrayList(types.TextEdit) = .empty;
    var matched_ranges: std.ArrayList(offsets.Loc) = .empty;

    const tgt_tree = &handle.tree;

    for (1..tgt_tree.nodes.len) |node_idx| {
        const tgt_node: Ast.Node.Index = @fromBackingInt(@intCast(node_idx));
        const tgt_loc = offsets.nodeToLoc(tgt_tree, tgt_node);

        var already_covered = false;
        for (matched_ranges.items) |range| {
            if (tgt_loc.start >= range.start and tgt_loc.end <= range.end) {
                already_covered = true;
                break;
            }
        }
        if (already_covered) continue;

        var bindings: Bindings = .empty;
        if (try matchNodes(arena, pat_tree, pat_root, tgt_tree, tgt_node, &bindings)) {
            const new_text = try substituteReplacement(arena, replacement_template, &bindings);
            const range = offsets.nodeToRange(tgt_tree, tgt_node, offset_encoding);
            try edits.append(arena, .{
                .range = range,
                .newText = new_text,
            });
            try matched_ranges.append(arena, tgt_loc);
        }
    }

    return edits.toOwnedSlice(arena);
}

pub fn performSsr(
    arena: std.mem.Allocator,
    store: *DocumentStore,
    params: SsrParams,
    offset_encoding: offsets.Encoding,
) !types.WorkspaceEdit {
    const parsed = if (params.query) |q|
        try parseQuery(arena, q)
    else if (params.pattern != null and params.replacement != null)
        ParsedQuery{ .pattern = params.pattern.?, .replacement = params.replacement.? }
    else
        return error.InvalidParams;

    const normalized_pat = try normalizePattern(arena, parsed.pattern);
    const pat_tree, const pat_root = try parsePattern(arena, normalized_pat);

    var workspace_edit: types.WorkspaceEdit = .{ .changes = .{} };

    if (params.uri) |target_uri_str| {
        const uri = Uri.parse(arena, target_uri_str) catch return workspace_edit;
        if (store.getHandle(uri)) |handle| {
            const edits = try searchAndReplaceDocument(arena, handle, &pat_tree, pat_root, parsed.replacement, offset_encoding);
            if (edits.len > 0) {
                try workspace_edit.changes.?.map.putNoClobber(arena, handle.uri.raw, edits);
            }
        }
    } else {
        var it: DocumentStore.HandleIterator = .{ .store = store };
        while (it.next()) |handle| {
            const edits = try searchAndReplaceDocument(arena, handle, &pat_tree, pat_root, parsed.replacement, offset_encoding);
            if (edits.len > 0) {
                try workspace_edit.changes.?.map.putNoClobber(arena, handle.uri.raw, edits);
            }
        }
    }

    return workspace_edit;
}

//! Implementation of [`textDocument/hover`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_hover)

const std = @import("std");
const Ast = std.zig.Ast;

const ast = @import("../ast.zig");
const types = @import("lsp").types;
const offsets = @import("../offsets.zig");
const tracy = @import("tracy");

const Analyser = @import("../analysis.zig");
const DocumentStore = @import("../DocumentStore.zig");
const Server = @import("../Server.zig");
const Uri = @import("../Uri.zig");

const data = @import("version_data");

pub const Error = Analyser.Error || error{InvalidParams};

test "keyword documentation comes from the language reference" {
    try std.testing.expectEqualStrings("The boolean operator `and`.", data.keywords.get("and").?);
    for (data.keywords.values()) |documentation| {
        try std.testing.expect(std.mem.indexOf(u8, documentation, "{#") == null);
    }
}

fn hoverSymbol(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    param_decl_handle: Analyser.DeclWithHandle,
    markup_kind: types.MarkupKind,
    show_memory_layout: bool,
) Analyser.Error!?[]const u8 {
    return try hoverSymbolWithType(analyser, arena, param_decl_handle, null, markup_kind, show_memory_layout);
}

fn hoverSymbolWithType(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    param_decl_handle: Analyser.DeclWithHandle,
    type_maybe: ?Analyser.Type,
    markup_kind: types.MarkupKind,
    show_memory_layout: bool,
) Analyser.Error!?[]const u8 {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var doc_strings: std.ArrayList([]const u8) = .empty;
    // Source byte positions of each doc comment's first token; used to resolve intra-doc links.
    var doc_string_positions: std.ArrayList(usize) = .empty;

    var decl_handle: Analyser.DeclWithHandle = param_decl_handle;
    var maybe_resolved_type = type_maybe orelse try param_decl_handle.resolveType(analyser);

    while (true) {
        if (try decl_handle.docCommentsAt(arena)) |dc| {
            try doc_strings.append(arena, dc.text);
            try doc_string_positions.append(arena, dc.source_pos);
        }
        decl_handle = try analyser.resolveVarDeclAlias(decl_handle) orelse break;
        maybe_resolved_type = maybe_resolved_type orelse try decl_handle.resolveType(analyser);
    }

    const tree = &decl_handle.handle.tree;
    var layout_comment: ?[]const u8 = null;
    if (show_memory_layout) {
        if (decl_handle.decl == .ast_node) {
            const node = decl_handle.decl.ast_node;
            switch (tree.nodeTag(node)) {
                .container_field, .container_field_init, .container_field_align => {
                    const field_name = offsets.tokenToSlice(tree, tree.nodeMainToken(node));
                    if (decl_handle.container_type) |ct| {
                        const offset = try Analyser.Type.computeFieldOffset(analyser, ct, field_name);
                        const fl = if (maybe_resolved_type) |t| try t.computeMemoryLayout(analyser) else null;
                        if (offset != null and fl != null) {
                            layout_comment = try arena.print("// offset: {d} bytes, size: {d} bytes, align: {d} bytes", .{ offset.?, fl.?.size, fl.?.alignment });
                        } else if (fl) |l| {
                            layout_comment = try arena.print("// size: {d} bytes, align: {d} bytes", .{ l.size, l.alignment });
                        }
                    }
                },
                .global_var_decl, .local_var_decl, .aligned_var_decl, .simple_var_decl => {
                    if (maybe_resolved_type) |t| {
                        if (try t.computeMemoryLayout(analyser)) |l| {
                            layout_comment = try arena.print("// size: {d} bytes, align: {d} bytes", .{ l.size, l.alignment });
                        }
                    }
                },
                else => {
                    if (maybe_resolved_type) |t| {
                        if (try t.computeMemoryLayout(analyser)) |l| {
                            layout_comment = try arena.print("// size: {d} bytes, align: {d} bytes", .{ l.size, l.alignment });
                        }
                    }
                },
            }
        } else if (maybe_resolved_type) |t| {
            if (try t.computeMemoryLayout(analyser)) |l| {
                layout_comment = try arena.print("// size: {d} bytes, align: {d} bytes", .{ l.size, l.alignment });
            }
        }
    }

    const def_str = switch (decl_handle.decl) {
        .ast_node => |node| switch (tree.nodeTag(node)) {
            .global_var_decl,
            .local_var_decl,
            .aligned_var_decl,
            .simple_var_decl,
            => if (tree.fullVarDecl(node)) |vd|
                try Analyser.getVariableSignature(arena, tree, vd, true)
            else
                offsets.nodeToSlice(tree, node),
            .container_field,
            .container_field_init,
            .container_field_align,
            => offsets.nodeToSlice(tree, node),
            .fn_proto,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto_simple,
            .fn_decl,
            => def: {
                var buf: [1]Ast.Node.Index = undefined;
                if (tree.fullFnProto(&buf, node)) |fn_proto| {
                    break :def try Analyser.getFunctionSignatureUnindented(arena, tree, fn_proto);
                } else {
                    break :def offsets.nodeToSlice(tree, node);
                }
            },
            else => offsets.nodeToSlice(tree, node),
        },
        .function_parameter => |payload| ast.paramSlice(tree, payload.get(tree).?, false),
        .optional_payload,
        .error_union_payload,
        .error_union_error,
        .for_loop_payload,
        .assign_destructure,
        .switch_payload,
        .switch_inline_tag_payload,
        .label,
        .error_token,
        => tree.tokenSlice(decl_handle.nameToken()),
    };

    return try hoverSymbolResolvedType(
        analyser,
        arena,
        def_str,
        layout_comment,
        markup_kind,
        &doc_strings,
        &doc_string_positions,
        maybe_resolved_type,
        decl_handle.handle,
    );
}

fn hoverSymbolResolvedType(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    def_str: []const u8,
    layout_comment_arg: ?[]const u8,
    markup_kind: types.MarkupKind,
    doc_strings: *std.ArrayList([]const u8),
    doc_string_positions: *std.ArrayList(usize),
    resolved_type_maybe: ?Analyser.Type,
    handle: ?*DocumentStore.Handle,
) error{OutOfMemory}!?[]const u8 {
    const layout_comment = layout_comment_arg;
    var referenced: Analyser.ReferencedType.Set = .empty;
    var resolved_type_strings: std.ArrayList([]const u8) = .empty;
    var has_more = false;
    if (resolved_type_maybe) |resolved_type| {
        if (try resolved_type.docComments(arena)) |doc| {
            try doc_strings.append(arena, doc);
            // For type-resolved doc comments we don't have a token position; use 0 as fallback.
            try doc_string_positions.append(arena, 0);
        }

        var possible_types: Analyser.Type.ArraySet = .empty;
        has_more = try resolved_type.getAllTypesWithHandlesArraySet(analyser, &possible_types);

        const options: Analyser.Type.FormatOptions = .{
            .referenced = &referenced,
            .truncate_container_decls = possible_types.count() > 1,
        };

        for (possible_types.keys()) |ty| {
            const type_str = try ty.stringifyTypeOf(analyser, options);

            if (ty.ipIndex() != null) {
                const val_str = try ty.stringifyTypeVal(analyser, options);
                const combined = try arena.print("{s} = {s}", .{ type_str, val_str });
                try resolved_type_strings.append(arena, combined);
            } else {
                try resolved_type_strings.append(arena, type_str);
            }
        }
    }
    const referenced_types: []const Analyser.ReferencedType = referenced.keys();
    return try hoverSymbolResolved(
        arena,
        markup_kind,
        doc_strings.items,
        doc_string_positions.items,
        def_str,
        layout_comment,
        resolved_type_strings.items,
        has_more,
        referenced_types,
        analyser,
        handle,
    );
}

fn formatDocLinks(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    doc: []const u8,
    comment_pos: usize,
) error{OutOfMemory}![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < doc.len) {
        if (doc[i] == '[') {
            const b_start = i;
            if (std.mem.indexOfScalar(u8, doc[b_start + 1 ..], ']')) |b_end_rel| {
                const full_b_end = b_start + 1 + b_end_rel;
                const bracket_content = doc[b_start + 1 .. full_b_end];
                var target_str = bracket_content;
                var file_path: ?[]const u8 = null;
                var link_end = full_b_end + 1;

                if (full_b_end + 1 < doc.len and doc[full_b_end + 1] == '(') {
                    const p_start = full_b_end + 1;
                    if (std.mem.indexOfScalar(u8, doc[p_start + 1 ..], ')')) |p_end_rel| {
                        const full_p_end = p_start + 1 + p_end_rel;
                        const paren_content = doc[p_start + 1 .. full_p_end];
                        link_end = full_p_end + 1;
                        const trimmed_p = std.mem.trim(u8, paren_content, " `\t\r");
                        if (std.mem.startsWith(u8, trimmed_p, "http://") or std.mem.startsWith(u8, trimmed_p, "https://")) {
                            try output.appendSlice(arena, doc[b_start..link_end]);
                            i = link_end;
                            continue;
                        }
                        if (std.mem.endsWith(u8, trimmed_p, ".zig") or std.mem.endsWith(u8, trimmed_p, ".zon")) {
                            file_path = trimmed_p;
                            target_str = bracket_content;
                        } else if (trimmed_p.len > 0) {
                            target_str = trimmed_p;
                        }
                    }
                }

                var clean = std.mem.trim(u8, target_str, " `\t\r");
                if (std.mem.endsWith(u8, clean, "()")) clean = clean[0 .. clean.len - 2];
                const label = std.mem.trim(u8, bracket_content, " `\t\r");

                if (clean.len > 0 or file_path != null) {
                    if (analyser.resolveDocCommentLinkWithFile(arena, handle, comment_pos, clean, file_path) catch null) |target_decl| {
                        const target_line = if (target_decl.decl == .ast_node and target_decl.decl.ast_node == @as(Ast.Node.Index, @fromBackingInt(@intCast(0))))
                            @as(u32, 1)
                        else
                            offsets.tokenToPosition(&target_decl.handle.tree, target_decl.nameToken(), .@"utf-8").line + 1;
                        try output.print(arena, "[{s}]({s}#L{d})", .{ label, target_decl.handle.uri.raw, target_line });
                        i = link_end;
                        continue;
                    }
                }
            }
        }
        try output.append(arena, doc[i]);
        i += 1;
    }
    return output.toOwnedSlice(arena);
}

fn stripReleaseAnnotations(arena: std.mem.Allocator, doc: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.indexOf(u8, doc, "[release]:") == null) return doc;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    var result: std.ArrayList([]const u8) = .empty;
    defer result.deinit(arena);
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "[release]:")) continue;
        try result.append(arena, line);
    }
    return try std.mem.join(arena, "\n", result.items);
}

fn hoverSymbolResolved(
    arena: std.mem.Allocator,
    markup_kind: types.MarkupKind,
    doc_strings: []const []const u8,
    doc_string_positions: []const usize,
    def_str: []const u8,
    layout_comment: ?[]const u8,
    resolved_type_strings: []const []const u8,
    has_more: bool,
    referenced_types: []const Analyser.ReferencedType,
    analyser: ?*Analyser,
    handle: ?*DocumentStore.Handle,
) error{OutOfMemory}![]const u8 {
    var output: std.ArrayList(u8) = .empty;

    if (markup_kind == .markdown) {
        if (layout_comment) |comment| {
            try output.print(arena, "```zig\n{s}\n{s}\n```", .{ comment, def_str });
        } else {
            try output.print(arena, "```zig\n{s}\n```", .{def_str});
        }
        for (resolved_type_strings) |resolved_type_str|
            try output.print(arena, "\n```zig\n({s})\n```", .{resolved_type_str});
        if (resolved_type_strings.len == 0)
            try output.appendSlice(arena, "\n```zig\n(unknown)\n```");
        if (has_more)
            try output.print(arena, "\n```txt\n(...)\n```", .{});
        if (referenced_types.len > 0)
            try output.print(arena, "\n\n" ++ "Go to ", .{});
        for (referenced_types, 0..) |ref, index| {
            if (index > 0)
                try output.print(arena, " | ", .{});
            const source_index = ref.handle.tree.tokenStart(ref.token);
            const line = 1 + std.mem.count(u8, ref.handle.tree.source[0..source_index], "\n");
            try output.print(arena, "[{s}]({s}#L{d})", .{ ref.str, ref.handle.uri.raw, line });
        }
    } else {
        if (layout_comment) |comment| {
            try output.print(arena, "{s}\n{s}", .{ comment, def_str });
        } else {
            try output.print(arena, "{s}", .{def_str});
        }
        for (resolved_type_strings) |resolved_type_str|
            try output.print(arena, "\n({s})", .{resolved_type_str});
        if (resolved_type_strings.len == 0)
            try output.appendSlice(arena, "\n(unknown)");
        if (has_more)
            try output.print(arena, "\n(...)", .{});
    }

    if (doc_strings.len > 0) {
        try output.appendSlice(arena, "\n\n");
        for (doc_strings, 0..) |raw_doc, i| {
            const stripped_doc = try stripReleaseAnnotations(arena, raw_doc);
            if (stripped_doc.len == 0) continue;
            // Use the recorded source position when available; fall back to 0 for type-resolved docs.
            const pos = if (i < doc_string_positions.len) doc_string_positions[i] else 0;
            const formatted_doc = if (markup_kind == .markdown and analyser != null and handle != null)
                try formatDocLinks(analyser.?, arena, handle.?, stripped_doc, pos)
            else
                stripped_doc;
            try output.appendSlice(arena, formatted_doc);
            if (i != doc_strings.len - 1) try output.appendSlice(arena, "\n\n");
        }
    }

    return output.items;
}

fn hoverDefinitionLabel(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    pos_index: usize,
    loc: offsets.Loc,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
    show_memory_layout: bool,
) Analyser.Error!?types.Hover {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const name = offsets.locToSlice(handle.tree.source, loc);
    const decl = (try Analyser.lookupLabel(handle, name, pos_index)) orelse return null;

    return .{
        .contents = .{
            .markup_content = .{
                .kind = markup_kind,
                .value = (try hoverSymbol(analyser, arena, decl, markup_kind, show_memory_layout)) orelse return null,
            },
        },
        .range = offsets.locToRange(handle.tree.source, loc, offset_encoding),
    };
}

fn hoverDefinitionBuiltin(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    name_loc: offsets.Loc,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
) error{OutOfMemory}!?types.Hover {
    _ = analyser;
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const name = offsets.locToSlice(handle.tree.source, name_loc);

    var contents: std.ArrayList(u8) = .empty;

    const builtin = data.builtins.get(name) orelse return null;
    const signature = try Analyser.renderBuiltinFunctionSignature(
        arena,
        name,
        builtin,
        builtin.parameters.len > 3,
    );

    switch (markup_kind) {
        .plaintext, .unknown_value => {
            try contents.print(arena,
                \\{s}
                \\{s}
            , .{ signature, builtin.documentation });
        },
        .markdown => {
            try contents.print(arena,
                \\```zig
                \\{s}
                \\```
                \\{s}
            , .{ signature, builtin.documentation });
        },
    }

    return .{
        .contents = .{
            .markup_content = .{
                .kind = markup_kind,
                .value = contents.items,
            },
        },
        .range = offsets.locToRange(handle.tree.source, name_loc, offset_encoding),
    };
}

fn hoverDefinitionGlobal(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    pos_index: usize,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
    show_memory_layout: bool,
) Analyser.Error!?types.Hover {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const name_token, const name_loc = offsets.identifierTokenAndLocFromIndex(&handle.tree, pos_index) orelse return null;
    const name = offsets.locToSlice(handle.tree.source, name_loc);
    const hover_text = blk: {
        const is_escaped_identifier = handle.tree.source[handle.tree.tokenStart(name_token)] == '@';
        if (!is_escaped_identifier) {
            if (std.mem.eql(u8, name, "_")) return null;
            if (try analyser.resolvePrimitive(name)) |ip_index| {
                const resolved_type_str = try arena.print("{f}", .{analyser.ip.typeOf(ip_index).fmt(analyser.ip)});
                break :blk try hoverSymbolResolved(arena, markup_kind, &.{}, &.{}, name, null, &.{resolved_type_str}, false, &.{}, null, null);
            }
        }
        const decl = (try analyser.lookupSymbolGlobal(handle, name, pos_index)) orelse return null;
        break :blk (try hoverSymbol(analyser, arena, decl, markup_kind, show_memory_layout)) orelse return null;
    };

    return .{
        .contents = .{
            .markup_content = .{
                .kind = markup_kind,
                .value = hover_text,
            },
        },
        .range = offsets.tokenToRange(&handle.tree, name_token, offset_encoding),
    };
}

fn hoverDefinitionStructInit(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    source_index: usize,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
) Analyser.Error!?types.Hover {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const token = offsets.sourceIndexToTokenIndex(&handle.tree, source_index).pickPreferred(&.{.period}, &handle.tree) orelse return null;
    if (token + 1 >= handle.tree.tokens.len) return null;
    if (handle.tree.tokenTag(token + 1) != .l_brace) return null;

    const resolved_type = try analyser.resolveStructInitType(handle, source_index) orelse return null;

    var doc_strings: std.ArrayList([]const u8) = .empty;
    if (try resolved_type.docComments(arena)) |doc|
        try doc_strings.append(arena, doc);

    var referenced: Analyser.ReferencedType.Set = .empty;
    const def_str = try resolved_type.stringifyTypeOf(analyser, .{
        .referenced = &referenced,
        .truncate_container_decls = false,
    });
    const referenced_types: []const Analyser.ReferencedType = referenced.keys();

    return .{
        .contents = .{
            .markup_content = .{
                .kind = markup_kind,
                .value = try hoverSymbolResolved(arena, markup_kind, doc_strings.items, &.{}, def_str, null, &.{"type"}, false, referenced_types, analyser, handle),
            },
        },
        .range = offsets.tokenToRange(&handle.tree, token, offset_encoding),
    };
}

fn hoverDefinitionEnumLiteral(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    source_index: usize,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
    show_memory_layout: bool,
) Analyser.Error!?types.Hover {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const name_token, const name_loc = offsets.identifierTokenAndLocFromIndex(&handle.tree, source_index) orelse {
        return try hoverDefinitionStructInit(analyser, arena, handle, source_index, markup_kind, offset_encoding);
    };
    const name = offsets.locToSlice(handle.tree.source, name_loc);
    const decl, const type_maybe = (try analyser.getSymbolEnumLiteral(handle, source_index, name)) orelse return null;

    return .{
        .contents = .{
            .markup_content = .{
                .kind = markup_kind,
                .value = (try hoverSymbolWithType(analyser, arena, decl, type_maybe, markup_kind, show_memory_layout)) orelse return null,
            },
        },
        .range = offsets.tokenToRange(&handle.tree, name_token, offset_encoding),
    };
}

fn hoverDefinitionFieldAccess(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    source_index: usize,
    loc: offsets.Loc,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
    show_memory_layout: bool,
) Analyser.Error!?types.Hover {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var decls: std.ArrayList(Analyser.DeclWithHandle) = .empty;
    var tys: std.ArrayList(Analyser.Type) = .empty;
    const highlight_loc = try analyser.getSymbolFieldAccessesHighlight(arena, handle, source_index, loc, &decls, &tys) orelse return null;

    var content: std.ArrayList([]const u8) = try .initCapacity(arena, decls.items.len + tys.items.len);

    for (decls.items) |decl| {
        content.appendAssumeCapacity(try hoverSymbol(analyser, arena, decl, markup_kind, show_memory_layout) orelse continue);
    }
    for (tys.items) |ty| {
        const def_str = offsets.locToSlice(handle.tree.source, highlight_loc);
        var doc_strings: std.ArrayList([]const u8) = .empty;
        var doc_string_positions: std.ArrayList(usize) = .empty;
        content.appendAssumeCapacity(try hoverSymbolResolvedType(analyser, arena, def_str, null, markup_kind, &doc_strings, &doc_string_positions, ty, handle) orelse continue);
    }

    return .{
        .contents = .{ .markup_content = .{
            .kind = markup_kind,
            .value = switch (content.items.len) {
                0 => return null,
                1 => content.items[0],
                else => try std.mem.join(arena, "\n\n", content.items),
            },
        } },
        .range = offsets.locToRange(handle.tree.source, highlight_loc, offset_encoding),
    };
}

fn hoverNumberLiteral(
    handle: *DocumentStore.Handle,
    token_index: Ast.TokenIndex,
    arena: std.mem.Allocator,
    markup_kind: types.MarkupKind,
) error{OutOfMemory}!?[]const u8 {
    const tree = &handle.tree;
    // number literals get tokenized separately from their minus sign
    const is_negative = tree.tokenTag(token_index -| 1) == .minus;
    const num_slice = tree.tokenSlice(token_index);
    const number = blk: {
        if (tree.tokenTag(token_index) == .char_literal) {
            switch (std.zig.parseCharLiteral(num_slice)) {
                .success => |value| break :blk value,
                else => return null,
            }
        }
        switch (std.zig.parseNumberLiteral(num_slice)) {
            .int => |value| break :blk value,
            else => return null,
        }
    };

    switch (markup_kind) {
        .markdown => return try arena.print(
            \\| Base | {[value]s:<[count]} |
            \\| ---- | {[dash]s:-<[count]} |
            \\| BIN  | {[sign]s}0b{[number]b:<[len]} |
            \\| OCT  | {[sign]s}0o{[number]o:<[len]} |
            \\| DEC  | {[sign]s}{[number]d:<[len]}   |
            \\| HEX  | {[sign]s}0x{[number]X:<[len]} |
        , .{
            .sign = if (is_negative) "-" else "",
            .dash = "-",
            .value = "Value",
            .number = number,
            .count = @max(@bitSizeOf(@TypeOf(number)) - @clz(number) + "0x".len + @intFromBool(is_negative), "Value".len),
            .len = @max(@bitSizeOf(@TypeOf(number)) - @clz(number), "Value".len - "0x".len),
        }),
        .plaintext, .unknown_value => return try arena.print(
            \\BIN: {[sign]s}0b{[number]b}
            \\OCT: {[sign]s}0o{[number]o}
            \\DEC: {[sign]s}{[number]d}
            \\HEX: {[sign]s}0x{[number]X}
        ,
            .{ .sign = if (is_negative) "-" else "", .number = number },
        ),
    }
}

fn hoverDefinitionNumberLiteral(
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    source_index: usize,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
) error{OutOfMemory}!?types.Hover {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const tree = &handle.tree;
    const token_index = offsets.sourceIndexToTokenIndex(tree, source_index).pickPreferred(&.{ .number_literal, .char_literal }, tree) orelse return null;
    const num_loc = offsets.tokenToLoc(tree, token_index);
    const hover_text = (try hoverNumberLiteral(handle, token_index, arena, markup_kind)) orelse return null;

    return .{
        .contents = .{ .markup_content = .{
            .kind = markup_kind,
            .value = hover_text,
        } },
        .range = offsets.locToRange(handle.tree.source, num_loc, offset_encoding),
    };
}

fn hoverZon(
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    source_index: usize,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
) !?types.Hover {
    const is_build_zon = std.mem.endsWith(u8, handle.uri.raw, "build.zig.zon");
    const source = handle.tree.source;
    if (source_index >= source.len) return null;

    var start = source_index;
    while (start > 0 and (std.ascii.isAlphanumeric(source[start - 1]) or source[start - 1] == '_')) : (start -= 1) {}
    var end = source_index;
    while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '_')) : (end += 1) {}

    if (start >= end) return null;
    const word = source[start..end];

    const doc: []const u8 = if (is_build_zon) blk: {
        if (std.mem.eql(u8, word, "name")) {
            break :blk "### `name` (Enum literal. Required)\n\nThis is the default name used by packages depending on this one. For example, when a user runs `zig fetch --save <url>`, this field is used to name the dependency.";
        } else if (std.mem.eql(u8, word, "version")) {
            break :blk "### `version` (String literal. Required)\n\nThe semantic version of this package. Package versions must follow the [SemVer 2.0](https://semver.org) specification.";
        } else if (std.mem.eql(u8, word, "fingerprint")) {
            break :blk "### `fingerprint` (Integer literal. Optional)\n\nA 64-bit integer that uniquely identifies the package. It should be initialized to `0x0` when creating a new package. When `zig fetch` updates dependencies, it will replace this with a collision-resistant hash.";
        } else if (std.mem.eql(u8, word, "minimum_zig_version")) {
            break :blk "### `minimum_zig_version` (String literal. Optional)\n\nPackages that depend on this one will fail to build if their Zig version is less than this value.";
        } else if (std.mem.eql(u8, word, "dependencies")) {
            break :blk "### `dependencies` (Struct literal. Optional)\n\nPackages that are required to build this package. Each field represents a package name and points to a dependency struct containing `.url`, `.hash`, `.path`, or `.lazy`.";
        } else if (std.mem.eql(u8, word, "paths")) {
            break :blk "### `paths` (Array of strings. Required)\n\nSpecifies the set of files and directories that are included in this package. Only files listed here will be included in the package tarball and hashed.";
        } else if (std.mem.eql(u8, word, "url")) {
            break :blk "### `url` (String literal)\n\nThe URL where the package archive or git repository can be downloaded. Supports HTTP/HTTPS tarballs and git URLs.";
        } else if (std.mem.eql(u8, word, "hash")) {
            break :blk "### `hash` (String literal)\n\nThe expected multihash of the package contents. Ensures reproducible builds and prevents tampering.";
        } else if (std.mem.eql(u8, word, "path")) {
            break :blk "### `path` (String literal)\n\nRelative path to a local package dependency on disk instead of downloading from a URL.";
        } else if (std.mem.eql(u8, word, "lazy")) {
            break :blk "### `lazy` (Boolean literal)\n\nIf `true`, the dependency will only be downloaded/fetched when explicitly requested by `b.lazyDependency(...)`.";
        }
        return null;
    } else return null;

    const range = offsets.locToRange(source, .{ .start = start, .end = end }, offset_encoding);
    return types.Hover{
        .contents = .{
            .markup_content = .{
                .kind = markup_kind,
                .value = try arena.dupe(u8, doc),
            },
        },
        .range = range,
    };
}

pub fn @"textDocument/hover"(
    server: *Server,
    arena: std.mem.Allocator,
    request: types.Hover.Params,
) Error!?types.Hover {
    const document_uri = Uri.parse(arena, request.textDocument.uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };
    const handle = server.document_store.getHandle(document_uri) orelse return null;
    const source_index = offsets.positionToIndex(handle.tree.source, request.position, server.offset_encoding);
    const markup_kind: types.MarkupKind = if (server.client_capabilities.hover_supports_md) .markdown else .plaintext;

    if (handle.tree.mode == .zon) {
        return try hoverZon(arena, handle, source_index, markup_kind, server.offset_encoding);
    }

    var analyser = server.initAnalyser(arena, handle);
    defer analyser.deinit();

    return try hoverWithOptions(
        &analyser,
        arena,
        handle,
        source_index,
        markup_kind,
        server.offset_encoding,
        server.config_manager.config.hover_show_memory_layout,
    );
}

pub fn hover(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    source_index: usize,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
) Analyser.Error!?types.Hover {
    return hoverWithOptions(
        analyser,
        arena,
        handle,
        source_index,
        markup_kind,
        offset_encoding,
        false,
    );
}

pub fn hoverWithOptions(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    source_index: usize,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
    show_memory_layout: bool,
) Analyser.Error!?types.Hover {
    const old_resolve_number_literal_values = analyser.resolve_number_literal_values;
    analyser.resolve_number_literal_values = true;
    defer analyser.resolve_number_literal_values = old_resolve_number_literal_values;

    const keyword_token = offsets.sourceIndexToTokenIndex(&handle.tree, source_index).preferRight(&handle.tree);
    const keyword_loc = offsets.tokenToLoc(&handle.tree, keyword_token);
    if (source_index >= keyword_loc.start and source_index < keyword_loc.end) {
        if (data.keywords.get(offsets.locToSlice(handle.tree.source, keyword_loc))) |documentation| {
            return .{
                .contents = .{ .markup_content = .{ .kind = markup_kind, .value = documentation } },
                .range = offsets.locToRange(handle.tree.source, keyword_loc, offset_encoding),
            };
        }
    }

    const pos_context = try Analyser.getPositionContext(arena, &handle.tree, source_index, true);

    const response = switch (pos_context) {
        .builtin => |loc| try hoverDefinitionBuiltin(analyser, arena, handle, loc, markup_kind, offset_encoding),
        .var_access, .test_doctest_name => try hoverDefinitionGlobal(analyser, arena, handle, source_index, markup_kind, offset_encoding, show_memory_layout),
        .field_access => |loc| try hoverDefinitionFieldAccess(analyser, arena, handle, source_index, loc, markup_kind, offset_encoding, show_memory_layout),
        .label_access, .label_decl => |loc| try hoverDefinitionLabel(analyser, arena, handle, source_index, loc, markup_kind, offset_encoding, show_memory_layout),
        .enum_literal => try hoverDefinitionEnumLiteral(analyser, arena, handle, source_index, markup_kind, offset_encoding, show_memory_layout),
        .number_literal, .char_literal => try hoverDefinitionNumberLiteral(arena, handle, source_index, markup_kind, offset_encoding),
        .comment => try hoverDocCommentLink(analyser, arena, handle, source_index, markup_kind, offset_encoding, show_memory_layout),
        .import_string_literal => |loc| try hoverDefinitionImportString(analyser, arena, handle, loc, markup_kind, offset_encoding),
        else => null,
    };

    return response;
}

fn hoverDocCommentLink(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    source_index: usize,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
    show_memory_layout: bool,
) Analyser.Error!?types.Hover {
    const link_info = Analyser.getDocCommentLinkAt(handle.tree.source, source_index) orelse return null;
    const target_decl = (try analyser.resolveDocCommentLinkWithFile(arena, handle, source_index, link_info.target, link_info.file_path)) orelse return null;
    const hover_val = (try hoverSymbol(analyser, arena, target_decl, markup_kind, show_memory_layout)) orelse return null;
    return .{
        .contents = .{
            .markup_content = .{
                .kind = markup_kind,
                .value = hover_val,
            },
        },
        .range = offsets.locToRange(handle.tree.source, link_info.loc, offset_encoding),
    };
}

fn hoverDefinitionImportString(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    loc: offsets.Loc,
    markup_kind: types.MarkupKind,
    offset_encoding: offsets.Encoding,
) Analyser.Error!?types.Hover {
    const import_str = offsets.locToSlice(handle.tree.source, loc);
    const result = analyser.store.uriFromImportStr(arena, handle, import_str) catch return null;

    const target_uri = switch (result) {
        .one => |uri| uri,
        .many => |uris| if (uris.len > 0) uris[0] else return null,
        .none => return null,
    };

    const target_handle = (analyser.store.getOrLoadHandle(target_uri) catch return null) orelse return null;
    const target_tree = &target_handle.tree;

    const doc_comment = try Analyser.collectDocComments(arena, target_tree, 0, true);

    const file_path = target_uri.toFsPath(arena) catch target_uri.raw;
    const title = try arena.print("### Module `{s}`\n*{s}*", .{ import_str, file_path });

    const hover_content = if (doc_comment) |doc|
        try arena.print("{s}\n\n---\n{s}", .{ title, doc })
    else
        title;

    return .{
        .contents = .{
            .markup_content = .{
                .kind = markup_kind,
                .value = hover_content,
            },
        },
        .range = offsets.locToRange(handle.tree.source, loc, offset_encoding),
    };
}

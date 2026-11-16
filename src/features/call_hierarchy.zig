//! Implementation of LSP Call Hierarchy
//! (`textDocument/prepareCallHierarchy`, `callHierarchy/incomingCalls`, `callHierarchy/outgoingCalls`)

const std = @import("std");
const Ast = std.zig.Ast;

const types = @import("lsp").types;
const offsets = @import("../offsets.zig");
const ast = @import("../ast.zig");
const analysis = @import("../analysis.zig");
const references = @import("references.zig");
const Server = @import("../Server.zig");
const Analyser = @import("../analysis.zig");
const DocumentStore = @import("../DocumentStore.zig");
const Uri = @import("../Uri.zig");
const tracy = @import("tracy");

pub const Error = error{ OutOfMemory, Canceled, InvalidParams };

fn findEnclosingFunction(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    const node_loc = offsets.nodeToLoc(tree, node);
    var best_fn: ?Ast.Node.Index = null;
    var best_len: usize = std.math.maxInt(usize);

    for (0..tree.nodes.len) |idx| {
        const candidate: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        switch (tree.nodeTag(candidate)) {
            .fn_decl => {
                const fn_loc = offsets.nodeToLoc(tree, candidate);
                if (fn_loc.start <= node_loc.start and fn_loc.end >= node_loc.end) {
                    const len = fn_loc.end - fn_loc.start;
                    if (len < best_len) {
                        best_len = len;
                        best_fn = candidate;
                    }
                }
            },
            else => {},
        }
    }
    return best_fn;
}

fn createCallHierarchyItem(
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    fn_node: Ast.Node.Index,
    encoding: offsets.Encoding,
) error{OutOfMemory}!?types.call_hierarchy.Item {
    const tree = &handle.tree;
    var buf: [1]Ast.Node.Index = undefined;
    const fn_info = tree.fullFnProto(&buf, fn_node) orelse return null;
    const name_token = fn_info.name_token orelse return null;

    const name = offsets.identifierTokenToNameSlice(tree, name_token);
    const detail = analysis.getFunctionSignature(tree, fn_info);
    const loc = offsets.nodeToLoc(tree, fn_node);
    const sel_loc = offsets.tokenToLoc(tree, name_token);

    return types.call_hierarchy.Item{
        .name = try arena.dupe(u8, name),
        .kind = .Function,
        .detail = if (detail.len > 0) try arena.dupe(u8, detail) else null,
        .uri = handle.uri.raw,
        .range = offsets.locToRange(tree.source, loc, encoding),
        .selectionRange = offsets.locToRange(tree.source, sel_loc, encoding),
    };
}

pub fn @"textDocument/prepareCallHierarchy"(
    server: *Server,
    arena: std.mem.Allocator,
    request: types.call_hierarchy.PrepareParams,
) Error!?[]const types.call_hierarchy.Item {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const document_uri = Uri.parse(arena, request.textDocument.uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };
    const handle = server.document_store.getHandle(document_uri) orelse return null;
    if (handle.tree.mode == .zon) return null;

    const source_index = offsets.positionToIndex(handle.tree.source, request.position, server.offset_encoding);
    const tree = &handle.tree;

    // Check if cursor is directly on a function declaration or inside a function
    var fn_node: ?Ast.Node.Index = null;
    for (0..tree.nodes.len) |idx| {
        const candidate: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        switch (tree.nodeTag(candidate)) {
            .fn_decl, .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => {
                var buf: [1]Ast.Node.Index = undefined;
                if (tree.fullFnProto(&buf, candidate)) |fn_info| {
                    if (fn_info.name_token) |name_token| {
                        const name_loc = offsets.tokenToLoc(tree, name_token);
                        if (source_index >= name_loc.start and source_index <= name_loc.end) {
                            fn_node = candidate;
                            break;
                        }
                    }
                }
            },
            else => {},
        }
    }

    if (fn_node == null) {
        // Fall back to enclosing function
        var target_node: ?Ast.Node.Index = null;
        for (0..tree.nodes.len) |idx| {
            const candidate: Ast.Node.Index = @fromBackingInt(@intCast(idx));
            const loc = offsets.nodeToLoc(tree, candidate);
            if (source_index >= loc.start and source_index <= loc.end) {
                target_node = candidate;
                break;
            }
        }
        if (target_node) |tn| {
            fn_node = findEnclosingFunction(tree, tn);
        }
    }

    const resolved_fn = fn_node orelse return null;
    const item = (try createCallHierarchyItem(arena, handle, resolved_fn, server.offset_encoding)) orelse return null;

    const result = try arena.alloc(types.call_hierarchy.Item, 1);
    result[0] = item;
    return result;
}

pub fn @"callHierarchy/incomingCalls"(
    server: *Server,
    arena: std.mem.Allocator,
    request: types.call_hierarchy.IncomingCallsParams,
) Error!?[]const types.call_hierarchy.IncomingCall {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const document_uri = Uri.parse(arena, request.item.uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };
    const handle = server.document_store.getHandle(document_uri) orelse return null;

    var analyser = server.initAnalyser(arena, handle);
    defer analyser.deinit();

    const tree = &handle.tree;
    const sel_index = offsets.positionToIndex(tree.source, request.item.selectionRange.start, server.offset_encoding);

    var target_fn_node: ?Ast.Node.Index = null;
    for (0..tree.nodes.len) |idx| {
        const candidate: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        switch (tree.nodeTag(candidate)) {
            .fn_decl, .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => {
                var buf: [1]Ast.Node.Index = undefined;
                if (tree.fullFnProto(&buf, candidate)) |fn_info| {
                    if (fn_info.name_token) |nt| {
                        const name_loc = offsets.tokenToLoc(tree, nt);
                        if (sel_index >= name_loc.start and sel_index <= name_loc.end) {
                            target_fn_node = candidate;
                            break;
                        }
                    }
                }
            },
            else => {},
        }
    }

    var fn_node = target_fn_node orelse return null;
    if (tree.nodeTag(fn_node) != .fn_decl) {
        for (0..tree.nodes.len) |idx| {
            const candidate: Ast.Node.Index = @fromBackingInt(@intCast(idx));
            if (tree.nodeTag(candidate) == .fn_decl) {
                const data = tree.nodeData(candidate).node_and_node;
                if (data[0] == fn_node) {
                    fn_node = candidate;
                    break;
                }
            }
        }
    }
    var buf: [1]Ast.Node.Index = undefined;
    const fn_info = tree.fullFnProto(&buf, fn_node) orelse return null;
    const nt = fn_info.name_token orelse return null;
    const name = offsets.identifierTokenToNameSlice(tree, nt);
    const target_decl = (try analyser.lookupSymbolGlobal(handle, name, tree.tokenStart(nt))) orelse return null;

    const callsites = try references.callsiteReferences(&analyser, target_decl, true);

    // Group callsites by enclosing caller function
    const Group = struct {
        caller_handle: *DocumentStore.Handle,
        caller_node: Ast.Node.Index,
        ranges: std.ArrayList(types.Range),
    };
    var groups: std.ArrayList(Group) = .empty;

    for (callsites.items) |cs| {
        const caller_fn = findEnclosingFunction(&cs.handle.tree, cs.node) orelse continue;
        const call_loc = offsets.nodeToLoc(&cs.handle.tree, cs.node);
        const call_range = offsets.locToRange(cs.handle.tree.source, call_loc, server.offset_encoding);

        var found_group: ?*Group = null;
        for (groups.items) |*g| {
            if (g.caller_handle.uri.eql(cs.handle.uri) and g.caller_node == caller_fn) {
                found_group = g;
                break;
            }
        }

        if (found_group) |g| {
            try g.ranges.append(arena, call_range);
        } else {
            var new_ranges: std.ArrayList(types.Range) = .empty;
            try new_ranges.append(arena, call_range);
            try groups.append(arena, .{
                .caller_handle = cs.handle,
                .caller_node = caller_fn,
                .ranges = new_ranges,
            });
        }
    }

    var result: std.ArrayList(types.call_hierarchy.IncomingCall) = .empty;
    for (groups.items) |g| {
        if (try createCallHierarchyItem(arena, g.caller_handle, g.caller_node, server.offset_encoding)) |caller_item| {
            try result.append(arena, .{
                .from = caller_item,
                .fromRanges = g.ranges.items,
            });
        }
    }

    return result.items;
}

pub fn @"callHierarchy/outgoingCalls"(
    server: *Server,
    arena: std.mem.Allocator,
    request: types.call_hierarchy.OutgoingCallsParams,
) Error!?[]const types.call_hierarchy.OutgoingCall {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const document_uri = Uri.parse(arena, request.item.uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };
    const handle = server.document_store.getHandle(document_uri) orelse return null;

    var analyser = server.initAnalyser(arena, handle);
    defer analyser.deinit();

    const tree = &handle.tree;
    const sel_index = offsets.positionToIndex(tree.source, request.item.selectionRange.start, server.offset_encoding);

    var target_fn_node: ?Ast.Node.Index = null;
    for (0..tree.nodes.len) |idx| {
        const candidate: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        switch (tree.nodeTag(candidate)) {
            .fn_decl, .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => {
                var buf: [1]Ast.Node.Index = undefined;
                if (tree.fullFnProto(&buf, candidate)) |fn_info| {
                    if (fn_info.name_token) |nt| {
                        const name_loc = offsets.tokenToLoc(tree, nt);
                        if (sel_index >= name_loc.start and sel_index <= name_loc.end) {
                            target_fn_node = candidate;
                            break;
                        }
                    }
                }
            },
            else => {},
        }
    }

    var fn_node = target_fn_node orelse return null;
    if (tree.nodeTag(fn_node) != .fn_decl) {
        for (0..tree.nodes.len) |idx| {
            const candidate: Ast.Node.Index = @fromBackingInt(@intCast(idx));
            if (tree.nodeTag(candidate) == .fn_decl) {
                const data = tree.nodeData(candidate).node_and_node;
                if (data[0] == fn_node) {
                    fn_node = candidate;
                    break;
                }
            }
        }
    }

    const OutGroup = struct {
        callee_handle: *DocumentStore.Handle,
        callee_node: Ast.Node.Index,
        ranges: std.ArrayList(types.Range),
    };
    var groups: std.ArrayList(OutGroup) = .empty;

    var walker: ast.Walker = try .init(arena, tree, fn_node);
    defer walker.deinit(arena);
    while (try walker.nextIgnoreClose(arena, tree)) |child| {
        switch (tree.nodeTag(child)) {
            .call, .call_comma, .call_one, .call_one_comma => {
                var buf: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&buf, child) orelse continue;
                const called_node = call.ast.fn_expr;

                var maybe_decl: ?Analyser.DeclWithHandle = null;
                switch (tree.nodeTag(called_node)) {
                    .identifier => {
                        const id_tok = ast.identifierTokenFromIdentifierNode(tree, called_node) orelse continue;
                        const name = offsets.identifierTokenToNameSlice(tree, id_tok);
                        maybe_decl = analyser.lookupSymbolGlobal(handle, name, tree.tokenStart(id_tok)) catch null;
                    },
                    .field_access => {
                        const lhs_node, const field_name = tree.nodeData(called_node).node_and_token;
                        if (analyser.resolveTypeOfNode(.of(lhs_node, handle)) catch null) |lhs| {
                            const deref_lhs = (analyser.resolveDerefType(lhs) catch null) orelse lhs;
                            const symbol = offsets.tokenToSlice(tree, field_name);
                            maybe_decl = deref_lhs.lookupSymbol(&analyser, symbol) catch null;
                        }
                    },
                    else => {},
                }

                const decl = maybe_decl orelse continue;
                if (decl.decl != .ast_node) continue;

                const call_loc = offsets.nodeToLoc(tree, child);
                const call_range = offsets.locToRange(tree.source, call_loc, server.offset_encoding);

                var found_group: ?*OutGroup = null;
                for (groups.items) |*g| {
                    if (g.callee_handle.uri.eql(decl.handle.uri) and g.callee_node == decl.decl.ast_node) {
                        found_group = g;
                        break;
                    }
                }

                if (found_group) |g| {
                    try g.ranges.append(arena, call_range);
                } else {
                    var new_ranges: std.ArrayList(types.Range) = .empty;
                    try new_ranges.append(arena, call_range);
                    try groups.append(arena, .{
                        .callee_handle = decl.handle,
                        .callee_node = decl.decl.ast_node,
                        .ranges = new_ranges,
                    });
                }
            },
            else => {},
        }
    }

    var result: std.ArrayList(types.call_hierarchy.OutgoingCall) = .empty;
    for (groups.items) |g| {
        if (try createCallHierarchyItem(arena, g.callee_handle, g.callee_node, server.offset_encoding)) |to_item| {
            try result.append(arena, .{
                .to = to_item,
                .fromRanges = g.ranges.items,
            });
        }
    }

    return result.items;
}

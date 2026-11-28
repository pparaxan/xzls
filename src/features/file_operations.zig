const std = @import("std");
const Server = @import("../Server.zig");
const DocumentStore = @import("../DocumentStore.zig");
const types = @import("lsp").types;
const Uri = @import("../Uri.zig");
const offsets = @import("../offsets.zig");

fn mapped(arena: std.mem.Allocator, uri: Uri, files: []const types.workspace.FileRename) Server.Error!Uri {
    var best: ?Uri = null;
    var length: usize = 0;
    for (files) |file| {
        const old = Uri.parse(arena, file.oldUri) catch return error.InvalidParams;
        const prefix = std.mem.trimEnd(u8, old.raw, "/");
        if (prefix.len < length or !std.mem.startsWith(u8, uri.raw, prefix)) continue;
        if (uri.raw.len != prefix.len and uri.raw[prefix.len] != '/') continue;
        const new = Uri.parse(arena, file.newUri) catch return error.InvalidParams;
        best = Uri.parse(arena, try arena.print("{s}{s}", .{ std.mem.trimEnd(u8, new.raw, "/"), uri.raw[prefix.len..] })) catch return error.InvalidParams;
        length = prefix.len;
    }
    return best orelse uri;
}

pub fn willRename(server: *Server, arena: std.mem.Allocator, params: types.workspace.RenameFilesParams) Server.Error!?types.WorkspaceEdit {
    var changes: types.WorkspaceEdit = .{ .changes = .{} };
    var iterator: DocumentStore.HandleIterator = .{ .store = &server.document_store };
    while (iterator.next()) |handle| {
        if (!handle.uri.isFileScheme()) continue;
        const tree = &handle.tree;
        const destination = try mapped(arena, handle.uri, params.files);
        const source_path = destination.toFsPath(arena) catch continue;
        const source_dir = std.Io.Dir.path.dirname(source_path) orelse continue;
        var edits: std.ArrayList(types.TextEdit) = .empty;
        for (0..tree.nodes.len) |i| {
            const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(i));
            var buffer: [2]std.zig.Ast.Node.Index = undefined;
            const arguments = tree.builtinCallParams(&buffer, node) orelse continue;
            if (arguments.len != 1 or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) continue;
            const argument = arguments[0];
            if (tree.nodeTag(argument) != .string_literal) continue;
            const token = tree.nodeMainToken(argument);
            const name = std.zig.string_literal.parseAlloc(arena, tree.tokenSlice(token)) catch continue;
            if (!std.mem.endsWith(u8, name, ".zig") and !std.mem.endsWith(u8, name, ".zon")) continue;
            const target = try Uri.resolveImport(arena, handle.uri, handle.uri.toStdUri(), name);
            const new_target = try mapped(arena, target, params.files);
            if (destination.eql(handle.uri) and new_target.eql(target)) continue;
            const target_path = new_target.toFsPath(arena) catch continue;
            const relative = if (std.Io.Dir.path.isAbsolute(name))
                target_path
            else
                try std.Io.Dir.path.relativeAlloc(arena, ".", null, source_dir, target_path);
            for (relative) |*c| if (c.* == '\\') {
                c.* = '/';
            };
            if (std.mem.eql(u8, relative, name)) continue;
            try edits.append(arena, .{
                .range = offsets.tokenToRange(tree, token, server.offset_encoding),
                .newText = try arena.print("\"{f}\"", .{std.zig.fmtString(relative)}),
            });
        }
        if (edits.items.len > 0) try changes.changes.?.map.put(arena, handle.uri.raw, edits.items);
    }
    return if (changes.changes.?.map.count() == 0) null else changes;
}

pub fn didRename(server: *Server, arena: std.mem.Allocator, params: types.workspace.RenameFilesParams) Server.Error!void {
    // Snapshot first: changing the handle table while iterating would invalidate
    // its order, and a folder rename may affect several open documents.
    const Move = struct { old: Uri, destination: Uri, source: ?[]const u8 };
    var moves: std.ArrayList(Move) = .empty;
    var iterator: DocumentStore.HandleIterator = .{ .store = &server.document_store };
    while (iterator.next()) |handle| {
        const destination = try mapped(arena, handle.uri, params.files);
        if (destination.eql(handle.uri)) continue;
        try moves.append(arena, .{ .old = try handle.uri.dupe(arena), .destination = destination, .source = if (handle.lsp_synced) try arena.dupe(u8, handle.tree.source) else null });
    }
    for (moves.items) |move| {
        server.document_store.closeLspSyncedDocument(move.old);
        _ = try server.document_store.refreshDocumentFromFileSystem(move.old, true);
        server.diagnostics_collection.clearSingleDocumentDiagnostics(move.old);
    }
    for (moves.items) |move| {
        if (move.source) |source| try server.document_store.openLspSyncedDocument(move.destination, source);
    }
    for (moves.items) |move| {
        if (move.source != null) server.generateDiagnostics(server.document_store.getHandle(move.destination).?);
    }
}

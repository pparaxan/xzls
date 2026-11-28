const std = @import("std");
const Server = @import("../Server.zig");
const types = @import("lsp").types;
const Uri = @import("../Uri.zig");
const diff = @import("../diff.zig");

fn formatLines(server: *Server, arena: std.mem.Allocator, document: types.TextDocument.Identifier, first: u32, end: u32) Server.Error!?[]types.TextEdit {
    const uri = Uri.parse(arena, document.uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };
    const handle = server.document_store.getHandle(uri) orelse return null;
    if (handle.tree.errors.len != 0) return null;
    const formatted = try handle.tree.renderAlloc(arena);
    const edits = try diff.edits(server.io, arena, handle.tree.source, formatted, server.offset_encoding);
    var result: std.ArrayList(types.TextEdit) = .empty;
    for (edits.items) |edit| {
        if (edit.range.start.line < first) continue;
        if (edit.range.end.line > end or (edit.range.end.line == end and edit.range.end.character != 0)) continue;
        if (edit.range.start.line == end) continue;
        try result.append(arena, edit);
    }
    return result.items;
}

pub fn range(server: *Server, arena: std.mem.Allocator, params: types.document_range_formatting.Params) Server.Error!?[]types.TextEdit {
    const end = params.range.end.line +| @intFromBool(params.range.end.character != 0 or params.range.start.line == params.range.end.line);
    return formatLines(server, arena, params.textDocument, params.range.start.line, end);
}

pub fn onType(server: *Server, arena: std.mem.Allocator, params: types.document_on_type_formatting.Params) Server.Error!?[]types.TextEdit {
    const line = if (std.mem.eql(u8, params.ch, "\n")) params.position.line -| 1 else params.position.line;
    return formatLines(server, arena, params.textDocument, line, line +| 1);
}

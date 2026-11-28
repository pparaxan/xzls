const std = @import("std");
const Server = @import("../Server.zig");
const types = @import("lsp").types;
const Uri = @import("../Uri.zig");
const offsets = @import("../offsets.zig");

const Data = struct { uri: []const u8, position: types.Position, name: []const u8 };

fn json(arena: std.mem.Allocator, value: anytype) error{OutOfMemory}!std.json.Value {
    const text = try std.json.Stringify.valueAlloc(arena, value, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{ .allocate = .alloc_always }) catch return error.OutOfMemory;
}

pub fn list(server: *Server, arena: std.mem.Allocator, params: types.code_lens.Params) Server.Error!?[]types.code_lens.Response {
    const uri = Uri.parse(arena, params.textDocument.uri) catch return error.InvalidParams;
    const handle = server.document_store.getHandle(uri) orelse return null;
    if (handle.tree.mode != .zig) return null;
    var lenses: std.ArrayList(types.code_lens.Response) = .empty;
    for (0..handle.tree.nodes.len) |i| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (handle.tree.nodeTag(node) != .fn_decl) continue;
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const function = handle.tree.fullFnProto(&buffer, node) orelse continue;
        const name = function.name_token orelse continue;
        const range = offsets.tokenToRange(&handle.tree, name, server.offset_encoding);
        try lenses.append(arena, .{
            .range = range,
            .data = try json(arena, Data{ .uri = uri.raw, .position = range.start, .name = handle.tree.tokenSlice(name) }),
        });
    }
    return lenses.items;
}

pub fn resolve(server: *Server, arena: std.mem.Allocator, lens: types.code_lens.Response) Server.Error!types.code_lens.Response {
    const data = std.json.parseFromValueLeaky(Data, arena, lens.data orelse return error.InvalidParams, .{}) catch return error.InvalidParams;
    const uri = Uri.parse(arena, data.uri) catch return error.InvalidParams;
    const handle = server.document_store.getHandle(uri) orelse return lens;
    const index = offsets.positionToIndex(handle.tree.source, data.position, server.offset_encoding);
    const location = offsets.identifierLocFromIndex(&handle.tree, index) orelse return lens;
    if (!std.mem.eql(u8, offsets.locToSlice(handle.tree.source, location), data.name)) return lens;
    const locations = (try @import("references.zig").@"textDocument/references"(server, arena, .{
        .textDocument = .{ .uri = uri.raw },
        .position = data.position,
        .context = .{ .includeDeclaration = false },
    })) orelse &.{};
    var result = lens;
    result.command = .{
        .title = try arena.print("{d} reference{s}", .{ locations.len, if (locations.len == 1) @as([]const u8, "") else "s" }),
        .command = "editor.action.showReferences",
        .arguments = &.{ try json(arena, data.uri), try json(arena, data.position), try json(arena, locations) },
    };
    return result;
}

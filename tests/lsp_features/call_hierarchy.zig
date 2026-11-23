const std = @import("std");
const zls = @import("xzls");

const Context = @import("../context.zig").Context;
const types = zls.lsp.types;
const offsets = zls.offsets;

const allocator: std.mem.Allocator = std.testing.allocator;

test "prepare call hierarchy and incoming/outgoing calls" {
    const source =
        \\fn target() void {}
        \\fn caller() void {
        \\    target();
        \\}
    ;

    var ctx: Context = try .init();
    defer ctx.deinit();

    const uri = try ctx.addDocument(.{ .source = source });
    const pos = offsets.indexToPosition(source, 3, ctx.server.offset_encoding); // at 'target'

    const prepare_params: types.call_hierarchy.PrepareParams = .{
        .textDocument = .{ .uri = uri.raw },
        .position = pos,
    };

    const items = (try ctx.server.sendRequestSync(ctx.arena.allocator(), "textDocument/prepareCallHierarchy", prepare_params)).?;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("target", items[0].name);

    // Incoming calls to 'target'
    const incoming_params: types.call_hierarchy.IncomingCallsParams = .{
        .item = items[0],
    };
    const incoming = (try ctx.server.sendRequestSync(ctx.arena.allocator(), "callHierarchy/incomingCalls", incoming_params)).?;
    try std.testing.expectEqual(@as(usize, 1), incoming.len);
    try std.testing.expectEqualStrings("caller", incoming[0].from.name);

    // Outgoing calls from 'caller'
    const caller_pos = offsets.indexToPosition(source, std.mem.indexOf(u8, source, "caller").?, ctx.server.offset_encoding);
    const caller_items = (try ctx.server.sendRequestSync(ctx.arena.allocator(), "textDocument/prepareCallHierarchy", .{
        .textDocument = .{ .uri = uri.raw },
        .position = caller_pos,
    })).?;
    try std.testing.expectEqualStrings("caller", caller_items[0].name);

    const outgoing_params: types.call_hierarchy.OutgoingCallsParams = .{
        .item = caller_items[0],
    };
    const outgoing = (try ctx.server.sendRequestSync(ctx.arena.allocator(), "callHierarchy/outgoingCalls", outgoing_params)).?;
    try std.testing.expectEqual(@as(usize, 1), outgoing.len);
    try std.testing.expectEqualStrings("target", outgoing[0].to.name);
}

const std = @import("std");
const zls = @import("xzls");

const Context = @import("../context.zig").Context;
const allocator: std.mem.Allocator = std.testing.allocator;

test "ssr query replace expression" {
    var ctx: Context = try .init();
    defer ctx.deinit();

    const uri = try ctx.addDocument(.{
        .source =
        \\pub fn check(list: anytype) bool {
        \\    return list.items.len == 0;
        \\}
        ,
    });

    const edit = try zls.ssr.performSsr(
        ctx.arena.allocator(),
        &ctx.server.document_store,
        .{
            .query = "$a.len == 0 ==>> $a.isEmpty()",
            .uri = uri.raw,
        },
        ctx.server.offset_encoding,
    );

    const changes = edit.changes.?.map.get(uri.raw).?;
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings("list.items.isEmpty()", changes[0].newText);
}

test "ssr call argument swap" {
    var ctx: Context = try .init();
    defer ctx.deinit();

    const uri = try ctx.addDocument(.{
        .source =
        \\pub fn test_fn() void {
        \\    foo(x + 1, y * 2);
        \\}
        ,
    });

    const edit = try zls.ssr.performSsr(
        ctx.arena.allocator(),
        &ctx.server.document_store,
        .{
            .query = "foo($a, $b) ==>> bar($b, $a)",
            .uri = uri.raw,
        },
        ctx.server.offset_encoding,
    );

    const changes = edit.changes.?.map.get(uri.raw).?;
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings("bar(y * 2, x + 1)", changes[0].newText);
}

test "ssr multiple occurrences in file" {
    var ctx: Context = try .init();
    defer ctx.deinit();

    const uri = try ctx.addDocument(.{
        .source =
        \\pub fn test_fn() void {
        \\    if (alpha.len == 0) return;
        \\    if (beta.items.len == 0) return;
        \\}
        ,
    });

    const edit = try zls.ssr.performSsr(
        ctx.arena.allocator(),
        &ctx.server.document_store,
        .{
            .query = "$a.len == 0 ==>> $a.isEmpty()",
            .uri = uri.raw,
        },
        ctx.server.offset_encoding,
    );

    const changes = edit.changes.?.map.get(uri.raw).?;
    try std.testing.expectEqual(@as(usize, 2), changes.len);
    try std.testing.expectEqualStrings("alpha.isEmpty()", changes[0].newText);
    try std.testing.expectEqualStrings("beta.items.isEmpty()", changes[1].newText);
}

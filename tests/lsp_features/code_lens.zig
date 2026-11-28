const std = @import("std");
const Context = @import("../context.zig").Context;

test "code lenses resolve reference counts lazily" {
    var context = try Context.init();
    defer context.deinit();
    const arena = context.arena.allocator();
    const uri = try context.addDocument(.{ .source = "fn foo() void {}\nfn caller() void { foo(); }\n" });
    const lenses = (try context.server.sendRequestSync(arena, "textDocument/codeLens", .{ .textDocument = .{ .uri = uri.raw } })).?;
    try std.testing.expectEqual(@as(usize, 2), lenses.len);
    try std.testing.expect(lenses[0].command == null);
    const resolved = try context.server.sendRequestSync(arena, "codeLens/resolve", lenses[0]);
    try std.testing.expectEqualStrings("1 reference", resolved.command.?.title);
    try std.testing.expectEqualStrings("editor.action.showReferences", resolved.command.?.command);
    try std.testing.expectEqual(@as(usize, 1), resolved.command.?.arguments.?[2].array.items.len);
    const unused = try context.server.sendRequestSync(arena, "codeLens/resolve", lenses[1]);
    try std.testing.expectEqualStrings("0 references", unused.command.?.title);
}

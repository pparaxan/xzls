const std = @import("std");
const zls = @import("xzls");
const Context = @import("../context.zig").Context;

test "file rename updates imports and moved source relative paths" {
    var context = try Context.init();
    defer context.deinit();
    const uri = try zls.Uri.parse(context.arena.allocator(), "file:///project/src/main.zig");
    const source = "const dep = @import(\"../lib/old.zig\");\nconst std = @import(\"std\");\n";
    try context.server.document_store.openLspSyncedDocument(uri, source);
    const edit = (try context.server.sendRequestSync(context.arena.allocator(), "workspace/willRenameFiles", .{ .files = &.{
        .{ .oldUri = "file:///project/lib/old.zig", .newUri = "file:///project/pkg/new.zig" },
        .{ .oldUri = uri.raw, .newUri = "file:///project/main.zig" },
    } })).?;
    const actual = try zls.diff.applyTextEdits(std.testing.allocator, source, edit.changes.?.map.get(uri.raw).?, context.server.offset_encoding);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("const dep = @import(\"pkg/new.zig\");\nconst std = @import(\"std\");\n", actual);
}

test "folder rename respects directory boundaries" {
    var context = try Context.init();
    defer context.deinit();
    const uri = try zls.Uri.parse(context.arena.allocator(), "file:///project/main.zig");
    const source = "const a = @import(\"lib/a.zig\");\nconst b = @import(\"library/b.zig\");\n";
    try context.server.document_store.openLspSyncedDocument(uri, source);
    const edit = (try context.server.sendRequestSync(context.arena.allocator(), "workspace/willRenameFiles", .{ .files = &.{.{ .oldUri = "file:///project/lib", .newUri = "file:///project/pkg" }} })).?;
    const actual = try zls.diff.applyTextEdits(std.testing.allocator, source, edit.changes.?.map.get(uri.raw).?, context.server.offset_encoding);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("const a = @import(\"pkg/a.zig\");\nconst b = @import(\"library/b.zig\");\n", actual);
}

test "rename notification preserves open unsaved documents" {
    var context = try Context.init();
    defer context.deinit();
    const uri = try zls.Uri.parse(context.arena.allocator(), "file:///project/a.zig");
    const destination = try zls.Uri.parse(context.arena.allocator(), "file:///project/b.zig");
    try context.server.document_store.openLspSyncedDocument(uri, "const unsaved = 42;");
    try context.server.sendNotificationSync(context.arena.allocator(), "workspace/didRenameFiles", .{ .files = &.{.{ .oldUri = uri.raw, .newUri = destination.raw }} });
    try std.testing.expect(context.server.document_store.getHandle(uri) == null);
    try std.testing.expectEqualStrings("const unsaved = 42;", context.server.document_store.getHandle(destination).?.tree.source);
}

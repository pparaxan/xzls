const std = @import("std");
const zls = @import("xzls");
const Context = @import("../context.zig").Context;

test "build script dependency autocomplete without build evaluation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dep/src/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data =
        \\.{ .dependencies = .{ .@"helper-tools" = .{ .path = "dep" } } }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "dep/build.zig", .data =
        \\pub fn addTool() void {}
        \\pub const Options = struct {};
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "dep/src/deep/root.zig", .data = "pub const runtime_only = true;" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.Io.Dir.path.join(allocator, &.{ root, "build.zig" });
    defer allocator.free(path);
    const uri = try zls.Uri.fromPath(allocator, path);
    defer uri.deinit(allocator);

    var context = try Context.init();
    defer context.deinit();
    // Resolving build APIs must not depend on the compiler successfully
    // evaluating the build script that is currently being edited.
    context.server.document_store.config.zig_exe_path = null;
    const source =
        \\const helper = @import("helper-tools");
        \\const value = helper.
    ;
    try context.server.document_store.openLspSyncedDocument(uri, source);
    const result = (try context.server.sendRequestSync(context.arena.allocator(), "textDocument/completion", .{
        .textDocument = .{ .uri = uri.raw },
        .position = zls.offsets.indexToPosition(source, source.len, .@"utf-16"),
    })) orelse return error.MissingCompletions;
    const items = result.completion_list.items;
    var found_function = false;
    var found_options = false;
    for (items) |item| {
        if (std.mem.eql(u8, item.label, "addTool")) found_function = true;
        if (std.mem.eql(u8, item.label, "Options")) found_options = true;
        try std.testing.expect(!std.mem.eql(u8, item.label, "runtime_only"));
    }
    try std.testing.expect(found_function);
    try std.testing.expect(found_options);
}

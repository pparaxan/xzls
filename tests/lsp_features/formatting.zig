const std = @import("std");
const zls = @import("xzls");
const Context = @import("../context.zig").Context;

test "range formatting leaves other lines unchanged" {
    var context = try Context.init();
    defer context.deinit();
    const source = "const a=1;\nconst b=2;\nconst c=3;\n";
    const uri = try context.addDocument(.{ .source = source });
    const edits = (try context.server.sendRequestSync(context.arena.allocator(), "textDocument/rangeFormatting", .{
        .textDocument = .{ .uri = uri.raw },
        .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 2, .character = 0 } },
        .options = .{ .tabSize = 4, .insertSpaces = true },
    })).?;
    const actual = try zls.diff.applyTextEdits(std.testing.allocator, source, edits, context.server.offset_encoding);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("const a=1;\nconst b = 2;\nconst c=3;\n", actual);
}

test "on type formatting is confined to the typed line" {
    var context = try Context.init();
    defer context.deinit();
    const source = "const a=1;\nconst b=2;\n";
    const uri = try context.addDocument(.{ .source = source });
    const edits = (try context.server.sendRequestSync(context.arena.allocator(), "textDocument/onTypeFormatting", .{
        .textDocument = .{ .uri = uri.raw },
        .position = .{ .line = 1, .character = 10 },
        .ch = ";",
        .options = .{ .tabSize = 4, .insertSpaces = true },
    })).?;
    const actual = try zls.diff.applyTextEdits(std.testing.allocator, source, edits, context.server.offset_encoding);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("const a=1;\nconst b = 2;\n", actual);
}

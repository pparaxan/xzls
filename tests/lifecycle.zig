const std = @import("std");
const builtin = @import("builtin");
const zls = @import("xzls");
const test_options = @import("test_options");

const io = std.testing.io;
const allocator = std.testing.allocator;

test "queued edits analyze the latest document state" {
    try testQueuedEdits(false);
}

test "queued edits preserve request boundaries" {
    try testQueuedEdits(true);
}

fn testQueuedEdits(with_request: bool) !void {
    const Context = @import("context.zig").Context;
    var context = try Context.init();
    defer context.deinit();
    const uri = try context.addDocument(.{ .source = "const value = \"\";" });
    const Transport = struct {
        transport: zls.lsp.Transport = .{ .vtable = &.{ .readJsonMessage = read, .writeJsonMessage = write } },
        messages: []const []const u8,
        index: usize = 0,
        read_complete: std.Io.Event = .unset,
        published: std.Io.Event = .unset,
        publications: std.atomic.Value(usize) = .init(0),
        expected_publications: usize,

        fn read(transport: *zls.lsp.Transport, task_io: std.Io, alloc: std.mem.Allocator) zls.lsp.Transport.ReadError![]u8 {
            const self: *@This() = @fieldParentPtr("transport", transport);
            if (self.index == self.messages.len) {
                self.read_complete.set(task_io);
                self.published.waitTimeout(task_io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } }) catch return error.EndOfStream;
                return error.EndOfStream;
            }
            const message = self.messages[self.index];
            self.index += 1;
            return alloc.dupe(u8, message);
        }

        fn write(transport: *zls.lsp.Transport, task_io: std.Io, json: []const u8) zls.lsp.Transport.WriteError!void {
            const self: *@This() = @fieldParentPtr("transport", transport);
            if (std.mem.indexOf(u8, json, "textDocument/publishDiagnostics") != null) {
                const previous = self.publications.fetchAdd(1, .monotonic);
                if (previous + 1 == self.expected_publications) self.published.set(task_io);
            }
        }

        fn waitForEdits(self: *@This(), task_io: std.Io) std.Io.Cancelable!void {
            try self.read_complete.wait(task_io);
        }
    };
    var messages: [4][]const u8 = undefined;
    for (1..4) |version| {
        const source = try context.arena.allocator().print("{d}", .{version});
        const position = .{ .line = 0, .character = 14 + version };
        messages[version - 1 + @intFromBool(with_request and version == 3)] = try std.json.Stringify.valueAlloc(context.arena.allocator(), .{
            .jsonrpc = "2.0",
            .method = "textDocument/didChange",
            .params = .{ .textDocument = .{ .uri = uri.raw, .version = version }, .contentChanges = .{.{ .range = .{ .start = position, .end = position }, .text = source }} },
        }, .{});
    }
    if (with_request) messages[2] = try std.json.Stringify.valueAlloc(context.arena.allocator(), .{
        .jsonrpc = "2.0",
        .id = 42,
        .method = "textDocument/hover",
        .params = .{ .textDocument = .{ .uri = uri.raw }, .position = .{ .line = 0, .character = 6 } },
    }, .{});
    const expected_publications: usize = if (with_request) 2 else 1;
    var transport: Transport = .{ .messages = messages[0..if (with_request) 4 else 3], .expected_publications = expected_publications };
    context.server.setTransport(&transport.transport);
    context.server.client_capabilities.supports_publish_diagnostics = true;
    context.server.wait_group.concurrent(io, Transport.waitForEdits, .{ &transport, io }) catch return error.SkipZigTest;
    try std.testing.expectError(error.EndOfStream, context.server.loop());
    try std.testing.expectEqualStrings("const value = \"123\";", context.server.document_store.getHandle(uri).?.tree.source);
    try std.testing.expectEqual(expected_publications, transport.publications.load(.monotonic));
}

test "LSP lifecycle" {
    var environ_map: std.process.Environ.Map = .init(std.testing.failing_allocator);
    var config_manager: zls.configuration.Manager = try .init(io, allocator, &environ_map);
    defer config_manager.deinit();

    var arena_allocator: std.heap.ArenaAllocator = .init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    if (builtin.target.os.tag != .wasi) {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);

        try config_manager.setConfiguration(.frontend, &.{
            .zig_exe_path = try std.Io.Dir.path.resolveAlloc(arena, &.{ cwd, test_options.zig_exe_path }),
            .zig_lib_path = try std.Io.Dir.path.resolveAlloc(arena, &.{ cwd, test_options.zig_lib_path }),
            .global_cache_path = try std.Io.Dir.path.resolveAlloc(arena, &.{ cwd, test_options.global_cache_path }),
        });
    }

    var server: *zls.Server = try .create(.{
        .io = io,
        .allocator = allocator,
        .transport = null,
        .config_manager = &config_manager,
    });
    defer server.destroy();

    try std.testing.expectEqual(zls.Server.Status.uninitialized, server.status);
    _ = try server.sendRequestSync(arena, "initialize", .{ .capabilities = .{} });
    try std.testing.expectEqual(zls.Server.Status.initializing, server.status);
    try server.sendNotificationSync(arena, "initialized", .{});
    try std.testing.expectEqual(zls.Server.Status.initialized, server.status);
    _ = try server.sendRequestSync(arena, "shutdown", {});
    try std.testing.expectEqual(zls.Server.Status.shutdown, server.status);
    try server.sendNotificationSync(arena, "exit", {});
    try std.testing.expectEqual(zls.Server.Status.exiting_success, server.status);
}

const std = @import("std");
const zls = @import("xzls");

const helper = @import("../helper.zig");
const Context = @import("../context.zig").Context;
const ErrorBuilder = @import("../ErrorBuilder.zig");

const types = zls.lsp.types;
const offsets = zls.offsets;

const allocator: std.mem.Allocator = std.testing.allocator;

test "none" {
    try testDiagnostics("", &.{}, .{});
}

test "ast error" {
    try testDiagnostics(
        \\const foo
    , &.{
        .{
            .range = .{
                .start = .{ .line = 0, .character = 9 },
                .end = .{ .line = 0, .character = 9 },
            },
            .severity = .Error,
            .source = "xzls",
            .message = .{ .string = "expected ';' after declaration" },
        },
    }, .{});
}

test "ast-check" {
    try testDiagnostics(
        \\test {
        \\    const foo = undefined;
        \\}
    , &.{
        .{
            .range = .{
                .start = .{ .line = 1, .character = 10 },
                .end = .{ .line = 1, .character = 13 },
            },
            .severity = .Error,
            .tags = &.{.Unnecessary},
            .source = "xzls",
            .message = .{ .string = "unused local constant" },
        },
    }, .{});

    try testDiagnostics(
        \\test {
        \\    var foo = undefined;
        \\}
    , &.{
        .{
            .range = .{
                .start = .{ .line = 1, .character = 8 },
                .end = .{ .line = 1, .character = 11 },
            },
            .severity = .Error,
            .tags = &.{.Unnecessary},
            .source = "xzls",
            .message = .{ .string = "unused local variable" },
        },
    }, .{});
}

test "warn style" {
    try testDiagnostics(
        \\const foo = @import("./foo");
    , &.{
        .{
            .range = .{
                .start = .{ .line = 0, .character = 20 },
                .end = .{ .line = 0, .character = 27 },
            },
            .severity = .Hint,
            .source = "xzls",
            .message = .{ .string = "`./` isn't needed in imports." },
        },
    }, .{ .warn_style = true });
    try testDiagnostics(
        \\fn Foo() void {}
        \\fn bar() type {}
    , &.{
        .{
            .range = .{
                .start = .{ .line = 0, .character = 3 },
                .end = .{ .line = 0, .character = 6 },
            },
            .severity = .Hint,
            .source = "xzls",
            .message = .{ .string = "Functions should be camelCase." },
        },
        .{
            .range = .{
                .start = .{ .line = 1, .character = 3 },
                .end = .{ .line = 1, .character = 6 },
            },
            .severity = .Hint,
            .source = "xzls",
            .message = .{ .string = "Type functions should be PascalCase." },
        },
    }, .{ .warn_style = true });
}

test "highlight global var decls" {
    try testDiagnostics(
        \\var foo: u32 = undefined;
    , &.{
        .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 3 },
            },
            .severity = .Hint,
            .source = "xzls",
            .message = .{ .string = "Global mutable variable. Consider using `const` if mutation is unnecessary." },
        },
    }, .{ .highlight_global_var_declarations = true });
}

test "autofix comment" {
    try testDiagnostics(
        \\test {
        \\    const foo = undefined;
        \\    _ = foo; // autofix
        \\}
    , &.{
        .{
            .range = .{
                .start = .{ .line = 2, .character = 8 },
                .end = .{ .line = 2, .character = 11 },
            },
            .severity = .Information,
            .source = "xzls",
            .message = .{ .string = "auto discard for unused variable" },
            .relatedInformation = &.{
                .{
                    .location = .{
                        .uri = "untitled:///Untitled-0.zig",
                        .range = .{
                            .start = .{ .line = 1, .character = 10 },
                            .end = .{ .line = 1, .character = 13 },
                        },
                    },
                    .message = "variable declared here",
                },
            },
        },
    }, .{ .autofix = true });
}

fn testDiagnostics(
    source: []const u8,
    expected_diagnostics: []const types.Diagnostic,
    options: struct {
        warn_style: bool = false,
        highlight_global_var_declarations: bool = false,
        autofix: bool = false,
        enable_checks: bool = false,
    },
) !void {
    var context: Context = try .init();
    defer context.deinit();

    const uri = try context.addDocument(.{
        .source = source,
    });

    context.server.config_manager.config.warn_style = options.warn_style;
    context.server.config_manager.config.highlight_global_var_declarations = options.highlight_global_var_declarations;
    context.server.config_manager.config.enable_checks = options.enable_checks;
    context.server.client_capabilities.supports_code_action_fixall = options.autofix;
    context.server.client_capabilities.supports_publish_diagnostics = true;
    try zls.diagnostics.generateDiagnostics(context.server, context.server.document_store.getHandle(uri).?);

    var actual_diagnostics: std.ArrayList(types.Diagnostic) = .empty;

    try context.server.diagnostics_collection.collectLspDiagnosticsForDocumentTesting(
        uri,
        .@"utf-8",
        context.arena.allocator(),
        &actual_diagnostics,
    );

    try zls.testing.expectEqual(expected_diagnostics, actual_diagnostics.items);
}

test "resource leak diagnostic" {
    try testDiagnostics(
        \\const std = @import("std");
        \\fn foo(allocator: std.mem.Allocator) !void {
        \\    const buf = try allocator.alloc(u8, 100);
        \\    buf[0] = 42;
        \\}
    , &.{
        .{
            .range = .{
                .start = .{ .line = 2, .character = 10 },
                .end = .{ .line = 2, .character = 13 },
            },
            .severity = .Warning,
            .source = "xzls",
            .message = .{ .string = "Resource 'buf' is allocated but never freed with either `free() or `destroy()`." },
        },
    }, .{});

    try testDiagnostics(
        \\const std = @import("std");
        \\fn foo(allocator: std.mem.Allocator) !void {
        \\    const buf = try allocator.alloc(u8, 100);
        \\    defer allocator.free(buf);
        \\}
    , &.{}, .{});

    try testDiagnostics(
        \\const std = @import("std");
        \\fn foo(allocator: std.mem.Allocator) !void {
        \\    const buf = try allocator.alloc(u8, 100);
        \\    allocator.free(buf);
        \\}
    , &.{}, .{});

    try testDiagnostics(
        \\const S = struct {
        \\    /// [release]: [deinit](S.zig)
        \\    pub fn init() !S { return .{}; }
        \\    pub fn deinit(self: *S) void { _ = self; }
        \\};
        \\fn foo() !void {
        \\    const s = try S.init();
        \\    _ = s;
        \\}
    , &.{
        .{
            .range = .{
                .start = .{ .line = 6, .character = 10 },
                .end = .{ .line = 6, .character = 11 },
            },
            .severity = .Warning,
            .source = "xzls",
            .message = .{ .string = "Resource 's' is allocated but never got freed with deinit." },
        },
    }, .{});

    try testDiagnostics(
        \\const S = struct {
        \\    /// [release]: [deinit](S.zig)
        \\    pub fn init() !S { return .{}; }
        \\    pub fn deinit(self: *S) void { _ = self; }
        \\    pub fn work(self: S) void { _ = self; }
        \\};
        \\fn foo() !void {
        \\    var s: S = undefined;
        \\    s = try S.init();
        \\    s.work();
        \\}
    , &.{
        .{
            .range = .{
                .start = .{ .line = 8, .character = 4 },
                .end = .{ .line = 8, .character = 5 },
            },
            .severity = .Warning,
            .source = "xzls",
            .message = .{ .string = "Resource 's' is allocated but never got freed with deinit." },
        },
    }, .{});

    // Test that deinit on another variable doesn't falsely mark `alternative.Untitled` as released.
    try testDiagnostics(
        \\const S = struct {
        \\    /// [release]: [deinit](Untitled.zig)
        \\    pub fn init() !S { return .{}; }
        \\    pub fn deinit(self: *S) void { _ = self; }
        \\};
        \\const Other = struct {
        \\    pub fn deinit(self: Other) void { _ = self; }
        \\};
        \\const alternative = struct {
        \\    pub const Untitled = S;
        \\};
        \\fn foo(other: Other) !void {
        \\    defer other.deinit();
        \\    const start = try alternative.Untitled.init();
        \\    _ = start;
        \\}
    , &.{
        .{
            .range = .{
                .start = .{ .line = 13, .character = 10 },
                .end = .{ .line = 13, .character = 15 },
            },
            .severity = .Warning,
            .source = "xzls",
            .message = .{ .string = "Resource 'start' is allocated but never got freed with deinit." },
        },
    }, .{});
}

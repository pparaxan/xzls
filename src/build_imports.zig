//! Resolve build-script imports without requiring a successful build evaluation.
const std = @import("std");
const Ast = std.zig.Ast;
const offsets = @import("offsets.zig");

pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    build_path: []const u8,
    name: []const u8,
    global_cache: ?[]const u8,
) error{ OutOfMemory, Canceled }!?[]u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const root = std.Io.Dir.path.dirname(build_path) orelse return null;
    const manifest_path = try std.Io.Dir.path.join(scratch, &.{ root, "build.zig.zon" });
    const source = std.Io.Dir.cwd().readFileAllocOptions(io, manifest_path, scratch, .limited(1024 * 1024), .of(u8), 0) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => |failure| return failure,
        else => return null,
    };
    var tree = try Ast.parse(scratch, source, .{ .mode = .zon });
    defer tree.deinit(scratch);
    if (tree.errors.len != 0) return null;
    const dependencies = field(&tree, tree.nodeData(.root).node, "dependencies") orelse return null;
    const dependency = field(&tree, dependencies, name) orelse return null;
    if (try stringField(scratch, &tree, dependency, "path")) |path| {
        const candidate = try std.Io.Dir.path.resolveAlloc(scratch, &.{ root, path, "build.zig" });
        return existingPath(allocator, io, candidate);
    }
    const hash = try stringField(scratch, &tree, dependency, "hash") orelse return null;
    // A hash is a single directory name, never a relative filesystem path.
    if (std.mem.indexOfAny(u8, hash, "/\\") != null or std.mem.eql(u8, hash, "..")) return null;
    const vendored = try std.Io.Dir.path.join(scratch, &.{ root, "zig-pkg", hash, "build.zig" });
    if (try existingPath(allocator, io, vendored)) |path| return path;
    if (global_cache) |cache| {
        const candidate = try std.Io.Dir.path.join(scratch, &.{ cache, "p", hash, "build.zig" });
        return existingPath(allocator, io, candidate);
    }
    return null;
}

fn existingPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) error{ OutOfMemory, Canceled }!?[]u8 {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    return try allocator.dupe(u8, path);
}

fn field(tree: *const Ast, node: Ast.Node.Index, name: []const u8) ?Ast.Node.Index {
    var buffer: [2]Ast.Node.Index = undefined;
    const init = tree.fullStructInit(&buffer, node) orelse return null;
    for (init.ast.fields) |value| {
        const first = tree.firstToken(value);
        if (first < 2 or tree.tokenTag(first - 2) != .identifier) continue;
        if (std.mem.eql(u8, offsets.identifierTokenToNameSlice(tree, first - 2), name)) return value;
    }
    return null;
}

fn stringField(allocator: std.mem.Allocator, tree: *const Ast, node: Ast.Node.Index, name: []const u8) error{OutOfMemory}!?[]const u8 {
    const value = field(tree, node, name) orelse return null;
    if (tree.nodeTag(value) != .string_literal) return null;
    return std.zig.string_literal.parseAlloc(allocator, tree.tokenSlice(tree.nodeMainToken(value))) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidLiteral => return null,
    };
}

test "build imports resolve cached and vendored packages" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "cache/p/cached-hash");
    try tmp.dir.createDirPath(io, "zig-pkg/vendored-hash");
    try tmp.dir.writeFile(io, .{ .sub_path = "cache/p/cached-hash/build.zig", .data = "pub const Cached = true;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-pkg/vendored-hash/build.zig", .data = "pub const Vendored = true;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data =
        \\.{ .dependencies = .{
        \\    .cached = .{ .hash = "cached-hash" },
        \\    .vendored = .{ .hash = "vendored-hash" },
        \\    .missing = .{ .hash = "not-fetched" },
        \\} }
    });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const build_path = try std.Io.Dir.path.join(allocator, &.{ root, "build.zig" });
    defer allocator.free(build_path);
    const cache_path = try std.Io.Dir.path.join(allocator, &.{ root, "cache" });
    defer allocator.free(cache_path);
    for ([_][]const u8{ "cached", "vendored" }, [_][]const u8{ "cache/p/cached-hash/build.zig", "zig-pkg/vendored-hash/build.zig" }) |name, relative| {
        const actual = (try resolve(allocator, io, build_path, name, cache_path)) orelse return error.MissingDependency;
        defer allocator.free(actual);
        const expected = try std.Io.Dir.path.join(allocator, &.{ root, relative });
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expectEqual(@as(?[]u8, null), try resolve(allocator, io, build_path, "missing", cache_path));
    try std.testing.expectEqual(@as(?[]u8, null), try resolve(allocator, io, build_path, "unknown", cache_path));
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{" });
    try std.testing.expectEqual(@as(?[]u8, null), try resolve(allocator, io, build_path, "cached", cache_path));
}

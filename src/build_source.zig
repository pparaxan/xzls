//! Conservative fallback for module paths explicitly declared in build scripts.
const std = @import("std");
const Ast = std.zig.Ast;
const imports = @import("build_imports.zig");

pub const Module = struct {
    root: []const u8,
    imports: std.array_hash_map.String([]const u8) = .empty,
};

const Source = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    cache: ?[]const u8,
    tree: Ast,

    fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8, cache: ?[]const u8) error{OutOfMemory}!?Source {
        const text = std.Io.Dir.cwd().readFileAllocOptions(io, path, allocator, .limited(1024 * 1024), .of(u8), 0) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        const tree = try Ast.parse(allocator, text, .{});
        if (tree.errors.len != 0) return null;
        return .{ .allocator = allocator, .io = io, .path = path, .cache = cache, .tree = tree };
    }

    fn string(self: *const Source, node: Ast.Node.Index) error{OutOfMemory}!?[]const u8 {
        if (self.tree.nodeTag(node) != .string_literal) return null;
        return std.zig.string_literal.parseAlloc(self.allocator, self.tree.tokenSlice(self.tree.nodeMainToken(node))) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidLiteral => return null,
        };
    }

    fn member(self: *const Source, node: Ast.Node.Index, name: []const u8) bool {
        if (self.tree.nodeTag(node) != .field_access) return false;
        return std.mem.eql(u8, self.tree.tokenSlice(self.tree.nodeData(node).node_and_token[1]), name);
    }

    fn initializer(self: *const Source, node: Ast.Node.Index) ?Ast.Node.Index {
        if (self.tree.nodeTag(node) != .identifier) return null;
        const name = self.tree.tokenSlice(self.tree.nodeMainToken(node));
        var result: ?Ast.Node.Index = null;
        for (0..self.tree.nodes.len) |i| {
            const decl = self.tree.fullVarDecl(@fromBackingInt(@intCast(i))) orelse continue;
            if (!std.mem.eql(u8, self.tree.tokenSlice(decl.ast.mut_token + 1), name)) continue;
            // Duplicate names can belong to different scopes; do not guess.
            if (result != null) return null;
            result = decl.ast.init_node.unwrap();
        }
        return result;
    }

    fn rootPath(self: *const Source, node: Ast.Node.Index, depth: u8) error{OutOfMemory}!?[]const u8 {
        if (depth == 0) return null;
        if (self.initializer(node)) |value| return self.rootPath(value, depth - 1);
        if (self.member(node, "root_module")) return self.rootPath(self.tree.nodeData(node).node_and_token[0], depth - 1);
        var buffer: [1]Ast.Node.Index = undefined;
        const call = self.tree.fullCall(&buffer, node) orelse return null;
        if (self.member(call.ast.fn_expr, "module") and call.ast.params.len == 1) {
            const module_name = try self.string(call.ast.params[0]) orelse return null;
            var receiver = self.tree.nodeData(call.ast.fn_expr).node_and_token[0];
            var remaining = depth;
            while (self.initializer(receiver)) |value| {
                if (remaining == 0) return null;
                remaining -= 1;
                receiver = value;
            }
            var dependency_buffer: [1]Ast.Node.Index = undefined;
            const dependency = self.tree.fullCall(&dependency_buffer, receiver) orelse return null;
            if (!self.member(dependency.ast.fn_expr, "dependency") or dependency.ast.params.len == 0) return null;
            const name = try self.string(dependency.ast.params[0]) orelse return null;
            const path = imports.resolve(self.allocator, self.io, self.path, name, self.cache) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return null,
            } orelse return null;
            const source = try Source.open(self.allocator, self.io, path, self.cache) orelse return null;
            return source.exportedRoot(module_name, depth - 1);
        }
        const option_index: usize = if (self.member(call.ast.fn_expr, "addModule")) 1 else 0;
        if (call.ast.params.len <= option_index) return null;
        if (!self.member(call.ast.fn_expr, "addModule") and !self.member(call.ast.fn_expr, "createModule") and !self.member(call.ast.fn_expr, "addExecutable") and !self.member(call.ast.fn_expr, "addTest") and !self.member(call.ast.fn_expr, "addLibrary")) return null;
        const options = call.ast.params[option_index];
        if (imports.field(&self.tree, options, "root_module")) |root_module| return self.rootPath(root_module, depth - 1);
        const root_file = imports.field(&self.tree, options, "root_source_file") orelse return null;
        var path_buffer: [1]Ast.Node.Index = undefined;
        const path_call = self.tree.fullCall(&path_buffer, root_file) orelse return null;
        if (!self.member(path_call.ast.fn_expr, "path") or path_call.ast.params.len != 1) return null;
        const relative = try self.string(path_call.ast.params[0]) orelse return null;
        return try std.Io.Dir.path.resolveAlloc(self.allocator, &.{ std.Io.Dir.path.dirname(self.path) orelse return null, relative });
    }

    fn exportedRoot(self: *const Source, name: ?[]const u8, depth: u8) error{OutOfMemory}!?[]const u8 {
        var result: ?[]const u8 = null;
        for (0..self.tree.nodes.len) |i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            var buffer: [1]Ast.Node.Index = undefined;
            const call = self.tree.fullCall(&buffer, node) orelse continue;
            if (!self.member(call.ast.fn_expr, "addModule") or call.ast.params.len != 2) continue;
            if (name) |expected| {
                const actual = try self.string(call.ast.params[0]) orelse continue;
                if (!std.mem.eql(u8, expected, actual)) continue;
            }
            const path = try self.rootPath(node, depth) orelse continue;
            if (result) |previous| if (!std.mem.eql(u8, previous, path)) return null;
            result = path;
        }
        return result;
    }
};

/// All returned memory belongs to the caller's arena.
pub fn collect(arena: std.mem.Allocator, io: std.Io, path: []const u8, cache: ?[]const u8) error{OutOfMemory}![]Module {
    const source = try Source.open(arena, io, path, cache) orelse return &.{};
    var modules: std.array_hash_map.String(Module) = .empty;
    for (0..source.tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Ast.Node.Index = undefined;
        const call = source.tree.fullCall(&buffer, node) orelse continue;
        if (!source.member(call.ast.fn_expr, "addModule") and !source.member(call.ast.fn_expr, "createModule")) continue;
        const root = try source.rootPath(node, 32) orelse continue;
        const gop = try modules.getOrPutValue(arena, root, .{ .root = root });
        const options = call.ast.params[if (source.member(call.ast.fn_expr, "addModule")) @as(usize, 1) else 0];
        var list = imports.field(&source.tree, options, "imports") orelse continue;
        if (source.tree.nodeTag(list) == .address_of) list = source.tree.nodeData(list).node;
        var fields_buffer: [2]Ast.Node.Index = undefined;
        const fields = source.tree.fullArrayInit(&fields_buffer, list) orelse continue;
        for (fields.ast.elements) |entry| {
            const name = try imports.stringField(arena, &source.tree, entry, "name") orelse continue;
            const value = imports.field(&source.tree, entry, "module") orelse continue;
            const target = try source.rootPath(value, 32) orelse continue;
            try gop.value_ptr.imports.put(arena, name, target);
        }
    }
    for (0..source.tree.nodes.len) |i| {
        var buffer: [1]Ast.Node.Index = undefined;
        const call = source.tree.fullCall(&buffer, @fromBackingInt(@intCast(i))) orelse continue;
        if (!source.member(call.ast.fn_expr, "addImport") or call.ast.params.len != 2) continue;
        const receiver = source.tree.nodeData(call.ast.fn_expr).node_and_token[0];
        const root = try source.rootPath(receiver, 32) orelse continue;
        const module = modules.getPtr(root) orelse continue;
        const name = try source.string(call.ast.params[0]) orelse continue;
        const target = try source.rootPath(call.ast.params[1], 32) orelse continue;
        try module.imports.put(arena, name, target);
    }
    return modules.values();
}

pub fn uniqueExportedRoot(arena: std.mem.Allocator, io: std.Io, path: []const u8) error{OutOfMemory}!?[]const u8 {
    const source = try Source.open(arena, io, path, null) orelse return null;
    return source.exportedRoot(null, 32);
}

test "declared roots and dependency module names replace filename guesses" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dep");
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data =
        \\.{ .dependencies = .{ .@"package-name" = .{ .path = "dep" } } }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data =
        \\pub fn build(b: anytype) void {
        \\    const dependency = b.dependency("package-name", .{});
        \\    const application = b.addModule("exported-name", .{
        \\        .root_source_file = b.path("app/sola.zig"),
        \\        .imports = &.{.{ .name = "runtime-alias", .module = dependency.module("selected") }},
        \\    });
        \\    application.addImport("another-alias", dependency.module("selected"));
        \\    _ = b.addModule("dynamic", .{ .root_source_file = chooseRoot() });
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "dep/build.zig", .data =
        \\pub fn build(b: anytype) void {
        \\    _ = b.addModule("selected", .{ .root_source_file = b.path("runtime/custom.zig") });
        \\    _ = b.addModule("other", .{ .root_source_file = b.path("another/file.zig") });
        \\}
    });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    const path = try std.Io.Dir.path.join(allocator, &.{ root, "build.zig" });
    const modules = try collect(allocator, io, path, null);
    try std.testing.expectEqual(@as(usize, 1), modules.len);
    try std.testing.expectEqualStrings(try std.Io.Dir.path.join(allocator, &.{ root, "app/sola.zig" }), modules[0].root);
    const expected = try std.Io.Dir.path.join(allocator, &.{ root, "dep/runtime/custom.zig" });
    try std.testing.expectEqualStrings(expected, modules[0].imports.get("runtime-alias").?);
    try std.testing.expectEqualStrings(expected, modules[0].imports.get("another-alias").?);
    const dependency_path = try std.Io.Dir.path.join(allocator, &.{ root, "dep/build.zig" });
    try std.testing.expectEqual(@as(?[]const u8, null), try uniqueExportedRoot(allocator, io, dependency_path));
}

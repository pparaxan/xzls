//! Implementation of [`textDocument/publishDiagnostics`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_publishDiagnostics)

const std = @import("std");
const builtin = @import("builtin");
const Ast = std.zig.Ast;
const log = std.log.scoped(.diag);

const Server = @import("../Server.zig");
const DocumentStore = @import("../DocumentStore.zig");
const lsp = @import("lsp");
const types = lsp.types;
const Analyser = @import("../analysis.zig");
const ast = @import("../ast.zig");
const offsets = @import("../offsets.zig");
const Uri = @import("../Uri.zig");
const code_actions = @import("code_actions.zig");
const tracy = @import("tracy");

const Zir = std.zig.Zir;

pub fn generateDiagnostics(
    server: *Server,
    handle: *DocumentStore.Handle,
) Analyser.Error!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const config = &server.config_manager.config;

    var maybe_eb: ?*const std.zig.ErrorBundle = null;

    if (handle.tree.errors.len == 0) {
        const tracy_zone2 = tracy.traceNamed(@src(), "ast-check");
        defer tracy_zone2.end();

        var error_bundle = try getAstCheckDiagnostics(server, handle);
        errdefer error_bundle.deinit(server.allocator);

        try server.diagnostics_collection.pushSingleDocumentDiagnostics(
            .parse,
            handle.uri,
            .{ .error_bundle = error_bundle },
        );
        if (server.diagnostics_collection.tag_set.get(.parse)) |entry| {
            if (entry.diagnostics_set.get(handle.uri)) |per_doc| {
                maybe_eb = &per_doc.error_bundle;
            }
        }
    } else {
        var wip: std.zig.ErrorBundle.Wip = try .init(server.allocator);
        defer wip.deinit();

        try collectParseDiagnostics(&handle.tree, &wip);

        var error_bundle = try wip.toOwnedBundle("");
        errdefer error_bundle.deinit(server.allocator);

        try server.diagnostics_collection.pushSingleDocumentDiagnostics(
            .parse,
            handle.uri,
            .{ .error_bundle = error_bundle },
        );
        if (server.diagnostics_collection.tag_set.get(.parse)) |entry| {
            if (entry.diagnostics_set.get(handle.uri)) |per_doc| {
                maybe_eb = &per_doc.error_bundle;
            }
        }
    }

    {
        var arena_allocator: std.heap.ArenaAllocator = .init(server.diagnostics_collection.allocator);
        errdefer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        var diagnostics: std.ArrayList(types.Diagnostic) = .empty;

        if (handle.tree.mode == .zig) {
            var analyser = server.initAnalyser(arena, handle);
            defer analyser.deinit();
            try code_actions.collectAutoDiscardDiagnostics(&analyser, handle, arena, &diagnostics, server.offset_encoding);
            try collectResourceDiagnostics(&analyser, handle, arena, &diagnostics, server.offset_encoding);

            if (config.eager_semantic_check) {
                try collectEagerSemanticDiagnostics(&analyser, handle, maybe_eb, arena, &diagnostics, server.offset_encoding);
            }
        }

        if (config.warn_style and handle.tree.mode == .zig) {
            try collectWarnStyleDiagnostics(&handle.tree, arena, &diagnostics, server.offset_encoding);
        }

        if (config.highlight_global_var_declarations and handle.tree.mode == .zig) {
            try collectGlobalVarDiagnostics(&handle.tree, arena, &diagnostics, server.offset_encoding);
        }

        if (config.enable_checks and handle.tree.mode == .zig) {
            try collectDiagnostics(&handle.tree, arena, &diagnostics, server.offset_encoding, config);
        }

        try server.diagnostics_collection.pushSingleDocumentDiagnostics(
            .parse,
            handle.uri,
            .{ .lsp = .{ .arena = arena_allocator.state, .diagnostics = diagnostics.items } },
        );
    }

    std.debug.assert(server.client_capabilities.supports_publish_diagnostics);
    server.diagnostics_collection.publishDiagnostics() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => log.err("failed to publish diagnostics: {}", .{err}),
    };
}

fn collectParseDiagnostics(tree: *const Ast, eb: *std.zig.ErrorBundle.Wip) error{OutOfMemory}!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    if (tree.errors.len == 0) return;

    const allocator = eb.gpa;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var notes: std.ArrayList(std.zig.ErrorBundle.MessageIndex) = .empty;
    defer notes.deinit(allocator);

    const current_error = tree.errors[0];
    for (tree.errors[1..]) |err| {
        if (!err.is_note) break;

        aw.clearRetainingCapacity();
        tree.renderError(err, &aw.writer) catch return error.OutOfMemory;
        try notes.append(allocator, try eb.addErrorMessage(.{
            .msg = try eb.addString(aw.written()),
            .src_loc = try errorBundleSourceLocationFromToken(tree, eb, err.token),
        }));
    }

    aw.clearRetainingCapacity();
    tree.renderError(current_error, &aw.writer) catch return error.OutOfMemory;
    try eb.addRootErrorMessage(.{
        .msg = try eb.addString(aw.written()),
        .src_loc = try errorBundleSourceLocationFromToken(tree, eb, current_error.token),
        .notes_len = @intCast(notes.items.len),
    });

    const notes_start = try eb.reserveNotes(@intCast(notes.items.len));
    @memcpy(eb.extra.items[notes_start..][0..notes.items.len], @as([]const u32, @ptrCast(notes.items)));
}

fn errorBundleSourceLocationFromToken(
    tree: *const Ast,
    eb: *std.zig.ErrorBundle.Wip,
    token: Ast.TokenIndex,
) error{OutOfMemory}!std.zig.ErrorBundle.SourceLocationIndex {
    const loc = offsets.tokenToLoc(tree, token);
    const pos = offsets.indexToPosition(tree.source, loc.start, .@"utf-8");
    const line = offsets.lineSliceAtIndex(tree.source, loc.start);

    return try eb.addSourceLocation(.{
        .src_path = try eb.addString(""),
        .line = pos.line,
        .column = pos.character,
        .span_start = @intCast(loc.start),
        .span_main = @intCast(loc.start),
        .span_end = @intCast(loc.end),
        .source_line = try eb.addString(line),
    });
}

fn collectWarnStyleDiagnostics(
    tree: *const Ast,
    arena: std.mem.Allocator,
    diagnostics: *std.ArrayList(types.Diagnostic),
    offset_encoding: offsets.Encoding,
) error{OutOfMemory}!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (ast.isBuiltinCall(tree, node)) {
            const builtin_token = tree.nodeMainToken(node);
            const call_name = tree.tokenSlice(builtin_token);

            if (!std.mem.eql(u8, call_name, "@import")) continue;

            var buffer: [2]Ast.Node.Index = undefined;
            const params = tree.builtinCallParams(&buffer, node).?;

            if (params.len != 1) continue;

            const import_str_token = tree.nodeMainToken(params[0]);
            const import_str = tree.tokenSlice(import_str_token);

            if (std.mem.startsWith(u8, import_str, "\"./")) {
                try diagnostics.append(arena, .{
                    .range = offsets.tokenToRange(tree, import_str_token, offset_encoding),
                    .severity = .Hint,
                    .code = .{ .string = "dot_slash_import" },
                    .source = "zls",
                    .message = .{ .string = "A ./ is not needed in imports" },
                });
            }
        }
    }

    // TODO: style warnings for types, values and declarations below root scope
    if (tree.errors.len == 0) {
        for (tree.rootDecls()) |decl_idx| {
            const decl = tree.nodeTag(decl_idx);
            switch (decl) {
                .fn_proto,
                .fn_proto_multi,
                .fn_proto_one,
                .fn_proto_simple,
                .fn_decl,
                => blk: {
                    var buf: [1]Ast.Node.Index = undefined;
                    const func = tree.fullFnProto(&buf, decl_idx).?;
                    if (func.extern_export_inline_token != null) break :blk;

                    if (func.name_token) |name_token| {
                        const is_type_function = Analyser.isTypeFunction(tree, func);

                        const func_name = tree.tokenSlice(name_token);
                        if (!is_type_function and !isCamelCase(func_name)) {
                            try diagnostics.append(arena, .{
                                .range = offsets.tokenToRange(tree, name_token, offset_encoding),
                                .severity = .Hint,
                                .code = .{ .string = "bad_style" },
                                .source = "zls",
                                .message = .{ .string = "Functions should be camelCase" },
                            });
                        } else if (is_type_function and !isPascalCase(func_name)) {
                            try diagnostics.append(arena, .{
                                .range = offsets.tokenToRange(tree, name_token, offset_encoding),
                                .severity = .Hint,
                                .code = .{ .string = "bad_style" },
                                .source = "zls",
                                .message = .{ .string = "Type functions should be PascalCase" },
                            });
                        }
                    }
                },
                else => {},
            }
        }
    }
}

fn isCamelCase(name: []const u8) bool {
    return !std.ascii.isUpper(name[0]) and !isSnakeCase(name);
}

fn isPascalCase(name: []const u8) bool {
    return std.ascii.isUpper(name[0]) and !isSnakeCase(name);
}

fn isSnakeCase(name: []const u8) bool {
    return std.mem.find(u8, name, "_") != null;
}

fn collectGlobalVarDiagnostics(
    tree: *const Ast,
    arena: std.mem.Allocator,
    diagnostics: *std.ArrayList(types.Diagnostic),
    offset_encoding: offsets.Encoding,
) error{OutOfMemory}!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    for (tree.rootDecls()) |decl| {
        const decl_tag = tree.nodeTag(decl);
        const decl_main_token = tree.nodeMainToken(decl);

        switch (decl_tag) {
            .simple_var_decl,
            .aligned_var_decl,
            .local_var_decl,
            .global_var_decl,
            => {
                if (tree.tokenTag(tree.nodeMainToken(decl)) != .keyword_var) continue; // skip anything immutable
                // uncomment this to get a list :)
                //log.debug("possible global variable \"{s}\"", .{tree.tokenSlice(decl_main_token + 1)});
                try diagnostics.append(arena, .{
                    .range = offsets.tokenToRange(tree, decl_main_token, offset_encoding),
                    .severity = .Hint,
                    .code = .{ .string = "highlight_global_var_declarations" },
                    .source = "zls",
                    .message = .{ .string = "Global var declaration" },
                });
            },
            else => {},
        }
    }
}

/// caller owns the returned ErrorBundle
pub fn getAstCheckDiagnostics(server: *Server, handle: *DocumentStore.Handle) error{ Canceled, OutOfMemory }!std.zig.ErrorBundle {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    std.debug.assert(handle.tree.errors.len == 0);
    const config = &server.config_manager.config;

    if (std.process.can_spawn and
        config.prefer_ast_check_as_child_process and
        handle.tree.mode == .zig and // TODO pass `--zon` if available
        config.zig_exe_path != null)
    {
        return getErrorBundleFromAstCheck(
            server.io,
            server.allocator,
            config.zig_exe_path.?,
            handle.tree.source,
        ) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                log.err("failed to run ast-check: {}", .{err});
                return .empty;
            },
        };
    } else switch (handle.tree.mode) {
        .zig => {
            var zir = try std.zig.AstGen.generate(server.allocator, handle.tree);
            defer zir.deinit(server.allocator);

            if (!zir.hasCompileErrors()) return .empty;

            var eb: std.zig.ErrorBundle.Wip = try .init(server.allocator);
            defer eb.deinit();
            try eb.addZirErrorMessages(zir, handle.tree, handle.tree.source, "");
            return try eb.toOwnedBundle("");
        },
        .zon => {
            const zoir = try std.zig.ZonGen.generate(server.allocator, handle.tree, .{});
            defer zoir.deinit(server.allocator);

            if (!zoir.hasCompileErrors()) return .empty;

            var eb: std.zig.ErrorBundle.Wip = try .init(server.allocator);
            defer eb.deinit();
            try eb.addZoirErrorMessages(zoir, handle.tree, handle.tree.source, "");
            return try eb.toOwnedBundle("");
        },
    }
}

fn getErrorBundleFromAstCheck(
    io: std.Io,
    allocator: std.mem.Allocator,
    zig_exe_path: []const u8,
    source: [:0]const u8,
) !std.zig.ErrorBundle {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    comptime std.debug.assert(std.process.can_spawn);

    var process = std.process.spawn(io, .{
        .argv = &.{ zig_exe_path, "ast-check", "--color", "off" },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .pipe,
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            log.warn("Failed to spawn zig ast-check process, error: {}", .{err});
            return .empty;
        },
    };
    try process.stdin.?.writeStreamingAll(io, source);
    process.stdin.?.close(io);

    process.stdin = null;

    var buffer: [4096]u8 = undefined;
    var file_reader = process.stderr.?.readerStreaming(io, &buffer);
    const stderr = file_reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
    defer allocator.free(stderr);

    const term = try process.wait(io);
    switch (term) {
        .exited => return try getErrorBundleFromStderr(allocator, stderr, true, .{ .single_source_file = source }),
        .signal => |sig| std.log.err("zig ast-check failed with signal {t} and stderr:\n{s}", .{ sig, stderr }),
        .stopped => |sig| std.log.err("zig ast-check stopped with signal {d} and stderr:\n{s}", .{ sig, stderr }),
        .unknown => |code| std.log.err("zig ast-check failed for unknown reason with code {d} and stderr:\n{s}", .{ code, stderr }),
    }
    return .empty;
}

pub fn getErrorBundleFromStderr(
    allocator: std.mem.Allocator,
    stderr_bytes: []const u8,
    ignore_src_path: bool,
    path_resolution: union(enum) {
        single_source_file: [:0]const u8,
        dynamic: struct {
            document_store: *DocumentStore,
            /// file paths in stderr may be relative so we need to figure out the base path
            base_path: []const u8,
        },
    },
) !std.zig.ErrorBundle {
    if (stderr_bytes.len == 0) return .empty;

    var last_error_message: ?std.zig.ErrorBundle.ErrorMessage = null;
    var notes: std.ArrayList(std.zig.ErrorBundle.MessageIndex) = .empty;
    defer notes.deinit(allocator);

    var error_bundle: std.zig.ErrorBundle.Wip = try .init(allocator);
    defer error_bundle.deinit();

    const eb_empty_string = try error_bundle.addString("");

    var line_iterator = std.mem.splitScalar(u8, stderr_bytes, '\n');
    while (line_iterator.next()) |line| {
        // `{optional indentation}{src_path}:{line}:{column}: {msg}`
        var pos_and_diag_iterator = std.mem.splitScalar(u8, std.mem.trimStart(u8, line, " "), ':');
        const src_path = pos_and_diag_iterator.next() orelse continue;
        const line_string = pos_and_diag_iterator.next() orelse continue;
        const column_string = pos_and_diag_iterator.next() orelse continue;
        const msg = pos_and_diag_iterator.rest();

        const eb_src_path = if (ignore_src_path) eb_empty_string else try error_bundle.addString(src_path);

        // zig uses utf-8 encoding for character offsets
        const utf8_position: types.Position = .{
            .line = (std.fmt.parseInt(u32, line_string, 10) catch continue) -| 1,
            .character = (std.fmt.parseInt(u32, column_string, 10) catch continue) -| 1,
        };

        const maybe_source: ?[:0]const u8 = switch (path_resolution) {
            .single_source_file => |source| source,
            .dynamic => |dynamic| source: {
                const file_path = try std.Io.Dir.path.resolveAlloc(allocator, &.{ dynamic.base_path, src_path });
                defer allocator.free(file_path);
                const file_uri: Uri = try .fromPath(allocator, file_path);
                defer file_uri.deinit(allocator);
                const handle = try dynamic.document_store.getOrLoadHandle(file_uri) orelse break :source null;
                break :source handle.tree.source;
            },
        };

        const src_loc = if (maybe_source) |source| src_loc: {
            const source_index = offsets.positionToIndex(source, utf8_position, .@"utf-8");
            const source_loc = offsets.lineLocAtIndex(source, source_index);

            const loc = offsets.tokenIndexToLoc(source, source_index);

            break :src_loc try error_bundle.addSourceLocation(.{
                .src_path = eb_src_path,
                .line = utf8_position.line,
                .column = utf8_position.character,
                // span_start <= span_main <= span_end <= source_loc.end
                .span_start = @intCast(@min(source_index, loc.start)),
                .span_main = @intCast(source_index),
                .span_end = @intCast(@min(@max(source_index, loc.end), source_loc.end)),
                .source_line = try error_bundle.addString(offsets.locToSlice(source, source_loc)),
            });
        } else src_loc: {
            break :src_loc try error_bundle.addSourceLocation(.{
                .src_path = eb_src_path,
                .line = utf8_position.line,
                .column = utf8_position.character,
                .span_start = 0,
                .span_main = 0,
                .span_end = 0,
                .source_line = 0,
            });
        };

        if (std.mem.startsWith(u8, msg, " note: ")) {
            try notes.append(allocator, try error_bundle.addErrorMessage(.{
                .msg = try error_bundle.addString(msg[" note: ".len..]),
                .src_loc = src_loc,
            }));
            continue;
        }

        const message = if (std.mem.startsWith(u8, msg, " error: ")) msg[" error: ".len..] else msg;

        if (last_error_message) |*em| {
            em.notes_len = @intCast(notes.items.len);
            try error_bundle.addRootErrorMessage(em.*);
            const notes_start = try error_bundle.reserveNotes(em.notes_len);
            @memcpy(error_bundle.extra.items[notes_start..][0..em.notes_len], @as([]const u32, @ptrCast(notes.items)));

            notes.clearRetainingCapacity();
            last_error_message = null;
        }

        last_error_message = .{
            .msg = try error_bundle.addString(message),
            .src_loc = src_loc,
            .notes_len = undefined, // set later
        };
    }

    if (last_error_message) |*em| {
        em.notes_len = @intCast(notes.items.len);
        try error_bundle.addRootErrorMessage(em.*);
        const notes_start = try error_bundle.reserveNotes(em.notes_len);
        @memcpy(error_bundle.extra.items[notes_start..][0..em.notes_len], @as([]const u32, @ptrCast(notes.items)));
    }

    return try error_bundle.toOwnedBundle("");
}

fn isLineInErrorBundle(eb: *const std.zig.ErrorBundle, line: u32) bool {
    if (eb.errorMessageCount() == 0) return false;
    for (eb.getMessages()) |msg_index| {
        const err = eb.getErrorMessage(msg_index);
        if (err.src_loc == .none) continue;
        const src_loc = eb.getSourceLocation(err.src_loc);
        if (src_loc.line == line) return true;
    }
    return false;
}

fn findEnclosingFunction(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    const node_loc = offsets.nodeToLoc(tree, node);
    var best_fn: ?Ast.Node.Index = null;
    var best_len: usize = std.math.maxInt(usize);

    for (0..tree.nodes.len) |idx| {
        const candidate: Ast.Node.Index = @fromBackingInt(@intCast(idx));
        if (tree.nodeTag(candidate) == .fn_decl) {
            const fn_loc = offsets.nodeToLoc(tree, candidate);
            if (fn_loc.start <= node_loc.start and fn_loc.end >= node_loc.end) {
                const len = fn_loc.end - fn_loc.start;
                if (len < best_len) {
                    best_len = len;
                    best_fn = candidate;
                }
            }
        }
    }
    return best_fn;
}

const ResourceKind = enum { memory, file, mutex };

fn isReleaseName(name: []const u8, custom_release: ?[]const u8, resource_kind: ResourceKind) bool {
    if (custom_release) |rel_fn| {
        if (std.mem.eql(u8, name, rel_fn)) return true;
    }
    return switch (resource_kind) {
        .memory => std.mem.eql(u8, name, "free") or
            std.mem.eql(u8, name, "destroy") or
            std.mem.eql(u8, name, "deinit"),
        .file => std.mem.eql(u8, name, "close"),
        .mutex => std.mem.eql(u8, name, "unlock"),
    };
}

fn checkResourceRelease(
    tree: *const Ast,
    fn_node: Ast.Node.Index,
    var_name: []const u8,
    resource_kind: ResourceKind,
    custom_release: ?[]const u8,
) bool {
    if (tree.nodeTag(fn_node) != .fn_decl) return true;
    const body_node = tree.nodeData(fn_node).node_and_node[1];
    const first_tok = tree.firstToken(body_node);
    const last_tok = tree.lastToken(body_node);
    if (first_tok > last_tok or last_tok >= tree.tokens.len) return true;

    var tok = first_tok;
    while (tok <= last_tok) : (tok += 1) {
        const tag = tree.tokenTag(tok);

        // Pattern 1: `return ... var_name ...`
        if (tag == .keyword_return) {
            var ret_tok = tok + 1;
            while (ret_tok <= last_tok and tree.tokenTag(ret_tok) != .semicolon) : (ret_tok += 1) {
                if (tree.tokenTag(ret_tok) == .identifier) {
                    const id_name = offsets.tokenToSlice(tree, ret_tok);
                    if (std.mem.eql(u8, id_name, var_name)) return true;
                }
            }
        }

        // Pattern 2: Call to release function
        if (tag == .identifier) {
            const id_name = offsets.tokenToSlice(tree, tok);
            if (isReleaseName(id_name, custom_release, resource_kind)) {
                // Must be a call: followed by `(`
                if (tok + 1 <= last_tok and tree.tokenTag(tok + 1) == .l_paren) {
                    // Subpattern 2A: Method call, e.g. `var_name.deinit()` or `(&var_name).deinit()`
                    if (tok > first_tok and tree.tokenTag(tok - 1) == .period) {
                        var prev = tok - 1;
                        while (prev > first_tok) {
                            prev -= 1;
                            const prev_tag = tree.tokenTag(prev);
                            if (prev_tag == .r_paren or prev_tag == .period_asterisk or prev_tag == .question_mark or prev_tag == .asterisk or prev_tag == .ampersand) {
                                continue;
                            }
                            if (prev_tag == .identifier) {
                                const lhs_id = offsets.tokenToSlice(tree, prev);
                                if (std.mem.eql(u8, lhs_id, var_name)) return true;
                            }
                            break;
                        }
                    }

                    // Subpattern 2B: Argument inside `rel_fn(..., var_name, ...)`
                    // e.g. `allocator.free(buf)` or `deinit(&var_name)`
                    var depth: usize = 0;
                    var arg_tok = tok + 1;
                    while (arg_tok <= last_tok) : (arg_tok += 1) {
                        const atag = tree.tokenTag(arg_tok);
                        if (atag == .l_paren) {
                            depth += 1;
                        } else if (atag == .r_paren) {
                            depth -= 1;
                            if (depth == 0) break;
                        } else if (atag == .identifier) {
                            const arg_id = offsets.tokenToSlice(tree, arg_tok);
                            if (std.mem.eql(u8, arg_id, var_name)) return true;
                        }
                    }
                }
            }
        }
    }

    return false;
}

fn parseReleaseComment(doc_comments: []const u8) ?[]const u8 {
    // Look for `[release]: [func_name](optional_path)` or `[release]: func_name` or `[release]: [func_name]`
    const key = "[release]:";
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, doc_comments, idx, key)) |k_idx| {
        var rest = std.mem.trim(u8, doc_comments[k_idx + key.len ..], " \t\r");
        if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            rest = rest[0..nl];
        }
        rest = std.mem.trim(u8, rest, " \t\r");
        if (rest.len > 0 and rest[0] == '[') {
            if (std.mem.indexOfScalar(u8, rest, ']')) |rb| {
                var fn_name = rest[1..rb];
                if (std.mem.endsWith(u8, fn_name, "()")) fn_name = fn_name[0 .. fn_name.len - 2];
                return fn_name;
            }
        }
        var end: usize = 0;
        while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) : (end += 1) {}
        if (end > 0) {
            return rest[0..end];
        }
        idx = k_idx + key.len;
    }
    return null;
}

fn isExplicitAllocatorType(analyser: *Analyser, ty: Analyser.Type) bool {
    var curr_ty = ty;
    while (curr_ty.data == .pointer) {
        curr_ty = curr_ty.data.pointer.elem_ty.*;
    }
    const rendered_str = curr_ty.stringifyTypeOf(analyser, .{ .truncate_container_decls = true }) catch return false;
    return std.mem.eql(u8, rendered_str, "std.mem.Allocator") or
        std.mem.eql(u8, rendered_str, "mem.Allocator") or
        std.mem.eql(u8, rendered_str, "Allocator");
}

pub fn collectResourceDiagnostics(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    arena: std.mem.Allocator,
    diagnostics: *std.ArrayList(types.Diagnostic),
    offset_encoding: offsets.Encoding,
) error{ Canceled, OutOfMemory }!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const tree = &handle.tree;
    if (tree.errors.len != 0) return;

    for (0..tree.nodes.len) |node_idx| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(node_idx));
        const tag = tree.nodeTag(node);

        switch (tag) {
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            .assign,
            => {
                var name_token: Ast.TokenIndex = undefined;
                var init_node_raw: Ast.Node.Index = undefined;

                if (tag == .assign) {
                    const lhs_node, const rhs_node = tree.nodeData(node).node_and_node;
                    if (tree.nodeTag(lhs_node) != .identifier) continue;
                    name_token = tree.nodeMainToken(lhs_node);
                    init_node_raw = rhs_node;
                } else {
                    const var_decl = tree.fullVarDecl(node) orelse continue;
                    // Only warn on `var` declarations — `const` bindings are not
                    // the resource owner and would produce false positives.
                    if (tree.tokenTag(var_decl.ast.mut_token) != .keyword_var) continue;
                    name_token = var_decl.ast.mut_token + 1;
                    if (tree.tokenTag(name_token) != .identifier) continue;
                    init_node_raw = var_decl.ast.init_node.unwrap() orelse continue;
                }

                const var_name = offsets.identifierTokenToNameSlice(tree, name_token);
                if (var_name.len == 0 or std.mem.eql(u8, var_name, "_")) continue;

                var init_node = init_node_raw;
                while (true) {
                    switch (tree.nodeTag(init_node)) {
                        .@"try" => {
                            init_node = tree.nodeData(init_node).node;
                        },
                        .@"catch" => {
                            init_node = tree.nodeData(init_node).node_and_node[0];
                        },
                        else => break,
                    }
                }

                var buf: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&buf, init_node) orelse continue;
                const called_fn_expr = call.ast.fn_expr;

                var res_kind: ?ResourceKind = null;
                var custom_release: ?[]const u8 = null;

                // Check doc comments on the called function for `[release]: ...`
                if (analyser.resolveTypeOfNode(.of(called_fn_expr, handle)) catch null) |callee_ty| {
                    if (analyser.resolveFuncProtoOfCallable(callee_ty) catch null) |fn_ty| {
                        if (fn_ty.data.function.doc_comments) |docs| {
                            if (parseReleaseComment(docs)) |rel_fn| {
                                custom_release = rel_fn;
                            }
                        }
                    }
                }

                if (tree.nodeTag(called_fn_expr) == .field_access) {
                    const lhs_node = tree.nodeData(called_fn_expr).node_and_token[0];
                    const rhs_tok = tree.nodeData(called_fn_expr).node_and_token[1];
                    const method = offsets.tokenToSlice(tree, rhs_tok);
                    if (std.mem.eql(u8, method, "alloc") or
                        std.mem.eql(u8, method, "allocSentinel") or
                        std.mem.eql(u8, method, "allocWithOptions") or
                        std.mem.eql(u8, method, "create") or
                        std.mem.eql(u8, method, "dupe") or
                        std.mem.eql(u8, method, "dupeZ") or
                        std.mem.eql(u8, method, "dupeSentinel"))
                    {
                        // Avoid false positives like Step.Compile.create, @import(...).create,
                        // or factory functions named create() in build scripts and structs.
                        // For create(), we strictly require type resolution to confirm an Allocator type.
                        var is_allocator = false;
                        if (analyser.resolveTypeOfNode(.of(lhs_node, handle)) catch null) |lhs_ty| {
                            is_allocator = isExplicitAllocatorType(analyser, lhs_ty);
                        } else if (!std.mem.eql(u8, method, "create") and tree.nodeTag(lhs_node) == .identifier) {
                            const callee_name = offsets.identifierTokenToNameSlice(tree, tree.nodeMainToken(lhs_node));
                            if (std.mem.eql(u8, callee_name, "allocator") or
                                std.mem.eql(u8, callee_name, "gpa") or
                                std.mem.eql(u8, callee_name, "arena"))
                            {
                                is_allocator = true;
                            }
                        }
                        if (is_allocator) {
                            res_kind = .memory;
                        }
                    } else if (std.mem.eql(u8, method, "openFile") or
                        std.mem.eql(u8, method, "createFile") or
                        std.mem.eql(u8, method, "openDir") or
                        std.mem.eql(u8, method, "makeDir"))
                    {
                        res_kind = .file;
                    } else if (std.mem.eql(u8, method, "lock")) {
                        res_kind = .mutex;
                    }
                }

                if (custom_release != null or res_kind != null) {
                    if (findEnclosingFunction(tree, node)) |fn_node| {
                        const kind = res_kind orelse .memory;
                        if (!checkResourceRelease(tree, fn_node, var_name, kind, custom_release)) {
                            const range = offsets.tokenToRange(tree, name_token, offset_encoding);
                            const msg = if (custom_release) |rel_fn|
                                try std.fmt.allocPrint(arena, "resource '{s}' allocated but never freed with {s}", .{ var_name, rel_fn })
                            else switch (kind) {
                                .memory => try std.fmt.allocPrint(arena, "resource '{s}' allocated but never freed with free/destroy", .{var_name}),
                                .file => try std.fmt.allocPrint(arena, "resource '{s}' opened but never closed with close()", .{var_name}),
                                .mutex => try std.fmt.allocPrint(arena, "mutex '{s}' locked but never unlocked with unlock()", .{var_name}),
                            };
                            try diagnostics.append(arena, .{
                                .range = range,
                                .severity = .Warning,
                                .code = null,
                                .source = "xzls-resource",
                                .message = .{ .string = msg },
                            });
                        }
                    }
                }
            },
            else => {},
        }
    }
}

pub fn collectEagerSemanticDiagnostics(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    maybe_eb: ?*const std.zig.ErrorBundle,
    arena: std.mem.Allocator,
    diagnostics: *std.ArrayList(types.Diagnostic),
    offset_encoding: offsets.Encoding,
) error{ Canceled, OutOfMemory }!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const tree = &handle.tree;
    if (tree.errors.len != 0) return;

    for (0..tree.nodes.len) |node_idx| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(node_idx));
        const tag = tree.nodeTag(node);

        switch (tag) {
            .identifier => {
                const token = tree.nodeMainToken(node);
                const name = offsets.identifierTokenToNameSlice(tree, token);
                if (name.len == 0 or std.mem.eql(u8, name, "_")) continue;
                if ((analyser.resolvePrimitive(name) catch null) != null) continue;

                const pos = tree.tokenStart(token);
                const resolved = analyser.lookupSymbolGlobal(handle, name, pos) catch null;
                if (resolved == null) {
                    const range = offsets.tokenToRange(tree, token, offset_encoding);
                    if (maybe_eb) |eb| {
                        if (isLineInErrorBundle(eb, range.start.line)) continue;
                    }
                    try diagnostics.append(arena, .{
                        .range = range,
                        .severity = .Error,
                        .code = null,
                        .source = "xzls-eager",
                        .message = .{ .string = try std.fmt.allocPrint(arena, "use of undeclared identifier '{s}'", .{name}) },
                    });
                }
            },
            .field_access => {
                const data = tree.nodeData(node).node_and_token;
                const lhs_node = data[0];
                const rhs_token = data[1];
                if (tree.tokenTag(rhs_token) != .identifier) continue;
                const member_name = offsets.identifierTokenToNameSlice(tree, rhs_token);

                // Common builtin field names on slices/pointers/tuples/types
                if (std.mem.eql(u8, member_name, "len") or
                    std.mem.eql(u8, member_name, "ptr") or
                    std.mem.eql(u8, member_name, "init") or
                    std.mem.eql(u8, member_name, "deinit")) continue;

                if (analyser.resolveTypeOfNode(.of(lhs_node, handle)) catch null) |lhs_ty| {
                    if (lhs_ty.data == .container) {
                        // ZON containers store values, not Zig declarations — skip all field checks.
                        if (lhs_ty.data.container.scope_handle.handle.tree.mode == .zon) continue;
                        const decl = lhs_ty.lookupSymbol(analyser, member_name) catch null;
                        if (decl == null) {
                            const range = offsets.tokenToRange(tree, rhs_token, offset_encoding);
                            if (maybe_eb) |eb| {
                                if (isLineInErrorBundle(eb, range.start.line)) continue;
                            }
                            try diagnostics.append(arena, .{
                                .range = range,
                                .severity = .Error,
                                .code = null,
                                .source = "xzls-eager",
                                .message = .{ .string = try std.fmt.allocPrint(arena, "no member or method named '{s}' on type", .{member_name}) },
                            });
                        }
                    }
                }
            },
            .call_one,
            .call_one_comma,
            .call,
            .call_comma,
            => {
                var params_buf: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&params_buf, node) orelse continue;

                const ty = (analyser.resolveTypeOfNode(.of(call.ast.fn_expr, handle)) catch null) orelse continue;
                const fn_ty = (analyser.resolveFuncProtoOfCallable(ty) catch null) orelse continue;
                const fn_info = fn_ty.data.function;

                var has_self_param = (call.ast.params.len + 1 == fn_info.parameters.len) and
                    ((analyser.isInstanceCall(handle, call, fn_ty) catch false));

                // If isInstanceCall couldn't resolve the type (e.g., conditional comptime type or generic container),
                // but the call is syntactically a method call (obj.method(...)) and the function has exactly one more parameter
                // whose first parameter name is typically `self`, treat it as an instance call.
                if (!has_self_param and call.ast.params.len + 1 == fn_info.parameters.len and tree.nodeTag(call.ast.fn_expr) == .field_access) {
                    if (fn_info.parameters.len > 0) {
                        const first_param = fn_info.parameters[0];
                        if (first_param.name) |pname| {
                            if (std.mem.eql(u8, pname, "self") or std.mem.eql(u8, pname, "this")) {
                                has_self_param = true;
                            }
                        }
                    }
                }

                const expected_count = fn_info.parameters.len - @intFromBool(has_self_param);
                const actual_count = call.ast.params.len;

                if (actual_count != expected_count) {
                    const call_loc = offsets.nodeToLoc(tree, node);
                    const range = offsets.locToRange(tree.source, call_loc, offset_encoding);
                    if (maybe_eb) |eb| {
                        if (isLineInErrorBundle(eb, range.start.line)) continue;
                    }
                    try diagnostics.append(arena, .{
                        .range = range,
                        .severity = .Error,
                        .code = null,
                        .source = "xzls-eager",
                        .message = .{ .string = try std.fmt.allocPrint(arena, "expected {d} argument(s), found {d}", .{ expected_count, actual_count }) },
                    });
                }
            },
            else => {},
        }
    }
}

fn isUndefinedNode(tree: *const Ast, node: Ast.Node.Index) bool {
    if (tree.nodeTag(node) != .identifier) return false;
    const token = tree.nodeMainToken(node);
    return std.mem.eql(u8, offsets.tokenToSlice(tree, token), "undefined");
}

// TODO: Update this function name later.
fn collectDiagnostics(
    tree: *const Ast,
    arena: std.mem.Allocator,
    diagnostics: *std.ArrayList(types.Diagnostic),
    offset_encoding: offsets.Encoding,
    config: *const @import("../Config.zig"),
) error{OutOfMemory}!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const root_decls = tree.rootDecls();

    // Orphans declarations.
    if (config.orphans) {
        var ident_counts: std.StringHashMapUnmanaged(usize) = .{};
        for (0..tree.tokens.len) |tok_idx| {
            if (tree.tokenTag(@intCast(tok_idx)) == .identifier) {
                const name = offsets.tokenToSlice(tree, @intCast(tok_idx));
                const gop = try ident_counts.getOrPut(arena, name);
                if (gop.found_existing) {
                    gop.value_ptr.* += 1;
                } else {
                    gop.value_ptr.* = 1;
                }
            }
        }

        for (root_decls) |decl_node| {
            if (tree.fullVarDecl(decl_node)) |var_decl| {
                if (var_decl.visib_token != null) continue;
                const name_tok = var_decl.ast.mut_token + 1;
                if (name_tok >= tree.tokens.len or tree.tokenTag(name_tok) != .identifier) continue;
                const name = offsets.tokenToSlice(tree, name_tok);
                if (std.mem.startsWith(u8, name, "_")) continue;

                if (ident_counts.get(name)) |cnt| {
                    if (cnt <= 1) {
                        const range = offsets.tokenToRange(tree, name_tok, offset_encoding);
                        try diagnostics.append(arena, .{
                            .range = range,
                            .severity = .Warning,
                            .source = "xzls",
                            .message = .{
                                .string = try std.fmt.allocPrint(arena, "Declaration '{s}' is never used.", .{
                                    name,
                                }),
                            },
                        });
                    }
                }
            }
        }
    }

    // Walk nodes for `suppressed-errors` and `unsafe-undefined`.
    var idx: usize = 0;
    while (idx < tree.nodes.len) : (idx += 1) {
        const node_idx: Ast.Node.Index = @enumFromInt(idx);
        const tag = tree.nodeTag(node_idx);

        // Suppressed errors such as `catch {}`.
        if (config.suppressed_errors and tag == .@"catch") {
            const data = tree.nodeData(node_idx);
            const caught = data.node_and_node[0];
            const catch_body = data.node_and_node[1];

            var is_writer_call = false;
            const callee_node: ?Ast.Node.Index = switch (tree.nodeTag(caught)) {
                .call, .call_comma => tree.nodeData(caught).node_and_extra[0],
                .call_one, .call_one_comma => tree.nodeData(caught).node_and_opt_node[0],
                else => null,
            };
            if (callee_node) |callee| {
                if (tree.nodeTag(callee) == .field_access) {
                    const field_tok = tree.nodeData(callee).node_and_token[1];
                    const method_name = offsets.tokenToSlice(tree, field_tok);
                    if (std.mem.eql(u8, method_name, "print") or
                        std.mem.eql(u8, method_name, "write") or
                        std.mem.eql(u8, method_name, "writeAll") or
                        std.mem.eql(u8, method_name, "writeByte"))
                    {
                        is_writer_call = true;
                    }
                }
            }

            if (!is_writer_call) {
                const body_tag = tree.nodeTag(catch_body);
                if (body_tag == .unreachable_literal) {
                    const range = offsets.nodeToRange(tree, catch_body, offset_encoding);
                    try diagnostics.append(arena, .{
                        .range = range,
                        .severity = .Warning,
                        .source = "xzls",
                        .message = .{
                            .string = "Caught error is mishandled with `unreachable`.",
                        },
                    });
                } else if (body_tag == .block_two or body_tag == .block_two_semicolon) {
                    const opt_nodes = tree.nodeData(catch_body).opt_node_and_opt_node;
                    if (opt_nodes[1] == .none) {
                        if (opt_nodes[0].unwrap()) |first_stmt| {
                            if (tree.nodeTag(first_stmt) == .unreachable_literal) {
                                const range = offsets.nodeToRange(tree, first_stmt, offset_encoding);
                                try diagnostics.append(arena, .{
                                    .range = range,
                                    .severity = .Warning,
                                    .source = "xzls",
                                    .message = .{
                                        .string = "Caught error is mishandled with `unreachable`.",
                                    },
                                });
                            }
                        } else {
                            const range = offsets.nodeToRange(tree, catch_body, offset_encoding);
                            try diagnostics.append(arena, .{
                                .range = range,
                                .severity = .Warning,
                                .source = "xzls",
                                .message = .{
                                    .string = "`catch` statement suppresses errors without handling.",
                                },
                            });
                        }
                    }
                }
            }
        }

        // Unsafe undefined.
        if (config.unsafe_undefined) {
            if (tag == .equal_equal or tag == .bang_equal) {
                const pair = tree.nodeData(node_idx).node_and_node;
                if (isUndefinedNode(tree, pair[0]) or isUndefinedNode(tree, pair[1])) {
                    const range = offsets.nodeToRange(tree, node_idx, offset_encoding);
                    try diagnostics.append(arena, .{
                        .range = range,
                        .severity = .Error,
                        .source = "zlint",
                        .message = .{
                            .string = "Comparison with `undefined` is undefined behavior.",
                        },
                    });
                }
            }

            if (tree.fullVarDecl(node_idx)) |var_decl| {
                if (var_decl.ast.init_node.unwrap()) |init_node| {
                    if (isUndefinedNode(tree, init_node)) {
                        var is_array = false;
                        if (var_decl.ast.type_node.unwrap()) |type_node| {
                            const type_tag = tree.nodeTag(type_node);
                            if (type_tag == .array_type or type_tag == .array_type_sentinel) {
                                is_array = true;
                            }
                        }

                        if (!is_array) {
                            const mut_tok = var_decl.ast.mut_token;
                            const start_idx = tree.tokenStart(mut_tok);
                            const line_start = std.mem.lastIndexOfScalar(u8, tree.source[0..start_idx], '\n') orelse 0;
                            const prev_line_start = if (line_start > 0)
                                (std.mem.lastIndexOfScalar(u8, tree.source[0..line_start - 1], '\n') orelse 0)
                            else
                                0;
                            const context_window = tree.source[prev_line_start..start_idx];
                            const has_safety = std.mem.indexOf(u8, context_window, "SAFETY:") != null;

                            if (!has_safety) {
                                const range = offsets.nodeToRange(tree, init_node, offset_encoding);
                                try diagnostics.append(arena, .{
                                    .range = range,
                                    .severity = .Warning,
                                    .source = "xzls",
                                    .message = .{
                                        .string = "Initializing to `undefined` requires a `// SAFETY:` comment explaining why it's safe.",
                                    },
                                });
                            }
                        }
                    }
                }
            }
        }
    }
}

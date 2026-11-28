const std = @import("std");
const zig_builtin = @import("builtin");
const exe_options = @import("exe_options");

const tracy = @import("tracy");
const known_folders = @import("known-folders");

pub const build_options = @import("build_options");
pub const lsp = @import("lsp");

pub const analyser = @import("analyser/analyser.zig");

pub const Analyser = @import("analysis.zig");
pub const ast = @import("ast.zig");
pub const BuildAssociatedConfig = @import("BuildAssociatedConfig.zig");
pub const Config = @import("Config.zig");
pub const configuration = @import("configuration.zig");
pub const DiagnosticsCollection = @import("DiagnosticsCollection.zig");
pub const diff = @import("diff.zig");
pub const DocumentScope = @import("DocumentScope.zig");
pub const DocumentStore = @import("DocumentStore.zig");
pub const offsets = @import("offsets.zig");
pub const print_ast = @import("print_ast.zig");
pub const Server = @import("Server.zig");
pub const snippets = @import("snippets.zig");
pub const testing = @import("testing.zig");
pub const TrigramStore = @import("TrigramStore.zig");
pub const Uri = @import("Uri.zig");

pub const code_actions = @import("features/code_actions.zig");
pub const completions = @import("features/completions.zig");
pub const diagnostics = @import("features/diagnostics.zig");
pub const document_symbol = @import("features/document_symbol.zig");
pub const folding_range = @import("features/folding_range.zig");
pub const goto = @import("features/goto.zig");
pub const hover = @import("features/hover.zig");
pub const inlay_hints = @import("features/inlay_hints.zig");
pub const references = @import("features/references.zig");
pub const selection_range = @import("features/selection_range.zig");
pub const semantic_tokens = @import("features/semantic_tokens.zig");
pub const signature_help = @import("features/signature_help.zig");
pub const ssr = @import("features/ssr.zig");
pub const workspace_symbols = @import("features/workspace_symbols.zig");

const xzls = @This();

const log = std.log.scoped(.main);

const usage =
    \\XZLS - A non-official language server for Zig.
    \\
    \\Commands:
    \\  help, --help,             Print this help and exit
    \\  version, --version        Print version number and exit
    \\  env                       Print config path, log path and version
    \\
    \\General Options:
    \\  --config-path [path]      Set path to the 'xzls.json' configuration file
    \\  --log-file [path]         Set path to the 'xzls.log' log file
    \\  --log-level [enum]        The Log Level to be used.
    \\                              Supported Values:
    \\                                err
    \\                                warn
    \\                                info (default)
    \\                                debug
    \\
    \\Advanced Options:
    \\  --enable-stderr-logs      Write log message to stderr
    \\  --disable-lsp-logs        Disable LSP 'window/logMessage' messages
    \\
;

pub const std_options: std.Options = .{
    // Always set this to debug to make std.log call into our handler, then control the runtime
    // value in logFn itself
    .log_level = .debug,
    .logFn = logFn,
    .networking = false,
};

/// Log messages with the LSP 'window/logMessage' message.
var log_transport: ?*xzls.lsp.Transport = null;
/// Log messages to stderr.
var log_stderr: bool = true;
/// Log messages to the given file.
var log_file: ?std.Io.File = null;
var log_level: std.log.Level = if (zig_builtin.mode == .debug) .debug else .info;

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [4096]u8 = undefined;
    comptime std.debug.assert(buffer.len >= xzls.lsp.minimum_logging_buffer_size);

    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);

    if (log_transport) |transport| {
        const lsp_message_type: xzls.lsp.types.window.MessageType = switch (level) {
            .err => .Error,
            .warn => .Warning,
            .info => .Info,
            .debug => .Debug,
        };
        const json_message = xzls.lsp.bufPrintLogMessage(&buffer, lsp_message_type, format, args);
        transport.writeJsonMessage(io, json_message) catch |err| switch (err) {
            error.Canceled => unreachable,
            else => {},
        };
    }

    if (@backingInt(level) > @backingInt(log_level)) return;
    if (!log_stderr and log_file == null) return;

    const level_txt: []const u8 = switch (level) {
        .err => "error",
        .warn => "warn ",
        .info => "info ",
        .debug => "debug",
    };
    const scope_txt: []const u8 = comptime @tagName(scope);

    var writer: std.Io.Writer = .fixed(&buffer);
    const no_space_left = blk: {
        writer.print("{s} ({s:^6}): ", .{ level_txt, scope_txt }) catch break :blk true;
        writer.print(format, args) catch break :blk true;
        writer.writeByte('\n') catch break :blk true;
        break :blk false;
    };
    if (no_space_left) {
        const trailing = "...\n".*;
        writer.undo(trailing.len -| writer.unusedCapacityLen());
        (writer.writableArray(trailing.len) catch unreachable).* = trailing;
    }

    if (log_stderr) {
        const stderr = io.lockStderr(&.{}, null) catch |err| switch (err) {
            error.Canceled => unreachable,
        };
        defer io.unlockStderr();
        stderr.file_writer.interface.writeAll(writer.buffered()) catch {};
    }

    if (log_file) |file| {
        const is_locked = if (file.lock(io, .exclusive)) |_| true else |_| false;
        defer if (is_locked) file.unlock(io);
        if (file.length(io)) |length| {
            file.writePositionalAll(io, writer.buffered(), length) catch {};
        } else |_| {
            // Io currently provides no way to seek to the end of a file. This
            // may clobber logs from other processes.
            file.writeStreamingAll(io, writer.buffered()) catch {};
        }
    }
}

fn defaultLogFilePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) error{ Canceled, OutOfMemory }!?[]const u8 {
    if (zig_builtin.target.os.tag == .wasi) return null;
    const cache_path = try known_folders.getPath(io, allocator, environ_map, .cache) orelse return null;
    defer allocator.free(cache_path);
    return try std.Io.Dir.path.join(allocator, &.{ cache_path, "zls", "xzls.log" });
}

fn createLogFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    override_log_file_path: ?[]const u8,
) error{ Canceled, OutOfMemory }!?struct { std.Io.File, []const u8 } {
    const log_file_path = if (override_log_file_path) |log_file_path|
        try allocator.dupe(u8, log_file_path)
    else
        try defaultLogFilePath(io, allocator, environ_map) orelse return null;
    errdefer allocator.free(log_file_path);

    if (std.Io.Dir.path.dirname(log_file_path)) |dirname| {
        std.Io.Dir.cwd().createDirPath(io, dirname) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {},
        };
    }

    const file = std.Io.Dir.cwd().createFile(io, log_file_path, .{ .truncate = false }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            allocator.free(log_file_path);
            return null;
        },
    };
    errdefer file.close(io);

    return .{ file, log_file_path };
}

/// Output format of `zls env`
const Env = struct {
    /// The ZLS version. Guaranteed to be a [semantic version](https://semver.org/).
    ///
    /// The semantic version can have one of the following formats:
    /// - `MAJOR.MINOR.PATCH` is a tagged release of ZLS
    /// - `MAJOR.MINOR.PATCH-dev.COMMIT_HEIGHT+SHORT_COMMIT_HASH` is a development build of ZLS
    /// - `MAJOR.MINOR.PATCH-dev` is a development build of ZLS where the exact version could not be resolved.
    ///
    version: []const u8,
    global_cache_dir: ?[]const u8,
    /// Path to a global configuration directory relative to which ZLS configuration files will be searched.
    /// Not `null` unless [known-folders](https://github.com/ziglibs/known-folders) was unable to find a global configuration directory.
    global_config_dir: ?[]const u8,
    /// Path to a user specific configuration directory relative to which configuration files will be searched.
    /// Not `null` unless [known-folders](https://github.com/ziglibs/known-folders) was unable to find a local configuration directory.
    local_config_dir: ?[]const u8,
    /// Path to a `xzls.json` config file. Will be resolved by looking in the local configuration directory and then falling back to the global directory.
    /// Can be null if no `xzls.json` was found in the global/local config directory.
    config_file: ?[]const u8,
    /// Path to a `xzls.log` file where ZLS will append logging output. The file may be truncated or cleared by xzls.
    /// Not `null` unless [known-folders](https://github.com/ziglibs/known-folders) was unable to find a cache directory.
    log_file: ?[]const u8,
};

fn @"zls env"(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) (std.mem.Allocator.Error || std.Io.File.Writer.Error)!noreturn {
    const global_cache_dir = known_folders.getPath(io, allocator, environ_map, .cache) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => |e| return e,
    };
    defer if (global_cache_dir) |path| allocator.free(path);

    const zls_global_cache_dir = if (global_cache_dir) |cache_dir| try std.Io.Dir.path.join(allocator, &.{ cache_dir, "zls" }) else null;
    defer if (zls_global_cache_dir) |path| allocator.free(path);

    const global_config_dir = known_folders.getPath(io, allocator, environ_map, .global_configuration) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => |e| return e,
    };
    defer if (global_config_dir) |path| allocator.free(path);

    const local_config_dir = known_folders.getPath(io, allocator, environ_map, .local_configuration) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => |e| return e,
    };
    defer if (local_config_dir) |path| allocator.free(path);

    var config_result = try loadConfigFromSystem(io, allocator, environ_map);
    defer config_result.deinit(allocator);

    const config_file_path: ?[]const u8 = switch (config_result) {
        .success => |config_with_path| config_with_path.path,
        .failure => |payload| blk: {
            const message = try payload.toMessage(allocator) orelse break :blk null;
            defer allocator.free(message);
            log.err("Failed to load configuration options.", .{});
            log.err("{s}", .{message});
            break :blk null;
        },
        .not_found => null,
    };

    const log_file_path = try defaultLogFilePath(io, allocator, environ_map);
    defer if (log_file_path) |path| allocator.free(path);

    var buffer: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    const writer = &file_writer.interface;

    const env: Env = .{
        .version = xzls.build_options.version_string,
        .global_cache_dir = zls_global_cache_dir,
        .global_config_dir = global_config_dir,
        .local_config_dir = local_config_dir,
        .config_file = config_file_path,
        .log_file = log_file_path,
    };
    std.json.Stringify.value(env, .{ .whitespace = .indent_1 }, writer) catch return file_writer.err.?;
    writer.writeAll("\n") catch return file_writer.err.?;
    writer.flush() catch return file_writer.err.?;

    std.process.exit(0);
}

const LoadConfigResult = union(enum) {
    success: struct {
        config: xzls.Config,
        config_arena: std.heap.ArenaAllocator.State,
        /// file path of the config.json
        path: []const u8,
    },
    failure: struct {
        /// `null` indicates that the error has already been logged
        error_bundle: ?std.zig.ErrorBundle,

        pub fn toMessage(self: @This(), allocator: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
            const error_bundle = self.error_bundle orelse return null;
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            error_bundle.renderToWriter(.{}, &aw.writer) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
            };
            return try aw.toOwnedSlice();
        }
    },
    not_found,

    pub fn deinit(self: *LoadConfigResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .success => |*config_with_path| {
                config_with_path.config_arena.promote(allocator).deinit();
                allocator.free(config_with_path.path);
            },
            .failure => |*payload| {
                if (payload.error_bundle) |*error_bundle| error_bundle.deinit(allocator);
            },
            .not_found => {},
        }
    }
};

fn loadConfigFromFile(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8) error{ Canceled, OutOfMemory }!LoadConfigResult {
    const file_buf = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .not_found,
        error.Canceled, error.OutOfMemory => |e| return e,
        else => {
            log.warn("Error while reading configuration file: {}", .{err});
            return .{ .failure = .{ .error_bundle = null } };
        },
    };
    defer allocator.free(file_buf);

    const parse_options: std.json.ParseOptions = .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    };
    var parse_diagnostics: std.json.Diagnostics = .{};

    var scanner: std.json.Scanner = .initCompleteInput(allocator, file_buf);
    defer scanner.deinit();
    scanner.enableDiagnostics(&parse_diagnostics);

    var arena_allocator: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena_allocator.deinit();

    @setEvalBranchQuota(10000);
    const config = std.json.parseFromTokenSourceLeaky(
        xzls.Config,
        arena_allocator.allocator(),
        &scanner,
        parse_options,
    ) catch |err| {
        var eb: std.zig.ErrorBundle.Wip = try .init(allocator);
        errdefer eb.deinit();

        const src_path = try eb.addString(file_path);
        const msg = try eb.addString(@errorName(err));

        const src_loc = try eb.addSourceLocation(.{
            .src_path = src_path,
            .line = @intCast(parse_diagnostics.getLine()),
            .column = @intCast(parse_diagnostics.getColumn()),
            .span_start = @intCast(parse_diagnostics.getByteOffset()),
            .span_main = @intCast(parse_diagnostics.getByteOffset()),
            .span_end = @intCast(parse_diagnostics.getByteOffset()),
        });
        try eb.addRootErrorMessage(.{
            .msg = msg,
            .src_loc = src_loc,
        });

        return .{ .failure = .{ .error_bundle = try eb.toOwnedBundle("") } };
    };

    return .{ .success = .{
        .config = config,
        .config_arena = arena_allocator.state,
        .path = try allocator.dupe(u8, file_path),
    } };
}

fn loadConfigFromSystem(io: std.Io, allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) error{ Canceled, OutOfMemory }!LoadConfigResult {
    if (zig_builtin.target.os.tag == .wasi) return .not_found;

    const config_filenames = [_][]const u8{
        "xxzls.json",
    };

    for (
        [_]known_folders.KnownFolder{ .local_configuration, .global_configuration },
    ) |folder| {
        const folder_path = try known_folders.getPath(io, allocator, environ_map, folder) orelse continue;
        defer allocator.free(folder_path);

        for (config_filenames) |filename| {
            const config_path = try std.Io.Dir.path.join(allocator, &.{ folder_path, filename });
            defer allocator.free(config_path);

            const result = try loadConfigFromFile(io, allocator, config_path);
            switch (result) {
                .success, .failure => return result,
                .not_found => continue,
            }
        }
    }

    return .not_found;
}

fn loadConfiguration(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    server: *xzls.Server,
    maybe_config_path: ?[]const u8,
) error{ Canceled, OutOfMemory }!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var config_arena: std.heap.ArenaAllocator = .init(allocator);
    defer config_arena.deinit();
    var config: xzls.Config = .{};

    blk: {
        var config_result = if (maybe_config_path) |config_path|
            try loadConfigFromFile(io, allocator, config_path)
        else
            try loadConfigFromSystem(io, allocator, environ_map);
        defer config_result.deinit(allocator);

        switch (config_result) {
            .success => |*config_with_path| {
                log.info("Loaded config:    {s}", .{config_with_path.path});
                config = config_with_path.config;
                config_arena.state = config_with_path.config_arena;
                config_with_path.config_arena = .{};
            },
            .failure => |payload| {
                const message = try payload.toMessage(allocator) orelse break :blk;
                defer allocator.free(message);
                server.showMessage(.Error, "Failed to load configuration options:\n{s}", .{message});
            },
            .not_found => {},
        }
    }

    if (config.global_cache_path == null) blk: {
        if (zig_builtin.target.os.tag == .wasi) {
            // will default to `/cache`
            break :blk;
        }

        const cache_dir_path = try known_folders.getPath(io, allocator, environ_map, .cache) orelse {
            server.showMessage(.Error, "Failed to resolve global cache directory", .{});
            break :blk;
        };
        defer allocator.free(cache_dir_path);

        config.global_cache_path = try std.Io.Dir.path.join(config_arena.allocator(), &.{ cache_dir_path, "zls" });
    }

    try server.config_manager.setConfiguration2(.frontend, &config);
}

const ParseArgsResult = struct {
    config_path: ?[]const u8 = null,
    log_level: ?std.log.Level = null,
    log_file_path: ?[]const u8 = null,
    zls_exe_path: []const u8 = "",
    enable_stderr_logs: bool = false,
    disable_lsp_logs: bool = false,

    fn deinit(self: ParseArgsResult, allocator: std.mem.Allocator) void {
        defer if (self.config_path) |path| allocator.free(path);
        defer if (self.log_file_path) |path| allocator.free(path);
        defer allocator.free(self.zls_exe_path);
    }
};

const ParseArgsError = std.mem.Allocator.Error || std.Io.File.Writer.Error;

fn parseArgs(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    args: std.process.Args,
) ParseArgsError!ParseArgsResult {
    var result: ParseArgsResult = .{};
    errdefer result.deinit(allocator);

    var args_it = try args.iterateAllocator(allocator);
    defer args_it.deinit();

    const zls_exe_path = args_it.next() orelse "";
    result.zls_exe_path = try allocator.dupe(u8, zls_exe_path);

    var arg_index: usize = 0;
    while (args_it.next()) |arg| : (arg_index += 1) {
        if ((arg_index == 0 and std.mem.eql(u8, arg, "help")) or
            std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "--help"))
        {
            try std.Io.File.stderr().writeStreamingAll(io, usage);
            std.process.exit(0);
        } else if ((arg_index == 0 and std.mem.eql(u8, arg, "version")) or std.mem.eql(u8, arg, "--version")) {
            try std.Io.File.stdout().writeStreamingAll(io, xzls.build_options.version_string ++ "\n");
            std.process.exit(0);
        } else if (arg_index == 0 and std.mem.eql(u8, arg, "env")) {
            try @"zls env"(io, allocator, environ_map);
        }

        if (std.mem.eql(u8, arg, "--config-path")) { // --config-path
            const path = args_it.next() orelse {
                log.err("Expected configuration file path after --config-path argument.", .{});
                std.process.exit(1);
            };
            if (result.config_path) |old_config_path| allocator.free(old_config_path);
            result.config_path = try allocator.dupe(u8, path);
        } else if (std.mem.eql(u8, arg, "--log-file")) { // --log-file
            const path = args_it.next() orelse {
                log.err("Expected configuration file path after --log-file argument.", .{});
                std.process.exit(1);
            };
            if (result.log_file_path) |old_file_path| allocator.free(old_file_path);
            result.log_file_path = try allocator.dupe(u8, path);
        } else if (std.mem.eql(u8, arg, "--log-level")) { // --log-level
            const log_level_name = args_it.next() orelse {
                log.err("Expected argument after --log-level", .{});
                std.process.exit(1);
            };
            result.log_level = std.meta.stringToEnum(std.log.Level, log_level_name) orelse {
                log.err("Invalid --log-level argument. Expected one of {{'debug', 'info', 'warn', 'err'}} but got '{s}'", .{log_level_name});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--enable-stderr-logs")) { // --enable-stderr-logs
            result.enable_stderr_logs = true;
        } else if (std.mem.eql(u8, arg, "--disable-lsp-logs")) { // --disable-lsp-logs
            result.disable_lsp_logs = true;
        } else {
            log.err("Unrecognized argument: '{s}'", .{arg});
            std.process.exit(1);
        }
    }

    if (zig_builtin.target.os.tag != .wasi and try std.Io.File.stdin().isTty(io)) {
        log.warn("XZLS isn't a CLI tool, it's a Language Server Protocol server.", .{});
        log.warn("Did you mean to run 'xzls --help'?", .{});
    }

    return result;
}

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main(init: std.process.Init) !u8 {
    const base_allocator = init.gpa;
    const environ = init.minimal.environ;
    const args = init.minimal.args;
    const io = init.io;

    var tracy_state = if (tracy.enable_allocation) tracy.Allocator{ .parent_allocator = base_allocator } else {};
    const inner_allocator: std.mem.Allocator = if (tracy.enable_allocation) tracy_state.interface() else base_allocator;

    var failing_allocator_state = if (exe_options.enable_failing_allocator) xzls.testing.FailingAllocator.init(inner_allocator, exe_options.enable_failing_allocator_likelihood) else {};
    const allocator: std.mem.Allocator = if (exe_options.enable_failing_allocator) failing_allocator_state.allocator() else inner_allocator;

    var environ_map = try environ.createMap(allocator);
    defer environ_map.deinit();

    const result = try parseArgs(io, allocator, &environ_map, args);
    defer result.deinit(allocator);

    log_file, const log_file_path = try createLogFile(io, allocator, &environ_map, result.log_file_path) orelse .{ null, null };
    defer if (log_file_path) |path| allocator.free(path);
    defer if (log_file) |file| {
        file.close(io);
        log_file = null;
    };

    var read_buffer: [256]u8 = undefined;
    var stdio_transport: xzls.lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());

    var thread_safe_transport: xzls.lsp.ThreadSafeTransport(.{
        .thread_safe_read = false,
        .thread_safe_write = true,
    }) = .init(&stdio_transport.transport);

    const transport: *xzls.lsp.Transport = &thread_safe_transport.transport;

    log_transport = if (result.disable_lsp_logs) null else transport;
    log_stderr = result.enable_stderr_logs;
    log_level = result.log_level orelse log_level;
    defer {
        log_transport = null;
        log_stderr = true;
    }

    log.info("Starting XZLS      {s} @ '{s}'", .{
        xzls.build_options.version_string,
        result.zls_exe_path,
    });
    if (log_file_path) |path| {
        log.info("Log File:         {s} ({t})", .{ path, log_level });
    } else {
        log.info("Log File:         none", .{});
    }

    var config_manager: xzls.configuration.Manager = try .init(io, allocator, &environ_map);
    defer config_manager.deinit();

    const server: *xzls.Server = try .create(.{
        .io = io,
        .allocator = allocator,
        .transport = transport,
        .config_manager = &config_manager,
    });
    defer server.destroy();

    try loadConfiguration(io, allocator, &environ_map, server, result.config_path);

    try server.loop();

    switch (server.status) {
        .exiting_failure => return 1,
        .exiting_success => return 0,
        else => unreachable,
    }
}

comptime {
    std.testing.refAllDecls(@This());

    if (@import("builtin").is_test) {
        _ = &@import("bsp.zig").BuildOnSave;
    }
}

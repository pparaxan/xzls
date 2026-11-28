const std = @import("std");
const builtin = @import("builtin");

const xzls_version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable;

const minimum_build_zig_version = @import("build.zig.zon").minimum_zig_version;

/// Specifies the minimum Zig version that is runtime compatible with XZLS
const minimum_runtime_zig_version = "0.17.0";

const release_targets = [_]std.Target.Query{
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
    .{ .cpu_arch = .arm, .os_tag = .linux },
    .{ .cpu_arch = .loongarch64, .os_tag = .linux },
    .{ .cpu_arch = .riscv64, .os_tag = .linux },
    .{ .cpu_arch = .x86, .os_tag = .linux },
    .{ .cpu_arch = .x86, .os_tag = .windows },
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
    .{ .cpu_arch = .wasm32, .os_tag = .wasi },
};

const additional_tagged_release_targets = [_]std.Target.Query{
    .{ .cpu_arch = .powerpc64le, .os_tag = .linux },
    .{ .cpu_arch = .s390x, .os_tag = .linux },
};

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pie = b.option(bool, "pie", "Build a Position Independent Executable");
    const strip = b.option(bool, "strip", "Strip executable");
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match filter") orelse &.{};
    var use_llvm = b.option(bool, "use-llvm", "Use Zig's llvm code backend");

    const resolved_xzls_version = xzls_version;

    const build_options = blk: {
        const build_options = b.addOptions();
        build_options.step.name = "XZLS build options";

        build_options.addOption(std.SemanticVersion, "version", resolved_xzls_version);
        build_options.addOption([]const u8, "version_string", b.fmt("{f}", .{resolved_xzls_version}));
        build_options.addOption([]const u8, "minimum_runtime_zig_version_string", minimum_runtime_zig_version);

        break :blk build_options.createModule();
    };
    const exe_options = blk: {
        const exe_options = b.addOptions();
        exe_options.step.name = "XZLS exe options";

        exe_options.addOption(bool, "enable_failing_allocator", b.option(bool, "enable-failing-allocator", "Whether to use a randomly failing allocator.") orelse false);
        exe_options.addOption(u32, "enable_failing_allocator_likelihood", b.option(u32, "enable-failing-allocator-likelihood", "The chance that an allocation will fail is `1/likelihood`") orelse 256);
        exe_options.addOption(bool, "debug_gpa", b.option(bool, "debug-allocator", "Force the DebugAllocator to be used in all release modes") orelse false);

        break :blk exe_options.createModule();
    };
    const test_options = blk: {
        const test_options = b.addOptions();
        test_options.step.name = "XZLS test options";

        test_options.addOptionPath("zig_exe_path", .zig_exe);
        test_options.addOptionPathUntracked("zig_lib_path", .zig_lib);
        test_options.addOptionPathUntracked("global_cache_path", std.Build.LazyPath.cache_root.join(b.allocator, "xzls") catch @panic("OOM"));

        break :blk test_options.createModule();
    };
    const tracy_options, const tracy_enable = blk: {
        const tracy_options = b.addOptions();
        tracy_options.step.name = "tracy options";

        const enable = b.option(bool, "enable-tracy", "Enable Tracy integration") orelse false;
        const enable_allocation = b.option(bool, "tracy-allocation", "Include allocation information with Tracy data") orelse enable;
        const callstack_depth: u32 = b.option(u32, "tracy-callstack", "Declare callstack depth for Tracy data") orelse 6;
        tracy_options.addOption(bool, "enable", enable);
        tracy_options.addOption(bool, "enable_allocation", enable and enable_allocation);
        tracy_options.addOption(u32, "callstack_depth", if (enable) callstack_depth else 0);

        break :blk .{ tracy_options.createModule(), enable };
    };
    // https://github.com/ziglang/zig/issues/25194
    if (tracy_enable and use_llvm == null) use_llvm = true;

    const gen_exe = b.addExecutable(.{
        .name = "xzls_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/config_gen.zig"),
            .target = b.graph.host,
            .single_threaded = true,
        }),
    });

    const version_data_module = blk: {
        const gen_version_data_cmd = b.addRunArtifact(gen_exe);
        const version = if (xzls_version.pre == null) b.fmt("{f}", .{xzls_version}) else "master";
        gen_version_data_cmd.addArgs(&.{ "--langref-version", version });

        gen_version_data_cmd.addArg("--langref-path");
        gen_version_data_cmd.addFileArg(b.path("src/tools/langref.html.in"));

        gen_version_data_cmd.addArg("--generate-version-data");
        const version_data_path = gen_version_data_cmd.addOutputFileArg("version_data.zig");

        break :blk b.createModule(.{ .root_source_file = version_data_path });
    };

    if (b.isRoot()) { // zig build gen
        const gen_step = b.step("gen", "Regenerate config files");

        const update_source = b.addUpdateSourceFiles();
        gen_step.dependOn(&update_source.step);

        const gen_cmd = b.addRunArtifact(gen_exe);
        gen_cmd.addArg("--generate-config");
        update_source.addCopyFileToSource(gen_cmd.addOutputFileArg("Config.zig"), "src/Config.zig");
        gen_cmd.addArg("--generate-schema");
        update_source.addCopyFileToSource(gen_cmd.addOutputFileArg("schema.json"), "schema.json");
        gen_cmd.addPassthruArgs();
    }

    if (b.isRoot()) { // zig build config-gen
        const gen_step = b.step("config-gen", "Run src/tools/config_gen.zig");
        const gen_cmd = b.addRunArtifact(gen_exe);
        gen_cmd.addPassthruArgs();
        gen_step.dependOn(&gen_cmd.step);
    }

    if (b.isRoot()) { // zig build release
        const targets = comptime if (xzls_version.pre == null) release_targets ++ additional_tagged_release_targets else release_targets;

        var release_artifacts: [targets.len]*Build.Step.Compile = undefined;
        for (targets, &release_artifacts) |target_query, *artifact| {
            const release_target = b.resolveTargetQuery(target_query);

            const release_exe_module = createExeModule(b, .{
                .target = release_target,
                .optimize = optimize,
                .pie = pie,
                .strip = strip,
                .tracy_enable = tracy_enable,
                .tracy_options = tracy_options,
                .build_options = build_options,
                .version_data = version_data_module,
                .exe_options = exe_options,
            });

            artifact.* = b.addExecutable(.{
                .name = "xzls",
                .root_module = release_exe_module,
                .max_rss = if (optimize == .debug and target_query.os_tag == .wasi) 2_600_000_000 else 2_750_000_000,
                .use_llvm = use_llvm,
                .use_lld = use_llvm,
            });
        }

        release(b, &release_artifacts, resolved_xzls_version);
    }

    const exe_module = createExeModule(b, .{
        .target = target,
        .optimize = optimize,
        .pie = pie,
        .strip = strip,
        .tracy_enable = tracy_enable,
        .tracy_options = tracy_options,
        .build_options = build_options,
        .version_data = version_data_module,
        .exe_options = exe_options,
    });

    { // zig build
        const exe = b.addExecutable(.{
            .name = "xzls",
            .root_module = exe_module,
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        exe.pie = pie;
        b.installArtifact(exe);
    }

    { // zig build check
        const exe_check = b.addExecutable(.{
            .name = "xzls",
            .root_module = exe_module,
        });

        const check = b.step("check", "Check if XZLS compiles");
        check.dependOn(&exe_check.step);
    }

    if (!b.isRoot()) return;

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tests.zig"),
            .target = target,
            .optimize = optimize,
            .pic = pie,
            .imports = &.{
                .{ .name = "xzls", .module = exe_module },
                .{ .name = "test_options", .module = test_options },
            },
        }),
        .filters = test_filters,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    const src_tests = b.addTest(.{
        .name = "src test",
        .root_module = exe_module,
        .filters = test_filters,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    { // zig build test, zig build test-analysis
        const test_step = b.step("test", "Run all the tests");
        const test_analysis_step = b.step("test-analysis", "Run all the analysis tests");

        // Create run steps
        addAnalysisCases(b, target, optimize, test_analysis_step, test_filters, exe_module);

        const run_tests = b.addRunArtifact(tests);
        const run_src_tests = b.addRunArtifact(src_tests);

        for ([_]*Build.Step.Run{ run_tests, run_src_tests }) |run| {
            run.setPreopen("/lib", .zig_lib);
            run.setPreopen("/cache", Build.LazyPath.cache_root.join(b.allocator, "xzls") catch @panic("OOM"));
        }

        // Setup dependencies of `zig build test`
        test_step.dependOn(&run_tests.step);
        test_step.dependOn(&run_src_tests.step);
        test_step.dependOn(test_analysis_step);
    }
}

fn createExeModule(
    b: *Build,
    options: struct {
        target: Build.ResolvedTarget,
        optimize: std.lang.Optimize,
        pie: ?bool,
        strip: ?bool,
        tracy_enable: bool,
        tracy_options: *std.Build.Module,
        build_options: *std.Build.Module,
        version_data: *std.Build.Module,
        exe_options: *std.Build.Module,
    },
) *std.Build.Module {
    const diffz_module = b.dependency("diffz", .{
        .target = options.target,
        .optimize = options.optimize,
    }).module("diffz");
    const lsp_module = b.dependency("lsp_kit", .{
        .target = options.target,
        .optimize = options.optimize,
    }).module("lsp");
    const tracy_module = createTracyModule(b, .{
        .target = options.target,
        .optimize = options.optimize,
        .enable = options.tracy_enable,
        .tracy_options = options.tracy_options,
    });
    const known_folders_module = b.dependency("known_folders", .{
        .target = options.target,
        .optimize = options.optimize,
    }).module("known-folders");

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .pic = options.pie,
        .strip = options.strip,
        .imports = &.{
            .{ .name = "diffz", .module = diffz_module },
            .{ .name = "lsp", .module = lsp_module },
            .{ .name = "tracy", .module = tracy_module },
            .{ .name = "build_options", .module = options.build_options },
            .{ .name = "version_data", .module = options.version_data },
            .{ .name = "exe_options", .module = options.exe_options },
            .{ .name = "known-folders", .module = known_folders_module },
        },
    });

    if (options.target.result.os.tag == .windows) {
        exe_module.linkSystemLibrary("advapi32", .{});
    }

    return exe_module;
}

fn createTracyModule(
    b: *Build,
    options: struct {
        target: Build.ResolvedTarget,
        optimize: std.lang.Optimize,
        enable: bool,
        tracy_options: *std.Build.Module,
    },
) *Build.Module {
    const tracy_module = b.createModule(.{
        .root_source_file = b.path("src/tracy.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{
            .{ .name = "options", .module = options.tracy_options },
        },
        .link_libc = options.enable,
        .link_libcpp = options.enable,
        .sanitize_c = .off,
    });
    if (!options.enable) return tracy_module;

    const tracy_dependency = b.lazyDependency("tracy", .{
        .target = options.target,
        .optimize = options.optimize,
    }) orelse return tracy_module;

    tracy_module.addCMacro("TRACY_ENABLE", "1");
    tracy_module.addIncludePath(tracy_dependency.path(""));
    tracy_module.addCSourceFile(.{
        .file = tracy_dependency.path("public/TracyClient.cpp"),
    });

    if (options.target.result.os.tag == .windows) {
        tracy_module.linkSystemLibrary("dbghelp", .{});
        tracy_module.linkSystemLibrary("ws2_32", .{});
    }

    return tracy_module;
}

/// 1. compile XZLS binaries to different targets
/// 2. compress them (`.tar.xz`, `.tar.gz`, and `.zip`)
/// 3. install artifacts to `./zig-out`
fn release(b: *Build, release_artifacts: []const *Build.Step.Compile, released_xzls_version: std.SemanticVersion) void {
    std.debug.assert(release_artifacts.len > 0);

    const release_step = b.step("release", "Build all release artifacts. (requires tar and 7z)");

    if (released_xzls_version.pre != null and released_xzls_version.build == null) {
        release_step.dependOn(&b.addFail("Cannot build release because the XZLS version could not be resolved").step);
        return;
    }

    const FileExtension = enum {
        zip,
        @"tar.xz",
        @"tar.gz",
    };

    var compressed_artifacts: std.array_hash_map.String(std.Build.LazyPath) = .empty;

    for (release_artifacts) |exe| {
        const resolved_target = exe.root_module.resolved_target.?.result;
        const is_windows = resolved_target.os.tag == .windows;
        const exe_name = b.fmt("{s}{s}", .{ exe.name, resolved_target.exeFileExt() });

        const extensions: []const FileExtension = if (is_windows) &.{.zip} else &.{ .@"tar.xz", .@"tar.gz" };

        for (extensions) |extension| {
            const file_name = b.fmt("xzls-{t}-{t}-{f}.{t}", .{
                resolved_target.cpu.arch,
                resolved_target.os.tag,
                released_xzls_version,
                extension,
            });

            const compress_cmd = std.Build.Step.Run.create(b, "compress artifact");
            compress_cmd.clearEnvironment();
            compress_cmd.step.max_rss = switch (extension) {
                .zip => 160 * 1024 * 1024, // 160 MiB
                .@"tar.xz" => 768 * 1024 * 1024, // 512 MiB
                .@"tar.gz" => 16 * 1024 * 1024, // 12 MiB
            };
            switch (extension) {
                .zip => {
                    compress_cmd.addArgs(&.{ "7z", "a", "-mx=9" });
                    compressed_artifacts.putNoClobber(b.allocator, file_name, compress_cmd.addOutputFileArg2(file_name, .{})) catch @panic("OOM");
                    compress_cmd.addArtifactArg(exe);
                    compress_cmd.addFileArg(exe.getEmittedPdb());
                    compress_cmd.addFileArg(b.path("LICENSE"));
                    compress_cmd.addFileArg(b.path("README.md"));
                },
                .@"tar.xz",
                .@"tar.gz",
                => {
                    compress_cmd.setEnvironmentVariable("XZ_OPT", "-9");
                    compress_cmd.addArgs(&.{ "tar", "caf" });
                    compressed_artifacts.putNoClobber(b.allocator, file_name, compress_cmd.addOutputFileArg(file_name)) catch @panic("OOM");
                    compress_cmd.addDirectoryArg2(exe.getEmittedBinDirectory(), .{ .prefix = "-C" });
                    compress_cmd.addArg(exe_name);

                    compress_cmd.addDirectoryArg2(b.path("."), .{ .prefix = "-C", .make_absolute = true });
                    compress_cmd.addArg("LICENSE");
                    compress_cmd.addArg("README.md");

                    compress_cmd.addArgs(&.{
                        "--sort=name",
                        "--numeric-owner",
                        "--owner=0",
                        "--group=0",
                        "--mtime=1970-01-01",
                    });
                },
            }
        }
    }

    for (compressed_artifacts.keys(), compressed_artifacts.values()) |file_name, file_path| {
        const install_dir: std.Build.InstallDir = .{ .custom = "artifacts" };

        const install_tarball = b.addInstallFileWithDir(file_path, install_dir, file_name);
        release_step.dependOn(&install_tarball.step);
    }
}

fn addAnalysisCases(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
    test_step: *std.Build.Step,
    test_filters: []const []const u8,
    exe_module: *std.Build.Module,
) void {
    const cases_path = "tests/analysis";

    const check_exe = b.addExecutable(.{
        .name = "analysis_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/analysis_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "xzls", .module = exe_module },
            },
        }),
    });

    b.dependOnDirectoryContents(b.path(cases_path));

    var dir = b.root.openDir(b.graph.io, cases_path, .{ .iterate = true }) catch |err|
        std.debug.panic("failed to open '{f}': {}", .{ b.path(cases_path), err });
    defer dir.close(b.graph.io);

    var it = dir.iterate();

    while (true) {
        const entry = it.next(b.graph.io) catch |err|
            std.debug.panic("failed to walk directory '{f}': {}", .{ b.path(cases_path), err }) orelse break;

        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.Io.Dir.path.extension(entry.name), ".zig")) continue;

        for (test_filters) |test_filter| {
            if (std.mem.find(u8, entry.name, test_filter) != null) break;
        } else if (test_filters.len > 0) continue;

        const run_check = std.Build.Step.Run.create(b, b.fmt("run analysis on {s}", .{entry.name}));
        run_check.producer = check_exe;

        run_check.addArtifactArg(check_exe);
        if (target.query.eql(b.graph.host.query)) {
            run_check.addArg("--zig-exe-path");
            run_check.addFileArg(.zig_exe);
        }
        run_check.setPreopen("/lib", .zig_lib);
        if (!target.result.cpu.arch.isWasm()) {
            run_check.addArg("--zig-lib-path");
            run_check.addDirectoryArg(.zig_lib);
        }

        const input_file = b.path(cases_path).path(b, entry.name);
        if (!target.result.cpu.arch.isWasm()) {
            run_check.addFileArg(input_file);
        } else {
            // pass a relative file path when running with wasmtime
            run_check.setCwd(b.path(cases_path));
            run_check.addArg(entry.name);
            run_check.addFileInput(input_file);
        }

        test_step.dependOn(&run_check.step);
    }
}

const Build = blk: {
    @setEvalBranchQuota(10_000);

    const min_build_zig = std.SemanticVersion.parse(minimum_build_zig_version) catch unreachable;
    const min_runtime_zig = std.SemanticVersion.parse(minimum_runtime_zig_version) catch unreachable;

    if (min_runtime_zig.order(min_build_zig) == .gt) {
        const message = std.fmt.comptimePrint(
            \\A Zig version that is able to build XZLS must be compatible with XZLS at runtime.
            \\
            \\This means that the minimum runtime Zig version must be less or equal to the minimum build Zig version:
            \\  minimum build   Zig version: {[min_build_zig]s}
            \\  minimum runtime Zig version: {[min_runtime_zig]s}
            \\
            \\This is a developer error.
        , .{ .min_build_zig = minimum_build_zig_version, .min_runtime_zig = minimum_runtime_zig_version });
        @compileError(message);
    }

    // check minimum build version
    const is_current_zig_tagged_release = builtin.zig_version.pre == null;
    const is_min_build_zig_tagged_release = min_build_zig.pre == null;
    if (switch (builtin.zig_version.order(min_build_zig)) {
        .lt => true,
        .eq => false,
        .gt => is_current_zig_tagged_release and !is_min_build_zig_tagged_release,
    }) {
        const message = std.fmt.comptimePrint(
            \\Your Zig version does not meet the minimum build requirement:
            \\  required Zig version: {[minimum_version]s} (or greater)
            \\  actual   Zig version: {[current_version]s}
            \\
            \\Please download the {[minimum_version]s} release of Zig. (https://ziglang.org/download/)
        , .{
            .current_version = builtin.zig_version_string,
            .minimum_version = minimum_build_zig_version,
        });
        @compileError(message);
    }
    break :blk std.Build;
};

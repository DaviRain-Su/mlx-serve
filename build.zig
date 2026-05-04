const std = @import("std");

pub fn build(b: *std.Build) void {
    // Pin LC_BUILD_VERSION minos to macOS 14 (Sonoma) so binaries built on newer
    // runners (macos-26 in CI) still load on Sonoma. dyld refuses any image whose
    // minos is newer than the running OS.
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } },
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    // Setting any non-default target field disables Zig's native macOS SDK detection,
    // so we resolve the SDK path ourselves and surface its frameworks dir.
    const macos_sdk_frameworks: ?[]const u8 = blk: {
        if (target.result.os.tag != .macos) break :blk null;
        var code: u8 = undefined;
        const stdout = b.runAllowFail(
            &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" },
            &code,
            .inherit,
        ) catch break :blk null;
        const sdk = std.mem.trim(u8, stdout, " \n\r\t");
        if (sdk.len == 0) break :blk null;
        break :blk b.fmt("{s}/System/Library/Frameworks", .{sdk});
    };

    // Version from build option or default
    const version = b.option([]const u8, "version", "Version string") orelse "0.1.0-dev";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });

    // Jinja2 template engine (from llama.cpp's common/jinja + nlohmann/json).
    // Pre-compiled as a static library with system clang++ (C++17 requires system libc++).
    // Rebuild with: cd lib/jinja_cpp && for f in jinja_wrapper caps lexer parser runtime jinja_string value; do clang++ -std=c++17 -O2 -DNDEBUG -I . -c $f.cpp -o obj/$f.o; done && ar rcs libjinja.a obj/*.o
    mod.addObjectFile(b.path("lib/jinja_cpp/libjinja.a"));
    mod.addIncludePath(b.path("lib/jinja_cpp"));

    // stb_image for JPEG/PNG decoding in the vision pipeline
    mod.addCSourceFile(.{ .file = b.path("lib/stb_image_impl.c"), .flags = &.{"-O2"} });
    mod.addIncludePath(b.path("lib"));

    // mlx-c include/lib paths (homebrew)
    mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    mod.linkSystemLibrary("mlxc", .{});
    mod.linkSystemLibrary("webp", .{});

    if (macos_sdk_frameworks) |fw_path| {
        mod.addFrameworkPath(.{ .cwd_relative = fw_path });
    }
    mod.linkFramework("IOKit", .{});
    mod.linkFramework("CoreFoundation", .{});

    const exe = b.addExecutable(.{
        .name = "mlx-serve",
        .root_module = mod,
    });

    // Ensure Mach-O header has room for install_name_tool path changes (app bundling)
    exe.headerpad_max_install_names = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run mlx-serve");
    run_step.dependOn(&run_cmd.step);

    // Unit tests — reuses the same module config (mlx-c, jinja_cpp, etc.)
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });

    test_mod.addObjectFile(b.path("lib/jinja_cpp/libjinja.a"));
    test_mod.addIncludePath(b.path("lib/jinja_cpp"));
    test_mod.addCSourceFile(.{ .file = b.path("lib/stb_image_impl.c"), .flags = &.{"-O2"} });
    test_mod.addIncludePath(b.path("lib"));
    test_mod.linkSystemLibrary("c++", .{});
    test_mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    test_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    test_mod.linkSystemLibrary("mlxc", .{});
    test_mod.linkSystemLibrary("webp", .{});

    if (macos_sdk_frameworks) |fw_path| {
        test_mod.addFrameworkPath(.{ .cwd_relative = fw_path });
    }
    test_mod.linkFramework("IOKit", .{});
    test_mod.linkFramework("CoreFoundation", .{});

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library: readers for the game's files and the port of the game itself, shared by the
    // game and every tool.
    const lib = b.addModule("openreliant", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // The game: SDL3 in place of Win32 and DirectX, from the SDL package, which builds SDL from
    // source for the target.
    // Building for a Mac other than the host, SDL and the game need the SDK's paths: from xcrun.
    const macos_sdk: ?[]const u8 = if (target.result.os.tag == .macos and !target.query.isNative())
        std.mem.trimEnd(u8, b.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }), "\n")
    else
        null;
    const sdl_dependency = if (macos_sdk) |sdk| b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .system_include_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) },
        .system_framework_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) },
        .library_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) },
    }) else b.dependency("sdl", .{ .target = target, .optimize = optimize });
    const sdl_library = sdl_dependency.artifact("SDL3");
    const sdl_c = b.addTranslateC(.{
        .root_source_file = b.path("src/platform/sdl.h"),
        .target = target,
        .optimize = optimize,
    });
    sdl_c.addIncludePath(sdl_library.getEmittedIncludeTree());
    const platform = b.createModule(.{
        .root_source_file = b.path("src/platform.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "openreliant", .module = lib },
            .{ .name = "sdl", .module = sdl_c.createModule() },
        },
    });
    platform.linkLibrary(sdl_library);
    // The sound: OpenAL Soft in place of Miles's 3D providers, which deps/openal-soft builds from
    // source for the target and the platform renders through its loopback device.
    const openal_library = b.dependency("openal_soft", .{ .target = target, .optimize = optimize }).artifact("openal");
    const openal_c = b.addTranslateC(.{
        .root_source_file = b.path("src/platform/openal.h"),
        .target = target,
        .optimize = optimize,
    });
    openal_c.addIncludePath(openal_library.getEmittedIncludeTree());
    platform.addImport("al", openal_c.createModule());
    platform.linkLibrary(openal_library);
    if (macos_sdk) |sdk| {
        platform.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
        platform.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
    }
    // The installer unpacks the game's cabinet with libarchive, which deps/libarchive builds from
    // source for the target.
    const archive_library = b.dependency("libarchive", .{ .target = target, .optimize = optimize }).artifact("archive");
    const archive_c = b.addTranslateC(.{
        .root_source_file = b.path("src/openreliant/archive.h"),
        .target = target,
        .optimize = optimize,
    });
    archive_c.addIncludePath(archive_library.getEmittedIncludeTree());
    if (macos_sdk) |sdk| {
        archive_library.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
        archive_library.root_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
        archive_library.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
    }
    const openreliant = b.addExecutable(.{
        .name = "openreliant",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/openreliant/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "openreliant", .module = lib },
                .{ .name = "platform", .module = platform },
                .{ .name = "archive", .module = archive_c.createModule() },
            },
        }),
    });
    openreliant.root_module.linkLibrary(archive_library);
    b.installArtifact(openreliant);

    const play_step = b.step("play", "Run the game");
    const play_cmd = b.addRunArtifact(openreliant);
    play_step.dependOn(&play_cmd.step);
    play_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| play_cmd.addArgs(args);

    const sltool = b.addExecutable(.{
        .name = "sltool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sltool/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "openreliant", .module = lib },
            },
        }),
    });
    b.installArtifact(sltool);

    // Derives the engine's static tables from the game binary: the script VM's opcodes, commands
    // and conditions, and the models it loads. Not installed: it is a development tool, run by the
    // `make vm-*` and `make model-tables` targets, and its output is committed.
    const tablegen = b.addExecutable(.{
        .name = "tablegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/tablegen/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "openreliant", .module = lib },
            },
        }),
    });

    const tablegen_step = b.step("tablegen", "Build the generator of the engine's tables");
    tablegen_step.dependOn(&b.addInstallArtifact(tablegen, .{}).step);

    // Writes the names and data types the Ghidra scripts apply, from the Zig definitions. Not
    // installed either: `make ghidra-annotate` runs it.
    const ghidragen = b.addExecutable(.{
        .name = "ghidragen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/ghidragen/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "openreliant", .module = lib },
            },
        }),
    });

    // Its tests check the names tables kept by hand, which Ghidra applies with its own rows.
    for ([_][]const u8{ "LANCER.EXE.tsv", "LANCER.EXE.runtime.tsv", "srd3d.dll.tsv" }) |table| {
        ghidragen.root_module.addAnonymousImport(table, .{
            .root_source_file = b.path(b.fmt("ghidra/names/{s}", .{table})),
        });
    }

    const ghidragen_step = b.step("ghidragen", "Build the Ghidra name and type table generator");
    ghidragen_step.dependOn(&b.addInstallArtifact(ghidragen, .{}).step);

    const run_step = b.step("run", "Run sltool");
    const run_cmd = b.addRunArtifact(sltool);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const lib_tests = b.addTest(.{ .root_module = lib });
    const exe_tests = b.addTest(.{ .root_module = sltool.root_module });
    const tablegen_tests = b.addTest(.{ .root_module = tablegen.root_module });
    const ghidragen_tests = b.addTest(.{ .root_module = ghidragen.root_module });
    const openreliant_tests = b.addTest(.{ .root_module = openreliant.root_module });
    const platform_tests = b.addTest(.{ .root_module = platform });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(tablegen_tests).step);
    test_step.dependOn(&b.addRunArtifact(ghidragen_tests).step);
    test_step.dependOn(&b.addRunArtifact(openreliant_tests).step);
    test_step.dependOn(&b.addRunArtifact(platform_tests).step);
}

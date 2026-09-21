const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library of StarLancer file-format readers, shared by every tool (and, later, the engine).
    const lib = b.addModule("starlancer", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const sltool = b.addExecutable(.{
        .name = "sltool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sltool/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "starlancer", .module = lib },
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
                .{ .name = "starlancer", .module = lib },
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
                .{ .name = "starlancer", .module = lib },
            },
        }),
    });

    // Its tests check the names tables kept by hand, which Ghidra applies with its own rows.
    for ([_][]const u8{ "LANCER.EXE.tsv", "LANCER.EXE.runtime.tsv" }) |table| {
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
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(tablegen_tests).step);
    test_step.dependOn(&b.addRunArtifact(ghidragen_tests).step);
}

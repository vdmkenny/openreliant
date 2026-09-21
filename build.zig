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

    // Derives the mission script VM's opcode table from the game binary. Not installed: it is a
    // development tool, run by `make vm-opcodes`, and its output is committed.
    const vmgen = b.addExecutable(.{
        .name = "vmgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/vmgen/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "starlancer", .module = lib },
            },
        }),
    });

    const vmgen_step = b.step("vmgen", "Build the VM opcode table generator");
    vmgen_step.dependOn(&b.addInstallArtifact(vmgen, .{}).step);

    const run_step = b.step("run", "Run sltool");
    const run_cmd = b.addRunArtifact(sltool);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const lib_tests = b.addTest(.{ .root_module = lib });
    const exe_tests = b.addTest(.{ .root_module = sltool.root_module });
    const vmgen_tests = b.addTest(.{ .root_module = vmgen.root_module });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(vmgen_tests).step);
}

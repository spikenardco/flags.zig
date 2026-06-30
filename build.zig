const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const flags_mod = b.addModule("flags", .{
        .root_source_file = b.path("src/flags.zig"),
        .target = target,
        .optimize = optimize,
    });

    const flags_tests = b.addTest(.{ .root_module = flags_mod });
    const run_flags_tests = b.addRunArtifact(flags_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_flags_tests.step);
}

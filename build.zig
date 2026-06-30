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

    // A run step that will run the test executable.
    const run_flags_tests = b.addRunArtifact(flags_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_flags_tests.step);

    inline for (.{
        .{ "example", "examples/demo.zig" },
        .{ "demo", "examples/demo.zig" },
        .{ "git", "examples/git.zig" },
        .{ "list_flags", "examples/list_flags.zig" },
        .{ "positionals", "examples/positionals.zig" },
    }) |ex| {
        const ex_mod = b.addModule(ex[0], .{
            .root_source_file = b.path(ex[1]),
            .target = target,
            .optimize = optimize,
        });
        ex_mod.addImport("flags", flags_mod);
        const ex_exe = b.addExecutable(.{
            .name = ex[0],
            .root_module = ex_mod,
        });
        const run_ex = b.addRunArtifact(ex_exe);
        if (b.args) |args| run_ex.addArgs(args);
        const step = b.step(ex[0], "Run the " ++ ex[0] ++ " example");
        step.dependOn(&run_ex.step);
    }
}

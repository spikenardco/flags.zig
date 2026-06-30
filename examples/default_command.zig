const std = @import("std");
const flags = @import("flags");

const CLI = struct {
    verbose: bool = false,
    command: union(enum) {
        default: struct {},
        serve: struct { port: u16 = 8080 },
        version: void,
    } = .{ .default = .{} },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var diag: flags.Diagnostic = .{};
    const cli = flags.parse(allocator, args, CLI, &diag) catch |err| {
        diag.report();
        std.process.exit(if (err == error.HelpRequested) 0 else 1);
    };

    if (cli.verbose) std.debug.print("verbose mode\n", .{});

    switch (cli.command) {
        .default => std.debug.print("no subcommand given\n", .{}),
        .serve => |s| std.debug.print("serving on port {d}\n", .{s.port}),
        .version => std.debug.print("version 1.0.0\n", .{}),
    }
}

const std = @import("std");
const flags = @import("flags");

const CLI = struct {
    verbose: bool = false,
    config: ?[]const u8 = null,
    command: union(enum) {
        serve: struct {
            host: []const u8 = "localhost",
            port: u16 = 8080,
        },
        greet: struct {
            name: []const u8 = "world",
            times: u8 = 1,
        },
    },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var diag: flags.Diagnostic = .{};
    const cli = flags.parse(allocator, args, CLI, &diag) catch |err| {
        diag.report();
        std.process.exit(if (err == error.HelpRequested) 0 else 1);
    };

    if (cli.verbose) {
        std.debug.print("[verbose] config={s}\n", .{cli.config orelse "(none)"});
    }

    switch (cli.command) {
        .serve => |s| std.debug.print("Starting server on {s}:{d}\n", .{ s.host, s.port }),
        .greet => |g| {
            for (0..g.times) |_| std.debug.print("Hello, {s}!\n", .{g.name});
        },
    }
}

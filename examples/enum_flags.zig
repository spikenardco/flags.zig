const std = @import("std");
const flags = @import("flags");

const Color = enum { red, green, blue };
const LogLevel = enum { debug, info, warn, err };

const Args = struct {
    color: Color = .blue,
    level: LogLevel = .info,
    verbose: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var diag: flags.Diagnostic = .{};
    const cli = flags.parse(allocator, args, Args, &diag) catch |err| {
        diag.report();
        std.process.exit(if (err == error.HelpRequested) 0 else 1);
    };

    std.debug.print("color: {s}\n", .{@tagName(cli.color)});
    std.debug.print("level: {s}\n", .{@tagName(cli.level)});
    if (cli.verbose) std.debug.print("verbose: true\n", .{});
}

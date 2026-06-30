const std = @import("std");
const flags = @import("flags");

const Args = struct {
    verbose: bool = false,
    positional: struct {
        input: []const u8,
        output: []const u8 = "out.txt",
        mode: enum { read, write, append } = .write,
    },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var diag: flags.Diagnostic = .{};
    const cli = flags.parse(allocator, args, Args, &diag) catch |err| {
        diag.report();
        std.process.exit(if (err == error.HelpRequested) 0 else 1);
    };

    if (cli.verbose) {
        std.debug.print("mode: {s}\n", .{@tagName(cli.positional.mode)});
    }
    std.debug.print("copying {s} to {s}\n", .{ cli.positional.input, cli.positional.output });
}

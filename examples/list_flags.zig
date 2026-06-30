const std = @import("std");
const flags = @import("flags");

const Args = struct {
    files: []const []const u8 = &.{},
    ports: []const u16 = &.{},
    tags: []const []const u8 = &.{},
    format: enum { json, yaml, toml } = .json,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var diag: flags.Diagnostic = .{};
    const cli = flags.parse(allocator, args, Args, &diag) catch |err| {
        diag.report();
        std.process.exit(if (err == error.HelpRequested) 0 else 1);
    };

    std.debug.print("format: {s}\n", .{@tagName(cli.format)});
    for (cli.files) |f| std.debug.print("file: {s}\n", .{f});
    for (cli.ports) |p| std.debug.print("port: {d}\n", .{p});
    for (cli.tags) |t| std.debug.print("tag: {s}\n", .{t});
}

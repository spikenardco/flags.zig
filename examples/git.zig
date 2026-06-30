const std = @import("std");
const flags = @import("flags");

const CLI = union(enum) {
    commit: struct {
        message: ?[]const u8 = null,
        all: bool = false,
        amend: bool = false,
    },
    branch: struct {
        name: []const u8,
        delete: bool = false,
    },
    clone: struct {
        url: []const u8,
        depth: ?u32 = null,
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

    switch (cli) {
        .commit => |c| {
            if (c.all) std.debug.print("staging all files\n", .{});
            if (c.amend) std.debug.print("amending previous commit\n", .{});
            if (c.message) |msg| {
                std.debug.print("committing: {s}\n", .{msg});
            } else {
                std.debug.print("opening editor for commit message\n", .{});
            }
        },
        .branch => |b| {
            if (b.delete) {
                std.debug.print("deleting branch {s}\n", .{b.name});
            } else {
                std.debug.print("creating branch {s}\n", .{b.name});
            }
        },
        .clone => |c| {
            if (c.depth) |d| {
                std.debug.print("shallow clone {s} at depth {d}\n", .{ c.url, d });
            } else {
                std.debug.print("full clone {s}\n", .{c.url});
            }
        },
    }
}

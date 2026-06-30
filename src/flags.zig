/// Comptime-first CLI parser with typed flags, positional args, subcommands, and slices.
const std = @import("std");

/// Carries error context out of `parse` so the caller can render messages and
/// usage. `parse` never prints and never exits; it populates this instead.
pub const Diagnostic = struct {
    /// The offending argument for a parse error (e.g. "--prot"), if any.
    token: ?[]const u8 = null,
    /// Human-readable message for a parse error, if any.
    message: ?[]const u8 = null,
    /// Comptime-generated usage text, set on error.HelpRequested.
    usage: ?[]const u8 = null,

    /// Print usage (if set) or the error message to stderr. Convenience only.
    pub fn report(self: Diagnostic) void {
        if (self.usage) |u| {
            std.debug.print("{s}\n", .{u});
            return;
        }
        if (self.message) |m| {
            if (self.token) |t| {
                std.debug.print("error: {s}: {s}\n", .{ m, t });
            } else {
                std.debug.print("error: {s}\n", .{m});
            }
        }
    }
};

/// Parse args into a struct (single command) or union(enum) (subcommands).
///
/// Caller passes full argv; the parser skips argv[0] (the program name).
///
/// Allocator is used for slice field allocation; caller owns returned memory.
pub fn parse(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    comptime T: type,
    diag: *Diagnostic,
) !T {
    if (args.len == 0) return error.EmptyArgs;
    const trimmed = args[1..];
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => return parse_struct(allocator, trimmed, T, diag),
        .@"union" => {
            if (info.@"union".tag_type == null) {
                @compileError("Args must be a union(enum) to use subcommands");
            }
            return parse_commands(allocator, trimmed, T, diag);
        },
        else => @compileError("Args must be a struct or union(enum)"),
    }
}

/// Apply default value or null for optional fields, otherwise return the given error.
fn apply_default(comptime field: std.builtin.Type.StructField, result: anytype, comptime error_type: anyerror) !void {
    if (field.defaultValue()) |default| {
        @field(result, field.name) = default;
    } else if (comptime @typeInfo(field.type) == .optional) {
        @field(result, field.name) = @as(field.type, null);
    } else {
        return error_type;
    }
}

/// Find the index of the '@"--"' field that separates flags from positionals.
fn separator_index(comptime fields: []const std.builtin.Type.StructField) ?usize {
    inline for (fields, 0..) |field, index| {
        if (std.mem.eql(u8, field.name, "--")) return index;
    }
    return null;
}

/// Parse a struct schema of named flags and optional positional args.
fn parse_struct(allocator: std.mem.Allocator, args: []const []const u8, comptime T: type, diag: *Diagnostic) !T {
    const fields = std.meta.fields(T);
    const marker_idx = comptime separator_index(fields);
    const named_fields = if (marker_idx) |idx| fields[0..idx] else fields;
    const positional_fields = if (marker_idx) |idx| fields[idx + 1 ..] else &[_]std.builtin.Type.StructField{};

    if (marker_idx) |idx| {
        if (fields[idx].type != void) {
            @compileError("'@" ++ "--" ++ "' marker must be declared as void");
        }
    }

    const subcmd_idx = comptime subcommand_field_index(named_fields);
    if (comptime subcmd_idx != null and positional_fields.len > 0) {
        @compileError("subcommands and positional arguments cannot coexist in the same struct");
    }

    var result: T = undefined;
    var seen = std.mem.zeroes([named_fields.len]bool);
    var positional_index: usize = 0;
    var positional_only = false;

    var slice_lists = std.mem.zeroes([named_fields.len]std.ArrayList([]const u8));
    inline for (named_fields, 0..) |field, fi| {
        if (comptime is_slice_type(field.type)) {
            slice_lists[fi] = .empty;
        }
    }

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (is_help_arg(arg)) {
            diag.usage = comptime usage(T);
            return error.HelpRequested;
        }

        if (std.mem.eql(u8, arg, "--")) {
            if (positional_fields.len == 0) {
                diag.token = arg;
                diag.message = "unexpected argument";
                return error.UnexpectedArgument;
            }
            positional_only = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--") and !positional_only) {
            const trimmed = arg[2..];
            var flag_name = trimmed;
            var flag_value: ?[]const u8 = null;

            if (std.mem.indexOfScalar(u8, trimmed, '=')) |pos| {
                flag_name = trimmed[0..pos];
                flag_value = trimmed[pos + 1 ..];
            }

            var found = false;
            inline for (named_fields, 0..) |field, field_index| {
                if (comptime is_union_subcommand(field)) continue;
                if (std.mem.eql(u8, flag_name, field.name)) {
                    found = true;

                    if (comptime is_slice_type(field.type)) {
                        const fv = flag_value orelse {
                            diag.token = arg;
                            diag.message = "missing value for flag";
                            return error.MissingValue;
                        };
                        var iter = std.mem.splitScalar(u8, fv, ',');
                        while (iter.next()) |part| {
                            try slice_lists[field_index].append(allocator, part);
                        }
                        seen[field_index] = true;
                    } else {
                        if (seen[field_index]) {
                            diag.token = arg;
                            diag.message = "duplicate flag";
                            return error.DuplicateFlag;
                        }
                        seen[field_index] = true;
                        @field(result, field.name) = parse_value(field.type, flag_value) catch |e| {
                            diag.token = arg;
                            diag.message = "invalid value";
                            return e;
                        };
                    }
                    break;
                }
            }

            if (!found) {
                diag.token = arg;
                diag.message = "unknown flag";
                return error.UnknownFlag;
            }
            continue;
        }

        if (!positional_only and std.mem.startsWith(u8, arg, "-")) {
            diag.token = arg;
            diag.message = "unexpected argument";
            return error.UnexpectedArgument;
        }

        if (comptime subcmd_idx) |si| {
            const subcmd_field = named_fields[si];
            const SubT = unwrap_optional(subcmd_field.type);
            const parsed = try parse_commands(allocator, args[i..], SubT, diag);
            if (comptime @typeInfo(subcmd_field.type) == .optional) {
                @field(result, subcmd_field.name) = @as(subcmd_field.type, parsed);
            } else {
                @field(result, subcmd_field.name) = parsed;
            }
            seen[si] = true;
            break;
        }

        if (positional_fields.len == 0) {
            diag.token = arg;
            diag.message = "unexpected argument";
            return error.UnexpectedArgument;
        }

        if (positional_index >= positional_fields.len) {
            diag.token = arg;
            diag.message = "too many positional arguments";
            return error.TooManyPositionals;
        }

        inline for (positional_fields, 0..) |field, pi| {
            if (pi == positional_index) {
                @field(result, field.name) = parse_value(field.type, arg) catch |e| {
                    diag.token = arg;
                    diag.message = "invalid value";
                    return e;
                };
            }
        }
        positional_index += 1;
        positional_only = true;
    }

    // Build slices and apply defaults.
    inline for (named_fields, 0..) |field, field_index| {
        if (comptime is_union_subcommand(field)) {
            if (!seen[field_index]) {
                try apply_default(field, &result, error.MissingSubcommand);
            }
        } else if (comptime is_slice_type(field.type)) {
            if (seen[field_index]) {
                const items = slice_lists[field_index].items;
                const child = comptime @typeInfo(field.type).pointer.child;
                const typed = try allocator.alloc(child, items.len);
                for (items, 0..) |raw, j| {
                    typed[j] = try parse_scalar(child, raw);
                }
                @field(result, field.name) = typed;
            } else {
                const child = comptime @typeInfo(field.type).pointer.child;
                if (field.defaultValue()) |default| {
                    const default_slice: field.type = default;
                    @field(result, field.name) = try allocator.dupe(child, default_slice);
                } else {
                    return error.MissingRequiredFlag;
                }
            }
        } else {
            if (!seen[field_index]) {
                try apply_default(field, &result, error.MissingRequiredFlag);
            }
        }
    }

    // Apply defaults for missing positional args.
    inline for (positional_fields, 0..) |field, pi| {
        if (pi >= positional_index) {
            try apply_default(field, &result, error.MissingRequiredPositional);
        }
    }

    return result;
}

/// Unwrap optional types before parsing the inner scalar value.
fn parse_value(comptime T: type, value: ?[]const u8) !T {
    if (@typeInfo(T) == .optional) {
        return try parse_scalar(@typeInfo(T).optional.child, value);
    }
    return parse_scalar(T, value);
}

/// Parse a scalar type: bool, int, float, enum, or string.
fn parse_scalar(comptime T: type, value: ?[]const u8) !T {
    if (T == bool) {
        if (value == null) return true;
        return parse_bool(value.?);
    }

    const v = value orelse return error.MissingValue;

    if (T == []const u8) return v;
    if (T == []u8) @compileError("use []const u8 for flag values");

    switch (@typeInfo(T)) {
        .int => return std.fmt.parseInt(T, v, 0) catch return error.InvalidValue,
        .float => return std.fmt.parseFloat(T, v) catch return error.InvalidValue,
        .@"enum" => return std.meta.stringToEnum(T, v) orelse error.InvalidValue,
        else => @compileError("Unsupported flag type: " ++ @typeName(T)),
    }
}

/// Parse a boolean string value; accepts "true" or "false" only.
fn parse_bool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidValue;
}

/// Parse a subcommand field as either a struct or nested union(enum).
fn parse_subcommand(
    allocator: std.mem.Allocator,
    comptime field: std.builtin.Type.UnionField,
    args: []const []const u8,
    diag: *Diagnostic,
) !field.type {
    const subcommand_info = @typeInfo(field.type);
    return switch (subcommand_info) {
        .@"struct" => try parse_struct(allocator, args, field.type, diag),
        .@"union" => blk: {
            if (subcommand_info.@"union".tag_type == null) {
                @compileError("subcommand types must be struct or union(enum)");
            }
            break :blk try parse_commands(allocator, args, field.type, diag);
        },
        .void => if (args.len > 0) blk: {
            diag.token = args[0];
            diag.message = "unexpected argument";
            break :blk error.UnexpectedArgument;
        } else {},
        else => @compileError("subcommand types must be struct, union(enum), or void"),
    };
}

/// Match and parse the first arg as a subcommand name, then parse the rest.
fn parse_commands(allocator: std.mem.Allocator, args: []const []const u8, comptime T: type, diag: *Diagnostic) !T {
    const fields = std.meta.fields(T);

    if (args.len == 0) return error.MissingSubcommand;

    const arg = args[0];
    if (is_help_arg(arg)) {
        diag.usage = comptime usage(T);
        return error.HelpRequested;
    }

    inline for (fields) |field| {
        if (std.mem.eql(u8, arg, field.name)) {
            const parsed = try parse_subcommand(allocator, field, args[1..], diag);
            return @unionInit(T, field.name, parsed);
        }
    }

    diag.token = arg;
    diag.message = "unknown subcommand";
    return error.UnknownSubcommand;
}

/// Return true if the type is a slice type (not []const u8 which is a string).
fn is_slice_type(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.size == .slice and ptr.child != u8,
        else => false,
    };
}

/// Unwrap an optional type to its child, or return the type as-is.
fn unwrap_optional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |opt| opt.child,
        else => T,
    };
}

/// Check whether a struct field is a union(enum) subcommand carrier.
fn is_union_subcommand(comptime field: std.builtin.Type.StructField) bool {
    const T = unwrap_optional(field.type);
    return switch (@typeInfo(T)) {
        .@"union" => |u| u.tag_type != null,
        else => false,
    };
}

/// Find the index of the single union(enum) subcommand field, if any.
fn subcommand_field_index(comptime fields: []const std.builtin.Type.StructField) ?usize {
    var idx: ?usize = null;
    for (fields, 0..) |field, i| {
        if (is_union_subcommand(field)) {
            if (idx != null) @compileError("only one union(enum) subcommand field is allowed");
            idx = i;
        }
    }
    return idx;
}

/// Return true if the argument is a help flag (-h or --help).
fn is_help_arg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

/// Public: the usage text for a type. Uses `pub const help` if declared,
/// otherwise the comptime-generated usage (Task 4).
pub fn usage(comptime T: type) []const u8 {
    if (@hasDecl(T, "help")) return T.help;
    return render_usage(T);
}

fn render_usage(comptime T: type) []const u8 {
    comptime {
        return switch (@typeInfo(T)) {
            .@"struct" => generate_struct_usage(T),
            .@"union" => generate_union_usage(T),
            else => "",
        };
    }
}

fn generate_struct_usage(comptime T: type) []const u8 {
    comptime {
        var flags_text: []const u8 = "";
        var cmds_text: []const u8 = "";
        for (std.meta.fields(T)) |field| {
            if (is_union_subcommand(field)) {
                const SubT = unwrap_optional(field.type);
                for (std.meta.fields(SubT)) |variant| {
                    cmds_text = cmds_text ++ "  " ++ variant.name ++ "\n";
                }
            } else {
                flags_text = flags_text ++ "  --" ++ field.name ++ "  " ++
                    @typeName(field.type) ++ default_label(field) ++ "\n";
            }
        }
        var out: []const u8 = "";
        if (flags_text.len > 0) out = out ++ "Flags:\n" ++ flags_text;
        if (cmds_text.len > 0) out = out ++ "Commands:\n" ++ cmds_text;
        return out;
    }
}

fn generate_union_usage(comptime T: type) []const u8 {
    comptime {
        var out: []const u8 = "Commands:\n";
        for (std.meta.fields(T)) |field| {
            out = out ++ "  " ++ field.name ++ "\n";
        }
        return out;
    }
}

fn default_label(comptime field: std.builtin.Type.StructField) []const u8 {
    if (@typeInfo(field.type) == .optional) return " (optional)";
    if (is_slice_type(field.type)) return " (repeatable)";
    if (field.defaultValue()) |d| {
        return " (default: " ++ value_to_string(field.type, d) ++ ")";
    }
    return " (required)";
}

fn value_to_string(comptime T: type, comptime v: T) []const u8 {
    return switch (@typeInfo(T)) {
        .pointer => v,
        .@"enum" => @tagName(v),
        .bool => if (v) "true" else "false",
        else => std.fmt.comptimePrint("{}", .{v}),
    };
}

// =============================================================================
// Tests
// =============================================================================

const TestArena = struct {
    arena: std.heap.ArenaAllocator,
    diag: Diagnostic = .{},

    fn init() TestArena {
        return .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    }
    fn deinit(self: *TestArena) void {
        self.arena.deinit();
    }
    fn run(self: *TestArena, comptime T: type, argv: []const []const u8) !T {
        return parse(self.arena.allocator(), argv, T, &self.diag);
    }
    fn expect_err(self: *TestArena, expected: anyerror, comptime T: type, argv: []const []const u8) !void {
        try std.testing.expectError(expected, self.run(T, argv));
    }
};

test "diagnostic names unknown flag" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct { port: u16 = 8080 };
    try ta.expect_err(error.UnknownFlag, Args, &.{ "prog", "--prot=80" });
    try std.testing.expectEqualStrings("--prot=80", ta.diag.token.?);
    try std.testing.expectEqualStrings("unknown flag", ta.diag.message.?);
}

test "diagnostic names invalid value" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct { port: u16 = 8080 };
    try ta.expect_err(error.InvalidValue, Args, &.{ "prog", "--port=nope" });
    try std.testing.expectEqualStrings("--port=nope", ta.diag.token.?);
}

test "diagnostic names unknown subcommand" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = union(enum) { start: struct {}, stop: struct {} };
    try ta.expect_err(error.UnknownSubcommand, CLI, &.{ "prog", "restart" });
    try std.testing.expectEqualStrings("restart", ta.diag.token.?);
    try std.testing.expectEqualStrings("unknown subcommand", ta.diag.message.?);
}

test "help requested at top level" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct {
        verbose: bool = false,
        pub const help = "Usage: app [--verbose]";
    };
    try ta.expect_err(error.HelpRequested, Args, &.{ "prog", "--help" });
    try std.testing.expectEqualStrings("Usage: app [--verbose]", ta.diag.usage.?);
}

test "help requested at subcommand level uses that level" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = union(enum) {
        server: struct {
            port: u16 = 8080,
            pub const help = "server help";
        },
    };
    try ta.expect_err(error.HelpRequested, CLI, &.{ "prog", "server", "--help" });
    try std.testing.expectEqualStrings("server help", ta.diag.usage.?);
}

test "auto usage for flag struct" {
    const Args = struct {
        name: []const u8 = "joe",
        port: u16 = 8080,
        verbose: bool = false,
        config: ?[]const u8 = null,
        host: []const u8,
    };
    try std.testing.expectEqualStrings(
        \\Flags:
        \\  --name  []const u8 (default: joe)
        \\  --port  u16 (default: 8080)
        \\  --verbose  bool (default: false)
        \\  --config  ?[]const u8 (optional)
        \\  --host  []const u8 (required)
        \\
    , comptime usage(Args));
}

test "auto usage for union" {
    const CLI = union(enum) { start: struct {}, stop: struct {} };
    try std.testing.expectEqualStrings(
        \\Commands:
        \\  start
        \\  stop
        \\
    , comptime usage(CLI));
}

test "auto usage with flags and commands" {
    const CLI = struct {
        verbose: bool = false,
        command: union(enum) { serve: struct {}, stop: struct {} },
    };
    try std.testing.expectEqualStrings(
        \\Flags:
        \\  --verbose  bool (default: false)
        \\Commands:
        \\  serve
        \\  stop
        \\
    , comptime usage(CLI));
}

test "pub const help overrides auto usage" {
    const Args = struct {
        v: bool = false,
        pub const help = "custom";
    };
    try std.testing.expectEqualStrings("custom", comptime usage(Args));
}

test "auto help generation" {
    const Args = struct {
        name: []const u8 = "joe",
        port: u16 = 8080,
        active: bool = false,
    };

    try std.testing.expectEqual(false, @hasDecl(Args, "help"));

    const Args2 = struct {
        verbose: bool = false,
        pub const help = "Usage: myapp";
    };
    try std.testing.expectEqual(true, @hasDecl(Args2, "help"));
    try std.testing.expectEqualStrings("Usage: myapp", Args2.help);
}

test "bare argument rejected without positionals" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct { name: []const u8 = "joe" };
    try ta.expect_err(error.UnexpectedArgument, Args, &.{ "prog", "name=jack" });
}

test "parse defaults" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct {
        name: []const u8 = "joe",
        active: bool = false,
        port: u16 = 5000,
        rate: f32 = 1.0,
    };
    const flags = try ta.run(Args, &.{"prog"});
    try std.testing.expectEqualStrings("joe", flags.name);
    try std.testing.expectEqual(false, flags.active);
    try std.testing.expectEqual(5000, flags.port);
    try std.testing.expectEqual(1.0, flags.rate);
}

test "parse primitives" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct {
        name: []const u8 = "default",
        port: u16 = 8080,
        rate: f32 = 1.0,
        active: bool = false,
    };
    const flags = try ta.run(Args, &.{ "prog", "--name=test", "--port=9090", "--rate=2.5", "--active" });
    try std.testing.expectEqualStrings("test", flags.name);
    try std.testing.expectEqual(9090, flags.port);
    try std.testing.expectEqual(2.5, flags.rate);
    try std.testing.expectEqual(true, flags.active);
}

test "parse enum" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Format = enum { json, yaml, toml };
    const Args = struct { format: Format = .json };
    const flags = try ta.run(Args, &.{ "prog", "--format=yaml" });
    try std.testing.expectEqual(Format.yaml, flags.format);
}

test "parse enum with default" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Format = enum { json, yaml, toml };
    const Args = struct { format: Format = .json };
    const flags = try ta.run(Args, &.{"prog"});
    try std.testing.expectEqual(Format.json, flags.format);
}

test "parse optional types" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct {
        config: ?[]const u8 = null,
        count: ?u32 = null,
        verbose: ?bool = null,
    };

    const flags1 = try ta.run(Args, &.{"prog"});
    try std.testing.expectEqual(null, flags1.config);
    try std.testing.expectEqual(null, flags1.count);
    try std.testing.expectEqual(null, flags1.verbose);

    const flags2 = try ta.run(Args, &.{ "prog", "--config=/path/to/config", "--count=42", "--verbose" });
    try std.testing.expectEqualStrings("/path/to/config", flags2.config.?);
    try std.testing.expectEqual(42, flags2.count.?);
    try std.testing.expectEqual(true, flags2.verbose.?);
}

test "parse boolean formats" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct { flag: bool = false };

    const flags1 = try ta.run(Args, &.{ "prog", "--flag" });
    try std.testing.expectEqual(true, flags1.flag);

    const flags2 = try ta.run(Args, &.{ "prog", "--flag=true" });
    try std.testing.expectEqual(true, flags2.flag);

    const flags3 = try ta.run(Args, &.{ "prog", "--flag=false" });
    try std.testing.expectEqual(false, flags3.flag);
}

test "parse subcommand" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = union(enum) {
        start: struct { host: []const u8 = "localhost", port: u16 = 8080 },
        stop: struct { force: bool = false },
    };

    const result1 = try ta.run(CLI, &.{ "prog", "start", "--host=0.0.0.0", "--port=3000" });
    try std.testing.expectEqualStrings("0.0.0.0", result1.start.host);
    try std.testing.expectEqual(3000, result1.start.port);

    const result2 = try ta.run(CLI, &.{ "prog", "stop", "--force" });
    try std.testing.expectEqual(true, result2.stop.force);
}

test "parse subcommand with defaults" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = union(enum) {
        start: struct { host: []const u8 = "localhost", port: u16 = 8080 },
        stop: struct {},
    };
    const result = try ta.run(CLI, &.{ "prog", "start" });
    try std.testing.expectEqualStrings("localhost", result.start.host);
    try std.testing.expectEqual(8080, result.start.port);
}

test "void subcommand variant" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = union(enum) { start: struct { port: u16 = 8080 }, stop: void };
    const result = try ta.run(CLI, &.{ "prog", "stop" });
    try std.testing.expectEqual(CLI.stop, result);

    const result2 = try ta.run(CLI, &.{ "prog", "start" });
    try std.testing.expectEqual(8080, result2.start.port);
}

test "void subcommand variant with extra args" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = union(enum) { start: struct { port: u16 = 8080 }, stop: void };
    try ta.expect_err(error.UnexpectedArgument, CLI, &.{ "prog", "stop", "--force" });
}

test "void subcommand variant rejects help arg" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = union(enum) { start: struct { port: u16 = 8080 }, stop: void };
    try ta.expect_err(error.UnexpectedArgument, CLI, &.{ "prog", "stop", "--help" });
}

test "missing subcommand" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = union(enum) { start: struct { host: []const u8 = "localhost" }, stop: struct { force: bool = false } };
    try ta.expect_err(error.MissingSubcommand, CLI, &.{"prog"});
}

test "unknown subcommand" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = struct {
        verbose: bool = false,
        command: union(enum) { start: struct { host: []const u8 = "localhost" }, stop: struct { force: bool = false } },
    };
    try ta.expect_err(error.UnknownSubcommand, CLI, &.{ "prog", "--verbose", "restart" });
}

test "duplicate flag" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct { port: u16 = 8080 };
    try ta.expect_err(error.DuplicateFlag, Args, &.{ "prog", "--port=8080", "--port=9090" });
}

test "missing value" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct { name: []const u8 };
    try ta.expect_err(error.MissingValue, Args, &.{ "prog", "--name" });
}

test "invalid enum value" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Format = enum { json, yaml, toml };
    const Args = struct { format: Format = .json };
    try ta.expect_err(error.InvalidValue, Args, &.{ "prog", "--format=xml" });
}

test "invalid int value" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct { port: u16 = 8080 };
    try ta.expect_err(error.InvalidValue, Args, &.{ "prog", "--port=not-a-number" });
}

test "no args provided" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct { port: u16 = 8080 };
    try ta.expect_err(error.EmptyArgs, Args, &.{});
}

test "missing required flag" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct { name: []const u8 };
    try ta.expect_err(error.MissingRequiredFlag, Args, &.{"prog"});
}

test "complex subcommand structure" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = union(enum) {
        server: union(enum) {
            start: struct { host: []const u8 = "0.0.0.0", port: u16 = 8080 },
            stop: struct { force: bool = false },
            pub const help = "Server commands";
        },
        client: struct { url: []const u8, timeout: u32 = 30 },
    };

    const result = try ta.run(CLI, &.{ "prog", "server", "start", "--port=9090" });
    try std.testing.expectEqualStrings("0.0.0.0", result.server.start.host);
    try std.testing.expectEqual(9090, result.server.start.port);
}

test "unexpected argument error" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct { port: u16 = 8080 };
    try ta.expect_err(error.UnexpectedArgument, Args, &.{ "prog", "--port=8080", "extra" });
}

// --- Slice tests ---

test "slice repeated flags" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct { files: []const []const u8 = &.{} };
    const result = try ta.run(Args, &.{ "prog", "--files=a.txt", "--files=b.txt", "--files=c.txt" });
    try std.testing.expectEqual(3, result.files.len);
    try std.testing.expectEqualStrings("a.txt", result.files[0]);
    try std.testing.expectEqualStrings("b.txt", result.files[1]);
    try std.testing.expectEqualStrings("c.txt", result.files[2]);
}

test "slice comma separated" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct { files: []const []const u8 = &.{} };
    const str_result = try ta.run(Args, &.{ "prog", "--files=a.txt,b.txt,c.txt" });
    try std.testing.expectEqual(3, str_result.files.len);
    try std.testing.expectEqualStrings("a.txt", str_result.files[0]);
    try std.testing.expectEqualStrings("b.txt", str_result.files[1]);
    try std.testing.expectEqualStrings("c.txt", str_result.files[2]);

    const single_str_result = try ta.run(Args, &.{ "prog", "--files=single.txt" });
    try std.testing.expectEqual(1, single_str_result.files.len);
    try std.testing.expectEqualStrings("single.txt", single_str_result.files[0]);

    const IntArgs = struct { ports: []const u16 = &.{} };
    const int_result = try ta.run(IntArgs, &.{ "prog", "--ports=80,443,8080" });
    try std.testing.expectEqual(3, int_result.ports.len);
    try std.testing.expectEqual(80, int_result.ports[0]);
    try std.testing.expectEqual(443, int_result.ports[1]);
    try std.testing.expectEqual(8080, int_result.ports[2]);
}

test "slice integer values" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct { ports: []const u16 = &.{} };
    const result = try ta.run(Args, &.{ "prog", "--ports=8080", "--ports=9090", "--ports=3000" });
    try std.testing.expectEqual(3, result.ports.len);
    try std.testing.expectEqual(8080, result.ports[0]);
    try std.testing.expectEqual(9090, result.ports[1]);
    try std.testing.expectEqual(3000, result.ports[2]);
}

test "slice enum values" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Format = enum { json, yaml, toml };
    const Args = struct { formats: []const Format = &.{} };
    const result = try ta.run(Args, &.{ "prog", "--formats=json,yaml,toml" });
    try std.testing.expectEqual(3, result.formats.len);
    try std.testing.expectEqual(Format.json, result.formats[0]);
    try std.testing.expectEqual(Format.yaml, result.formats[1]);
    try std.testing.expectEqual(Format.toml, result.formats[2]);
}

test "slice with default" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct { files: []const []const u8 = &.{} };
    const result = try ta.run(Args, &.{"prog"});
    try std.testing.expectEqual(0, result.files.len);
}

test "slice mixed with scalar flags" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct {
        files: []const []const u8 = &.{},
        verbose: bool = false,
        port: u16 = 8080,
    };
    const result = try ta.run(Args, &.{ "prog", "--files=a.txt", "--verbose", "--files=b.txt", "--port=3000" });
    try std.testing.expectEqual(2, result.files.len);
    try std.testing.expectEqualStrings("a.txt", result.files[0]);
    try std.testing.expectEqualStrings("b.txt", result.files[1]);
    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqual(3000, result.port);
}

test "slice invalid element" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct { ports: []const u16 = &.{} };
    try ta.expect_err(error.InvalidValue, Args, &.{ "prog", "--ports=80,not_a_number" });
}

test "multiple slice fields" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct {
        files: []const []const u8 = &.{},
        ports: []const u16 = &.{},
    };
    const result = try ta.run(Args, &.{ "prog", "--files=a.txt,b.txt", "--ports=80,443" });
    try std.testing.expectEqual(2, result.files.len);
    try std.testing.expectEqualStrings("a.txt", result.files[0]);
    try std.testing.expectEqualStrings("b.txt", result.files[1]);
    try std.testing.expectEqual(2, result.ports.len);
    try std.testing.expectEqual(80, result.ports[0]);
    try std.testing.expectEqual(443, result.ports[1]);
}

test "global flags with subcommand" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = struct {
        verbose: bool = false,
        config: ?[]const u8 = null,
        command: union(enum) {
            serve: struct { host: []const u8 = "0.0.0.0", port: u16 = 8080 },
            migrate: struct { dry_run: bool = false },
        },
    };

    const result = try ta.run(CLI, &.{ "prog", "--verbose", "--config=app.toml", "serve", "--port=3000" });
    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqualStrings("app.toml", result.config.?);
    try std.testing.expectEqualStrings("0.0.0.0", result.command.serve.host);
    try std.testing.expectEqual(3000, result.command.serve.port);
}

test "subcommand with defaults and global flags" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = struct {
        verbose: bool = false,
        command: union(enum) { serve: struct { host: []const u8 = "localhost", port: u16 = 8080 }, stop: struct {} },
    };
    const result = try ta.run(CLI, &.{ "prog", "serve" });
    try std.testing.expectEqual(false, result.verbose);
    try std.testing.expectEqualStrings("localhost", result.command.serve.host);
    try std.testing.expectEqual(8080, result.command.serve.port);
}

test "required subcommand missing" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = struct {
        verbose: bool = false,
        command: union(enum) { serve: struct { port: u16 = 8080 }, migrate: struct { dry_run: bool = false } },
    };
    try ta.expect_err(error.MissingSubcommand, CLI, &.{"prog"});
    try ta.expect_err(error.MissingSubcommand, CLI, &.{ "prog", "--verbose" });
}

test "optional subcommand not given" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = struct {
        verbose: bool = false,
        command: ?union(enum) { serve: struct { port: u16 = 8080 } } = null,
    };
    const result = try ta.run(CLI, &.{ "prog", "--verbose" });
    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqual(null, result.command);
}

test "subcommand with nested union" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = struct {
        verbose: bool = false,
        command: union(enum) {
            server: union(enum) { start: struct { port: u16 = 8080 }, stop: struct { force: bool = false } },
        },
    };
    const result = try ta.run(CLI, &.{ "prog", "--verbose", "server", "start", "--port=3000" });
    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqual(3000, result.command.server.start.port);
}

// --- Positional tests ---

test "positional basic" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct {
        verbose: bool = false,
        @"--": void,
        input: []const u8,
        output: []const u8 = "out.txt",
    };
    const result = try ta.run(Args, &.{ "prog", "--verbose", "main.zig" });
    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqualStrings("main.zig", result.input);
    try std.testing.expectEqualStrings("out.txt", result.output);
}

test "positional multiple" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct {
        @"--": void,
        input: []const u8,
        output: []const u8 = "out.txt",
    };
    const result = try ta.run(Args, &.{ "prog", "main.zig", "build.bin" });
    try std.testing.expectEqualStrings("main.zig", result.input);
    try std.testing.expectEqualStrings("build.bin", result.output);
}

test "positional with explicit separator" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct {
        verbose: bool = false,
        @"--": void,
        input: []const u8,
    };
    const result = try ta.run(Args, &.{ "prog", "--verbose", "--", "main.zig" });
    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqualStrings("main.zig", result.input);
}

test "positional with negative and dash-prefixed values after separator" {
    var ta = TestArena.init();
    defer ta.deinit();

    const ArgsInt = struct { @"--": void, value: i32 };
    const result_int = try ta.run(ArgsInt, &.{ "prog", "--", "-5" });
    try std.testing.expectEqual(-5, result_int.value);

    const ArgsFloat = struct { @"--": void, value: f64 };
    const result_float = try ta.run(ArgsFloat, &.{ "prog", "--", "-3.14" });
    try std.testing.expectEqual(-3.14, result_float.value);

    const ArgsString = struct { @"--": void, name: []const u8 };
    const result_string = try ta.run(ArgsString, &.{ "prog", "--", "-filename" });
    try std.testing.expectEqualStrings("-filename", result_string.name);
}

test "positional missing required" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct { @"--": void, input: []const u8 };
    try ta.expect_err(error.MissingRequiredPositional, Args, &.{"prog"});
}

test "positional too many" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct { @"--": void, input: []const u8 };
    try ta.expect_err(error.TooManyPositionals, Args, &.{ "prog", "a.zig", "b.zig" });
}

test "positional inside subcommand" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = struct {
        verbose: bool = false,
        command: union(enum) {
            compile: struct {
                optimize: bool = false,
                @"--": void,
                input: []const u8,
                output: []const u8 = "a.out",
            },
        },
    };
    const result = try ta.run(CLI, &.{ "prog", "--verbose", "compile", "--optimize", "main.zig" });
    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqual(true, result.command.compile.optimize);
    try std.testing.expectEqualStrings("main.zig", result.command.compile.input);
    try std.testing.expectEqualStrings("a.out", result.command.compile.output);
}

// --- List (ex-deinit) tests ---

test "list fields parse correctly" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct {
        files: []const []const u8 = &.{},
        ports: []const u16 = &.{},
        verbose: bool = false,
    };
    const result = try ta.run(Args, &.{ "prog", "--files=a.txt,b.txt", "--ports=80,443", "--verbose" });
    try std.testing.expectEqual(2, result.files.len);
    try std.testing.expectEqual(2, result.ports.len);
    try std.testing.expectEqual(true, result.verbose);
}

test "subcommand with list fields" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = struct {
        verbose: bool = false,
        command: union(enum) {
            serve: struct { hosts: []const []const u8 = &.{}, port: u16 = 8080 },
            stop: struct {},
        },
    };
    const result = try ta.run(CLI, &.{ "prog", "--verbose", "serve", "--hosts=a.com,b.com" });
    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqual(2, result.command.serve.hosts.len);
}

test "list fields with defaults only" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct {
        files: []const []const u8 = &.{},
        ports: []const u16 = &.{},
        name: []const u8 = "default",
    };
    const result = try ta.run(Args, &.{"prog"});
    try std.testing.expectEqual(0, result.files.len);
    try std.testing.expectEqual(0, result.ports.len);
}

test "optional subcommand null" {
    var ta = TestArena.init();
    defer ta.deinit();
    const CLI = struct {
        verbose: bool = false,
        command: ?union(enum) { serve: struct { hosts: []const []const u8 = &.{} } } = null,
    };
    const result = try ta.run(CLI, &.{ "prog", "--verbose" });
    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqual(null, result.command);
}

test "slice_lists array with non-slice and slice fields" {
    var ta = TestArena.init();
    defer ta.deinit();
    const Args = struct {
        verbose: bool = false,
        files: []const []const u8 = &.{},
        name: []const u8 = "default",
    };
    const result = try ta.run(Args, &.{ "prog", "--files=a.txt,b.txt", "--name=test" });
    try std.testing.expectEqual(false, result.verbose);
    try std.testing.expectEqual(2, result.files.len);
    try std.testing.expectEqualSlices(u8, result.name, "test");
}

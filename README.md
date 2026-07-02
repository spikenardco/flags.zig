# flags.zig

A type-safe command-line argument parser for Zig. Inspired by **Rust clap** and **TigerBeetle's flags**, it lets you define flags using a struct or union(enum) and parses command-line arguments into it.

- Zero runtime overhead. Parsing happens at comptime where possible.
- Type safety. Catch errors at compile time, not runtime.
- Idiomatic Zig. Works with the grain of the language.
- Zero external dependencies.

## Features

- [x] Multiple flag types (bool, string, int, float, enum)
- [x] Struct-based argument definition
- [x] Default values via struct fields
- [x] Error handling for invalid/unknown flags
- [x] Positional arguments via `@"--"` marker
- [x] Subcommands via `union(enum)`
- [x] Repeatable list flags (`--x=a --x=b`)
- [x] Auto-generated `--help`
- [x] Structured errors via `Diagnostic`

## Installation

### 1. Fetch the library

```bash
zig fetch --save git+https://github.com/spikenardco/flags.zig
```

### 2. Add to your `build.zig`

```zig
const flags = b.dependency("flags", .{});
exe.root_module.addImport("flags", flags.module("flags"));
```

## Quick Start

```zig
const std = @import("std");
const flags = @import("flags");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    // Define flags as a struct
    const Args = struct {
        name: []const u8 = "world",
        age: u32 = 25,
        active: bool = false,
        files: []const []const u8 = &.{},
    };

    var diag: flags.Diagnostic = .{};
    const parsed = flags.parse(allocator, args, Args, &diag) catch |err| {
        diag.report();
        std.process.exit(if (err == error.HelpRequested) 0 else 1);
    };

    std.debug.print("Hello {s}! Age: {d}, Active: {}\n", .{
        parsed.name, parsed.age, parsed.active,
    });
}
```

```bash
./program --name=alice --age=30 --active
./program --files=a.txt --files=b.txt --files=c.txt
./program --help
```

## Advanced Features

### Help Documentation

Running with `-h` or `--help` prints auto-generated usage text derived from your schema type. Help is auto-generated at comptime, so it always reflects the actual flag names and types.

If a type declares `pub const help`, that string overrides auto-generation:

```zig
const Args = struct {
    verbose: bool = false,
    port: u16 = 8080,

    pub const help =
        \\Options:
        \\  --verbose    Enable verbose output (default: false)
        \\  --port       Port to listen on (default: 8080)
    ;
};
```

### Subcommands

Git-style subcommands using `union(enum)`:

```zig
const CLI = union(enum) {
    start: struct {
        host: []const u8 = "localhost",
        port: u16 = 8080,
    },
    stop: struct {
        force: bool = false,
    },
};

var diag: flags.Diagnostic = .{};
const cli = flags.parse(allocator, args, CLI, &diag) catch |err| {
    diag.report();
    std.process.exit(if (err == error.HelpRequested) 0 else 1);
};
switch (cli) {
    .start => |s| startServer(s.host, s.port),
    .stop => |s| stopServer(s.force),
}
```

### Global Flags with Subcommands

Combine top-level flags with subcommands using a struct that contains a `union(enum)`:

```zig
const CLI = struct {
    verbose: bool = false,
    config: ?[]const u8 = null,
    command: union(enum) {
        serve: struct {
            host: []const u8 = "0.0.0.0",
            port: u16 = 8080,
        },
        migrate: struct {
            dry_run: bool = false,
        },
    },
};

var diag: flags.Diagnostic = .{};
const cli = flags.parse(allocator, args, CLI, &diag) catch |err| {
    diag.report();
    std.process.exit(if (err == error.HelpRequested) 0 else 1);
};
if (cli.verbose) std.debug.print("verbose mode\n", .{});
switch (cli.command) {
    .serve => |s| startServer(s.host, s.port),
    .migrate => |m| runMigration(m.dry_run),
}
```

```bash
prog --verbose serve --port=3000
prog --config=app.toml migrate --dry_run
```

### Positional Arguments

Use the `@"--"` marker to separate flags from positional arguments:

```zig
const Args = struct {
    verbose: bool = false,
    @"--": void,
    input: []const u8,
    output: []const u8 = "output.txt",
};

// Usage: program --verbose input.txt output.txt
// Access: args.input, args.output
```

Positional arguments are bare words that don't start with `-`. They can be
interleaved with flags in any order. A bare argument starting with `-` is
rejected (this library only supports `--name=value` flag syntax).

### Optional Subcommands

Subcommands can be made optional by wrapping the union type in `?`:

```zig
const CLI = struct {
    verbose: bool = false,
    command: ?union(enum) {
        serve: struct { port: u16 = 8080 },
        stop:  struct {},
    } = null,
};
```

When the subcommand is absent, `command` is `null`.

## Best Practices

- Use struct defaults for common values.
- Define help with `pub const help` when you need hand-written text.
- Use unions for mutually exclusive subcommands.
- Use enums for constrained choices.
- Use optional types for truly optional flags.
- Always handle the error from `parse`. Skipping it defeats the point.
- Don't make every field optional. You lose the type safety that makes this approach useful.
- Keep help text at compile time. No runtime string building.

## Parser vs Application Boundary

The parser handles syntax; the application handles semantics. Keep these in application code:

- Date/time interpretation (`--due=tomorrow`)
- File I/O, encryption, network calls
- Interactive prompts and terminal I/O
- Output formatting and display
- Command aliases (`t` → `task`)
- Configuration file loading

The parser extracts typed values. What you do with them is your business.

## Not planned

- **No short flags.** Only long flags (`--flag=value`), except `-h` for help. For brevity, use `--v` instead of `-v`.
- **No custom types.** Only built-in types and enums.
- **No nested slices.** Slices of slices not supported (`[][]T`).
- **No comma-separated lists.** Use repeated flags (`--x=a --x=b`).
- **Equals syntax only.** Use `--name=value` not `--name value`.
- **Strict boolean values.** Only `true` and `false` are accepted (no `1`, `0`, `yes`, `no`, etc.).
- **No subcommands + positional args.** Use either subcommands or positional arguments, not both in the same struct.

## Credits

Heavily inspired by [TigerBeetle's flags](https://github.com/tigerbeetle/tigerbeetle). The struct-as-schema design, comptime parsing, arena memory model, `Diagnostic`-style error reporting, and no-short-flags philosophy all come from there.

The declarative "derive" sensibility (define a type, get a parser) was popularized by [Rust clap](https://github.com/clap-rs/clap), and that was the conceptual starting point for this project.

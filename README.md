# flags.zig

A type-safe command-line argument parser for Zig. Taking inspiration from **Rust clap**, and **TigerBeetle's flags** implementation, it lets you define flags using a struct or union(enum) and parses command-line arguments into it.

- Zero runtime overhead — parsing happens at comptime where possible
- Type safety — catch errors at compile time, not runtime
- Idiomatic Zig — works with the grain of the language
- Zero external dependencies

## Features

- [x] Multiple flag types (bool, string, int, float, enum)
- [x] Struct-based argument definition
- [x] Default values via struct fields
- [x] Error handling for invalid/unknown flags
- [x] Positional arguments via `positional` struct
- [x] Subcommands via `union(enum)`
- [x] Repeatable list flags (`--x=a --x=b`)
- [x] Auto-generated `--help`
- [x] Structured errors via `Diagnostic`

## Installation

### 1. Fetch the library

```bash
zig fetch --save git+https://github.com/doxalabs/flags.zig
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

### Subcommands without optional unions

Optional subcommands (`command: ?union = null`) are not supported. Use a `default` variant instead:

```zig
command: union(enum) {
    default: struct {},
    serve:   struct { port: u16 = 8080 },
} = .{ .default = .{} },
```

## Best Practices

### DO

1. **Use struct defaults** for common values
2. **Define help** via `pub const help` declarations when you need hand-written text
3. **Use unions** for mutually exclusive subcommands
4. **Leverage enums** for constrained choices
5. **Use optional types** for truly optional flags

### DON'T

1. **Don't** skip error handling
2. **Don't** make all flags optional (defeats type safety)
3. **Don't** use runtime string manipulation for help

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

- **No short flags** — only long flags (`--flag=value`), except `-h` for help. For brevity, use `--v` instead of `-v`
- **No custom types** — only built-in types and enums
- **No nested slices** — slices of slices not supported (`[][]T`)
- **No comma-separated lists** — use repeated flags (`--x=a --x=b`)
- **No optional subcommands** — use a `default` variant
- **Equals syntax only** — use `--name=value` not `--name value`
- **Strict boolean values** — only `true` and `false` are accepted (no `1`, `0`, `yes`, `no`, etc.)
- **No subcommands + positional args** — use either subcommands or positional arguments, not both in the same struct

## Migration (from 0.1)

- `flags.parse(a, args, T)` → `flags.parse(a, args, T, &diag)` with `var diag: flags.Diagnostic = .{};`
- Remove `defer flags.deinit(...)`; use an arena allocator instead (nothing to free).
- `--tags=a,b` → `--tags=a --tags=b` (comma lists removed).
- `positional: struct { ... }` → `@"--": void` + trailing fields, accessed as `result.<name>`.
- `command: ?union = null` → a required union with a `default: struct {}` variant.
- Handle `error.HelpRequested` in your `catch` (print `diag.usage` via `diag.report()`, exit 0).

## Credits

This library draws significant inspiration from two exceptional projects:

- [TigerBeetle's flags](https://github.com/tigerbeetle/tigerbeetle) — struct-based flag definitions and zero-cost abstractions
- [Rust clap](https://github.com/clap-rs/clap) — declarative API design and derive-style patterns

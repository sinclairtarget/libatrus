const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const OutputChoice = enum {
    json,
    yaml,
    html,
};

pub const Options = struct {
    filepath: ?[]u8 = null,
    output_choice: OutputChoice = .json,

    const Self = @This();

    pub fn format(self: Self, alloc: Allocator) ![]u8 {
        return std.fmt.allocPrint(
            alloc,
            ".{{ .filepath = '{?s}', .output_choice = {any} }}",
            .{ self.filepath, self.output_choice },
        );
    }
};

pub fn printUsage(out: *Io.Writer) !void {
    const usage = if (builtin.mode == .Debug)
        \\Usage: atrus [OPTIONS...] <filepath>
        \\       atrus --version
        \\       atrus -h|--help
        \\
        \\Options:
        \\  --html    Output HTML.
        \\  --yaml    Output AST as YAML.
        \\
        \\Debug Options:
        \\  --tokens  Output the token stream prior to parsing.
        \\
        \\If "-" is given as the filepath, input will be read from STDIN.
        \\
    else
        \\Usage: atrus [OPTIONS...] <filepath>
        \\       atrus --version
        \\       atrus -h|--help
        \\
        \\Options:
        \\  --html  Output HTML.
        \\  --yaml  Output AST as YAML.
        \\
        \\If "-" is given as the filepath, input will be read from STDIN.
        \\
        ;

    try out.print(usage, .{});
}

pub const Action = enum {
    tokenize,
    parse,
    print_version,
    help,
};

pub const ArgsError = error {
    NotEnoughArgs,
    UnrecognizedArg,
};

pub const Diagnostic = struct {
    unrecognized: ?[]u8 = null,
};

pub fn parseArgs(
    arena: Allocator,
    diagnostic: *Diagnostic,
) !struct { Action, Options } {
    var args_arena_impl = std.heap.ArenaAllocator.init(arena);
    defer args_arena_impl.deinit();
    const args = try std.process.argsAlloc(args_arena_impl.allocator());

    if (args.len <= 1) {
        return ArgsError.NotEnoughArgs;
    }

    var action: Action = .parse;
    var options = Options{};
    for (1..args.len - 1) |i| {
        if (std.mem.eql(u8, args[i], "--yaml")) {
            options.output_choice = .yaml;
        } else if (std.mem.eql(u8, args[i], "--html")) {
            options.output_choice = .html;
        } else if (
            builtin.mode == .Debug 
            and std.mem.eql(u8, args[i], "--tokens")
        ) {
            action = .tokenize;
        } else {
            diagnostic.unrecognized = args[i];
            return ArgsError.UnrecognizedArg;
        }
    }

    const final = args[args.len - 1];
    if (std.mem.eql(u8, final, "--version")) {
        return .{ .print_version, options };
    } if (std.mem.eql(u8, final, "-h") or std.mem.eql(u8, final, "--help")) {
        return .{ .help, options };
    } else if (std.mem.eql(u8, final, "-")) {
        // Should read from stdin
        return .{ action, options };
    }

    options.filepath = try arena.dupe(u8, final);
    return .{ action, options };
}

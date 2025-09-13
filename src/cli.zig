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
    filepath: ?[]const u8 = null,
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
    const usage = 
        \\Usage: atrus [OPTIONS...] <filepath>
        \\       atrus --version
        \\       atrus -h|--help
        \\
        \\If "-" is given as the filepath, input is read from STDIN.
        \\
        \\Options:
        \\  --html    Output HTML.
        \\  --yaml    Output AST as YAML.
        \\
        ;

    const full_usage = blk: {
        if (builtin.mode == .Debug) {
            const debug_usage = 
                \\
                \\Debug Options:
                \\  --tokens  Output the token stream prior to parsing.
                \\
                ;
            break :blk usage ++ debug_usage;
        } else {
            break :blk usage;
        }
    };

    try out.print("{s}", .{full_usage});
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
    MissingRequiredArg,
};

pub const Diagnostic = struct {
    argname: ?[]const u8 = null,
};

pub fn parseArgs(
    arena: Allocator,
    diagnostic: *Diagnostic,
) !struct { Action, Options } {
    var args_arena_impl = std.heap.ArenaAllocator.init(arena);
    defer args_arena_impl.deinit();
    const args = try std.process.argsAlloc(args_arena_impl.allocator());

    if (args.len < 2) {
        return ArgsError.NotEnoughArgs;
    }

    var action: Action = .parse;
    var options = Options{};
    if (std.mem.eql(u8, args[1], "--version")) {
        return .{ .print_version, options };
    } else if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
        return .{ .help, options };
    }

    for (args[1..args.len - 1]) |arg| {
        if (std.mem.eql(u8, arg, "--yaml")) {
            options.output_choice = .yaml;
        } else if (std.mem.eql(u8, arg, "--html")) {
            options.output_choice = .html;
        } else if (
            builtin.mode == .Debug 
            and std.mem.eql(u8, arg, "--tokens")
        ) {
            action = .tokenize;
        } else {
            diagnostic.argname = arg;
            return ArgsError.UnrecognizedArg;
        }
    }

    const final = args[args.len - 1];
    if (std.mem.startsWith(u8, final, "-") and !std.mem.eql(u8, final, "-")) {
        diagnostic.argname = "filepath";
        return ArgsError.MissingRequiredArg;
    } else {
        options.filepath = try arena.dupe(u8, final);
    }

    return .{ action, options };
}

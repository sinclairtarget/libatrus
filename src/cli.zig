const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const InvocationOptions = struct {
    verbose: bool = false,
    filepath: ?[]u8 = null,
};

pub fn printUsage(out: *Io.Writer) !void {
    const usage =
        \\Usage: atrus [OPTIONS...] <filepath>
        \\       atrus --version
        \\       atrus -h|--help
        \\
        \\Options:
        \\  -v  Enable verbose logging.
        \\
        \\If "-" is given as the filepath, input will be read from STDIN.
        \\
    ;
    try out.print(usage, .{});
}

pub const Action = enum {
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
    alloc: Allocator, 
    options: *InvocationOptions, 
    diagnostic: *Diagnostic,
) !Action {
    const args = try std.process.argsAlloc(alloc);

    if (args.len <= 1) {
        return ArgsError.NotEnoughArgs;
    }

    for (1..args.len - 1) |i| {
        if (std.mem.eql(u8, args[i], "-v")) {
            options.verbose = true;
        } else {
            diagnostic.unrecognized = args[i];
            return ArgsError.UnrecognizedArg;
        }
    }

    const final = args[args.len - 1];
    if (std.mem.eql(u8, final, "--version")) {
        return .print_version;
    } if (std.mem.eql(u8, final, "-h") or std.mem.eql(u8, final, "--help")) {
        return .help;
    } else if (std.mem.eql(u8, final, "-")) {
        // Should read from stdin
        return .parse;
    }

    options.filepath = final;
    return .parse;
}

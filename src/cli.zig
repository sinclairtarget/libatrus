const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const OutputChoice = enum {
    json,
    yaml,
    html,
};

pub const InvocationOptions = struct {
    filepath: ?[]u8 = null,
    output_choice: OutputChoice = .json,

    pub fn format(self: @This(), alloc: Allocator) ![]u8 {
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
        if (std.mem.eql(u8, args[i], "--yaml")) {
            options.output_choice = .yaml;
        } else if (std.mem.eql(u8, args[i], "--html")) {
            options.output_choice = .html;
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

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const OutputChoice = enum {
    json,
    html,
};

pub const Options = struct {
    filepath: ?[]const u8 = null,
    output_choice: OutputChoice = .json,
    pre_only: bool = false,

    const Self = @This();

    pub fn format(self: Self, w: *Io.Writer) Io.Writer.Error!void {
        try w.print(
            ".{{ .filepath = '{?s}', .output_choice = {any}, .pre_only = {any} }}",
            .{ self.filepath, self.output_choice, self.pre_only },
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
        \\  --pre     Skip post-process/resolution phase.
        \\
    ;

    const full_usage = blk: {
        if (builtin.mode == .Debug) {
            const debug_usage =
                \\
                \\Debug Options:
                \\  --tokens  Output the token stream.
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

pub const ArgsError = error{
    NotEnoughArgs,
    UnrecognizedArg,
    MissingRequiredArg,
    IncompatibleArgs,
};

pub const Diagnostic = struct {
    argname: ?[]const u8 = null,
};

/// Parse CLI args.
///
/// Caller responsible for freeing memory held by returned Options.
pub fn parseArgs(
    gpa: Allocator,
    arena: Allocator,
    diagnostic: *Diagnostic,
) !struct { Action, Options } {
    var args_arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer args_arena_impl.deinit();

    const args = try std.process.argsAlloc(args_arena_impl.allocator());
    if (args.len < 2) {
        return ArgsError.NotEnoughArgs;
    }

    if (std.mem.eql(u8, args[1], "--version")) {
        return .{ .print_version, Options{} };
    } else if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
        return .{ .help, Options{} };
    }

    var action = Action.parse;
    var output_choice = OutputChoice.json;
    var pre_only = false;
    var filepath: ?[]const u8 = null;
    for (args[1 .. args.len - 1]) |arg| {
        if (std.mem.eql(u8, arg, "--html")) {
            output_choice = .html;
        } else if (std.mem.eql(u8, arg, "--pre")) {
            pre_only = true;
        } else if (builtin.mode == .Debug and std.mem.eql(u8, arg, "--tokens")) {
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
        filepath = try arena.dupe(u8, final);
    }

    if (pre_only and output_choice == .html) {
        return ArgsError.IncompatibleArgs;
    }

    return .{
        action,
        Options{
            .filepath = filepath,
            .output_choice = output_choice,
            .pre_only = pre_only,
        },
    };
}

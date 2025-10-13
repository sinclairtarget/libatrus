const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const OutputChoice = enum {
    json,
    html,
};

pub const Options = struct {
    filepath_or_input: ?[]const u8 = null,
    output_choice: OutputChoice = .json,
    pre_only: bool = false,

    const Self = @This();

    pub fn format(self: Self, w: *Io.Writer) Io.Writer.Error!void {
        try w.print(
            ".{{ .filepath = '{?s}', .output_choice = {any}, .pre_only = {any} }}",
            .{ self.filepath_or_input, self.output_choice, self.pre_only },
        );
    }
};

pub fn printUsage(out: *Io.Writer) !void {
    const usage =
        \\Usage: atrus [--pre|--html] [FILEPATH]
        \\       atrus --version
        \\       atrus -h|--help
        \\
        \\If no filepath is given, input is read from STDIN.
        \\
        \\Flags:
        \\  -h|--help  Ouptut this help text.
        \\  --html     Output HTML.
        \\  --pre      Skip post-process/resolution phase.
        \\  --version  Print version number.
        \\
    ;

    const full_usage = blk: {
        if (builtin.mode == .Debug) {
            const debug_usage =
                \\
                \\Debug Usage:
                \\       atrus --tokens [FILEPATH | INPUT]
                \\
                \\If a filepath is given, then block tokens are output. If an
                \\input string is given, then inline tokens are output.
                \\
                \\Debug Flags:
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
    var filepath_or_input: ?[]const u8 = null;
    var args_processed: u32 = 1;
    for (args[1..args.len]) |arg| {
        if (std.mem.eql(u8, arg, "--html")) {
            output_choice = .html;
        } else if (std.mem.eql(u8, arg, "--pre")) {
            pre_only = true;
        } else if (builtin.mode == .Debug and std.mem.eql(u8, arg, "--tokens")) {
            action = .tokenize;
        } else {
            filepath_or_input = try arena.dupe(u8, arg);
        }

        args_processed += 1;
        if (filepath_or_input != null) {
            break;
        }
    }

    if (args_processed < args.len) {
        diagnostic.argname = try arena.dupe(u8, args[args_processed]);
        return ArgsError.UnrecognizedArg;
    }

    if (pre_only and output_choice == .html) {
        return ArgsError.IncompatibleArgs;
    }

    return .{
        action,
        Options{
            .filepath_or_input = filepath_or_input,
            .output_choice = output_choice,
            .pre_only = pre_only,
        },
    };
}

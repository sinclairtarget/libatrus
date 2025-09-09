const std = @import("std");
const atrus = @import("atrus");

const Allocator = std.mem.Allocator;
const Io = std.Io;
 
const logger = std.log.scoped(.main);

const InvocationOptions = struct {
    verbose: bool = false,
    filepath: ?[]u8 = null,
};

pub fn main() !void {
    var buffer: [8192]u8 = undefined;
    var fixed_alloc_impl = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fixed_alloc_impl.allocator();
    defer fixed_alloc_impl.reset();

    var stdout_buffer: [64]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var options = InvocationOptions{};
    var diagnostic = Diagnostic{};
    const action = parseArgs(alloc, &options, &diagnostic) catch |err| {
        switch (err) {
            ArgsError.NotEnoughArgs => {
                try printUsage(stdout);
                try stdout.flush();
                die("Not enough args provided.\n", .{});
            },
            ArgsError.UnrecognizedArg => {
                try printUsage(stdout);
                try stdout.flush();
                const unrecognized = diagnostic.unrecognized.?;
                die("Unrecognized argument \"{s}\".\n", .{unrecognized});
            },
            Allocator.Error.OutOfMemory => {
                die("Hit memory limit trying to process CLI args.\n", .{});
            },
            else => return err,
        }
    };

    switch (action) {
        .parse => {
            logger.debug("Starting with options: {any}", .{options});
            const s = slurp(alloc, options.filepath) catch |err| {
                switch (err) {
                    error.FileNotFound => {
                        const filepath = options.filepath.?;
                        die("File does not exist: \"{s}\"\n", .{filepath});
                    },
                    else => return err,
                }
            };

            const result = atrus.parse(s);
            try stdout.print("{s}\n", .{result});
        },
        .print_version => {
            try printVersion(stdout);
        },
        .help => {
            try printUsage(stdout);
        },
    }

    try stdout.flush();
}

fn printUsage(out: *Io.Writer) !void {
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

fn printVersion(out: *Io.Writer) !void {
    try out.print("{s}\n", .{atrus.version});
}

pub fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

const Action = enum {
    parse,
    print_version,
    help,
};

const ArgsError = error {
    NotEnoughArgs,
    UnrecognizedArg,
};

const Diagnostic = struct {
    unrecognized: ?[]u8 = null,
};

fn parseArgs(
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

fn slurp(alloc: Allocator, filepath: ?[]u8) ![]u8 {
    if (filepath) |fp| {
        var file = try std.fs.cwd().openFile(fp, .{});
        defer file.close();

        const bytes = try file.readToEndAlloc(alloc, 1_000_000);
        return bytes;
    } else {
        return error.NotImplemented;
    }
}

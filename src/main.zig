const std = @import("std");
const atrus = @import("atrus");

const cli = @import("cli.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArgsError = cli.ArgsError;
 
const logger = std.log.scoped(.main);

pub fn main() !void {
    var buffer: [8192]u8 = undefined;
    var fixed_alloc_impl = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fixed_alloc_impl.allocator();
    defer fixed_alloc_impl.reset();

    var stdout_buffer: [64]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var options = cli.InvocationOptions{};
    var diagnostic = cli.Diagnostic{};
    const action = cli.parseArgs(alloc, &options, &diagnostic) catch |err| {
        switch (err) {
            ArgsError.NotEnoughArgs => {
                try cli.printUsage(stdout);
                try stdout.flush();
                die("Not enough args provided.\n", .{});
            },
            ArgsError.UnrecognizedArg => {
                try cli.printUsage(stdout);
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
                        die("File did not exist: \"{s}\"", .{options.filepath.?});
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
            try cli.printUsage(stdout);
        },
    }

    try stdout.flush();
}

pub fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

fn printVersion(out: *Io.Writer) !void {
    try out.print("{s}\n", .{atrus.version});
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

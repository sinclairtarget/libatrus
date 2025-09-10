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

    // Parse CLI args
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

    // Dispatch
    switch (action) {
        .print_version => {
            try printVersion(stdout);
        },
        .help => {
            try cli.printUsage(stdout);
        },
        .parse => {
            const description = try options.format(alloc);
            logger.debug("Parsing with options: {s}", .{description});

            const s = slurp(alloc, options.filepath) catch |err| {
                switch (err) {
                    error.FileNotFound => {
                        const p = options.filepath.?;
                        die("File did not exist: \"{s}\"\n", .{p});
                    },
                    else => return err,
                }
            };

            const ast = atrus.parse(s);

            logger.debug("Rendering...", .{});
            switch (options.output_choice) {
                .json => {
                    try stdout.print("{s}", .{ast});
                },
                .yaml => {
                    const result = atrus.renderYAML(ast);
                    try stdout.print("{s}", .{result});
                },
                .html => {
                    const result = atrus.renderHTML(ast);
                    try stdout.print("{s}", .{result});
                },
            }
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
    var buffer: [128]u8 = undefined;

    if (filepath) |fp| {
        var file = try std.fs.cwd().openFile(fp, .{});
        defer file.close();

        var reader_impl = file.reader(&buffer);
        const reader = &reader_impl.interface;
        const bytes = try reader.allocRemaining(alloc, .unlimited);
        return bytes;
    } else {
        var reader_impl = std.fs.File.stdin().reader(&buffer);
        const reader = &reader_impl.interface;
        const bytes = try reader.allocRemaining(alloc, .unlimited);
        return bytes;
    }
}

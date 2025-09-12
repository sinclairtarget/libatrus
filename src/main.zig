const std = @import("std");
const builtin = @import("builtin");

const atrus = @import("atrus");
const cli = @import("cli.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArgsError = cli.ArgsError;
 
const logger = std.log.scoped(.main);

pub fn main() !void {
    var stdout_buffer: [64]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        _ = debug_allocator.deinit();
    }
    const gpa = debug_allocator.allocator();

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // Parse CLI args
    const action, const options = blk: {
        var diagnostic = cli.Diagnostic{};
        break :blk cli.parseArgs(arena, &diagnostic) catch |err| {
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
                else => return err,
            }
        };
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
            const description = try options.format(arena);
            logger.debug("Parsing with options: {s}", .{description});

            const s = slurp(arena, options.filepath) catch |err| {
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
        .tokenize => {
            std.debug.assert(builtin.mode == .Debug);

            const description = try options.format(arena);
            logger.debug("Tokenizing with options: {s}", .{description});

            const s = slurp(arena, options.filepath) catch |err| {
                switch (err) {
                    error.FileNotFound => {
                        const p = options.filepath.?;
                        die("File did not exist: \"{s}\"\n", .{p});
                    },
                    else => return err,
                }
            };

            const tokens = atrus.tokenize(arena, s);
            for (tokens) |token| {
                try stdout.print("{s}\n", .{token});
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

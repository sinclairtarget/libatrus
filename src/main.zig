const std = @import("std");
const builtin = @import("builtin");

const atrus = @import("atrus");
const cli = @import("cli.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArgsError = cli.ArgsError;

const logger = std.log.scoped(.main);

const max_line_len = 1024; // bytes

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
                    try stdout.print("\n", .{});
                    try stdout.flush();
                    die("not enough args provided\n", .{});
                },
                ArgsError.UnrecognizedArg => {
                    try cli.printUsage(stdout);
                    try stdout.print("\n", .{});
                    try stdout.flush();
                    const unrecognized = diagnostic.argname.?;
                    die("unrecognized argument \"{s}\"\n", .{unrecognized});
                },
                ArgsError.MissingRequiredArg => {
                    try cli.printUsage(stdout);
                    try stdout.print("\n", .{});
                    try stdout.flush();
                    const required = diagnostic.argname.?;
                    die("missing required argument: <{s}>\n", .{required});
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

            const myst = slurp(arena, options.filepath) catch |err| {
                switch (err) {
                    error.FileNotFound => {
                        const path = options.filepath.?;
                        die("file did not exist: \"{s}\"\n", .{path});
                    },
                    else => return err,
                }
            };
            const ast = try atrus.parse(arena, myst);

            logger.debug("Rendering...", .{});
            switch (options.output_choice) {
                .json => {
                    const s = try atrus.renderJSON(arena, ast, .{});
                    try stdout.print("{s}\n", .{s});
                },
                .yaml => {
                    return error.NotImplemented;
                },
                .html => {
                    return error.NotImplemented;
                },
            }
        },
        .tokenize => {
            if (builtin.mode == .Debug) {
                const description = try options.format(arena);
                logger.debug("Tokenizing with options: {s}", .{description});

                var file = if (options.filepath) |filepath|
                    try std.fs.cwd().openFile(filepath, .{})
                else
                    std.fs.File.stdin();
                defer file.close();

                var buffer: [max_line_len]u8 = undefined;
                var reader_impl = file.reader(&buffer);
                const reader = &reader_impl.interface;

                const tokens = try atrus.tokenize(arena, reader);
                for (tokens) |token| {
                    const t = try token.format(arena);
                    try stdout.print("{s}\n", .{t});
                }
            } else {
                std.debug.assert(builtin.mode == .Debug);
            }
        },
    }

    try stdout.flush();
}

fn slurp(alloc: Allocator, filepath: ?[]const u8) ![]const u8 {
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

pub fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("Error: " ++ fmt, args);
    std.process.exit(1);
}

fn printVersion(out: *Io.Writer) !void {
    try out.print("{s}\n", .{atrus.version});
}

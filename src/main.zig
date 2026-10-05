//! An executable for testing libatrus at the command line.
//!
//! Not intended for general use.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArgsError = cli.ArgsError;

const atrus = @import("atrus");
const cli = @import("cli.zig");

const logger = std.log.scoped(.main);

const max_line_len = 1024; // bytes

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        // Adjust these to see more log messages from libatrus.
        // Note that unless the `log-scopes` build option is set, all log
        // messages have the `.libatrus` scope.
        .{ .scope = .libatrus, .level = .info },
        .{ .scope = .root, .level = .warn },
        .{ .scope = .directives, .level = .warn },
        .{ .scope = .container, .level = .warn },
        .{ .scope = .character_refs, .level = .warn },
    },
};

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{
        .verbose_log = false,
    }) = .init;
    defer {
        if (builtin.mode == .Debug) {
            _ = debug_allocator.detectLeaks();
        }
        _ = debug_allocator.deinit();
    }
    const gpa = debug_allocator.allocator();

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var stdout_buffer: [64]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Parse CLI args
    const action, const options = blk: {
        var diagnostic = cli.Diagnostic{};
        break :blk cli.parseArgs(
            init.args,
            gpa,
            arena,
            &diagnostic,
        ) catch |err| {
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
                ArgsError.IncompatibleArgs => {
                    try cli.printUsage(stdout);
                    try stdout.print("\n", .{});
                    try stdout.flush();
                    die("incompatible arguments\n", .{});
                },
                else => return err,
            }
        };
    };

    dispatch: switch (action) {
        .print_version => {
            try printVersion(stdout);
        },
        .help => {
            try cli.printUsage(stdout);
        },
        .parse => {
            logger.info("Parsing with options: {f}", .{options});

            const myst = slurp(
                io,
                arena,
                options.filepath_or_input,
            ) catch |err| {
                switch (err) {
                    error.FileNotFound => {
                        const path = options.filepath_or_input.?;
                        die("file did not exist: \"{s}\"\n", .{path});
                    },
                    else => return err,
                }
            };

            var reader = Io.Reader.fixed(myst);
            const ast = try atrus.parse(
                gpa,
                &reader,
                .{ .parse_level = switch (options.parse_level) {
                    .block => .block,
                    .raw => .raw,
                    .pre => .pre,
                    .post => .post,
                } },
            );
            defer ast.deinit(gpa);

            logger.info("Rendering...", .{});
            switch (options.output_choice) {
                .json => {
                    try atrus.render.toJSON(
                        ast,
                        stdout,
                        .{ .whitespace = .indent_2 },
                    );
                },
                .html => {
                    try atrus.render.toHTML(
                        ast,
                        stdout,
                        .{ .whitespace = .indent_2 },
                    );
                },
                .typst => try atrus.render.toTypst(ast, stdout, .{}),
            }
            try stdout.print("\n", .{});
            try stdout.flush();
            logger.info("Done.", .{});
        },
        .tokenize => {
            if (builtin.mode == .Debug) {
                if (options.filepath_or_input == null) {
                    var buffer: [max_line_len]u8 = undefined;
                    var reader_impl = Io.File.stdin().reader(io, &buffer);
                    try blockTokenize(arena, stdout, &reader_impl.interface);
                    break :dispatch;
                }

                const filepath_or_input = options.filepath_or_input.?;
                const cwd = Io.Dir.cwd();
                var file = cwd.openFile(
                    io,
                    filepath_or_input,
                    .{},
                ) catch |err| {
                    switch (err) {
                        error.FileNotFound => {
                            try inlineTokenize(
                                arena,
                                stdout,
                                filepath_or_input,
                            );
                            break :dispatch;
                        },
                        else => return err,
                    }
                };
                defer file.close(io);

                var buffer: [max_line_len]u8 = undefined;
                var reader_impl = file.reader(io, &buffer);
                try blockTokenize(arena, stdout, &reader_impl.interface);
            } else {
                // Runtime error if we get here somehow in non-debug build
                std.debug.assert(builtin.mode == .Debug);
            }
        },
    }

    try stdout.flush();
}

/// Reads a file into memory (or all of stdin if no filepath is given).
fn slurp(io: Io, alloc: Allocator, filepath: ?[]const u8) ![]const u8 {
    var buffer: [128]u8 = undefined;

    if (filepath) |fp| {
        var file = try Io.Dir.cwd().openFile(io, fp, .{});
        defer file.close(io);

        var reader_impl = file.reader(io, &buffer);
        const reader = &reader_impl.interface;
        const bytes = try reader.allocRemaining(alloc, .unlimited);
        return bytes;
    } else {
        var reader_impl = Io.File.stdin().reader(io, &buffer);
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

fn blockTokenize(arena: Allocator, out: *Io.Writer, reader: *Io.Reader) !void {
    var line_buf: [max_line_len]u8 = undefined;
    const line_reader: atrus.lex.LineReader = .{
        .in = reader,
        .buf = &line_buf,
    };

    var tokenizer = atrus.lex.BlockTokenizer.init(line_reader);
    while (try tokenizer.next(arena)) |token| {
        if (token.token_type == .newline) {
            try out.print("{f}\n", .{token});
        } else {
            try out.print("{f} ⋅ ", .{token});
        }
        try out.flush();
    }
}

fn inlineTokenize(arena: Allocator, out: *Io.Writer, in: []const u8) !void {
    var tokenizer = atrus.lex.InlineTokenizer.init(in);

    if (try tokenizer.next(arena)) |first| {
        try out.print("{f}", .{first});
    }

    while (try tokenizer.next(arena)) |token| {
        try out.print(" ⋅ {f}", .{token});
    }

    try out.print("\n", .{});
    try out.flush();
}

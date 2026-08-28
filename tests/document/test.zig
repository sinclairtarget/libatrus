const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const atrus = @import("atrus");

pub const TestCase = struct {
    mystmd_path: []const u8,
    json_path: []const u8,
    html_path: []const u8,
    typst_path: ?[]const u8 = null,
    skip: bool = false,

    pub fn name(self: TestCase) []const u8 {
        return self.mystmd_path;
    }

    pub fn run(self: TestCase, alloc: Allocator, rootdir: []const u8) !void {
        const mystmd = try slurpFile(alloc, rootdir, self.mystmd_path);

        var reader = Io.Reader.fixed(mystmd);
        const ast = try atrus.parse(
            alloc,
            &reader,
            .{ .parse_level = .post },
        );

        // Check JSON
        var outbuf = Io.Writer.Allocating.init(alloc);
        try atrus.renderJSON(
            ast,
            &outbuf.writer,
            .{ .whitespace = .indent_2 },
        );
        _ = try outbuf.writer.writeAll("\n");

        const expected_json = try slurpFile(alloc, rootdir, self.json_path);
        expectEqualStrings(expected_json, outbuf.written()) catch {
            return error.JSONNotEqual;
        };

        outbuf.clearRetainingCapacity();

        // Check HTML
        try atrus.renderHTML(
            ast,
            &outbuf.writer,
            .{ .whitespace = .indent_2 },
        );
        const expected_html = try slurpFile(alloc, rootdir, self.html_path);
        expectEqualStrings(expected_html, outbuf.written()) catch {
            return error.HTMLNotEqual;
        };

        outbuf.clearRetainingCapacity();
    }
};

fn slurpFile(
    alloc: Allocator,
    rootdir: []const u8,
    path: []const u8,
) ![]const u8 {
    const adjusted_path = try std.fs.path.join(alloc, &.{ rootdir, path });

    var buffer: [128]u8 = undefined;

    var file = std.fs.cwd().openFile(adjusted_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.debug.print("Missing file: \"{s}\"\n", .{adjusted_path});
                return err;
            },
            else => return err,
        }
    };
    defer file.close();

    var reader_impl = file.reader(&buffer);
    const reader = &reader_impl.interface;
    const bytes = try reader.allocRemaining(alloc, .unlimited);
    return bytes;
}

fn expectEqualStrings(expected: []const u8, actual: []const u8) !void {
    if (std.mem.indexOfDiff(u8, actual, expected)) |diff_index| {
        var diff_line_number: usize = 1;
        for (expected[0..diff_index]) |value| {
            if (value == '\n') diff_line_number += 1;
        }

        std.debug.print(
            "First difference occurs on line {d}:\n",
            .{diff_line_number},
        );
        std.debug.print("expected:\n", .{});
        printIndicatorLine(expected, diff_index);
        std.debug.print("actual:\n", .{});
        printIndicatorLine(actual, diff_index);

        return error.StringsNotEqual;
    }
}

fn printIndicatorLine(source: []const u8, indicator_index: usize) void {
    const line_begin_index = if (std.mem.lastIndexOfScalar(
        u8,
        source[0..indicator_index],
        '\n',
    )) |line_begin|
        line_begin + 1
    else
        0;
    const line_end_index = if (std.mem.indexOfScalar(
        u8,
        source[indicator_index..],
        '\n',
    )) |line_end|
        (indicator_index + line_end)
    else
        source.len;

    printLine(source[line_begin_index..line_end_index]);
    for (line_begin_index..indicator_index) |_|
        std.debug.print(" ", .{});

    if (indicator_index >= source.len)
        std.debug.print("^ (end of string)\n", .{})
    else
        std.debug.print("^ ('\\x{x:0>2}')\n", .{source[indicator_index]});
}

fn printLine(line: []const u8) void {
    if (line.len != 0) switch (line[line.len - 1]) {
        ' ', '\t' => return std.debug.print("{s}⏎\n", .{line}), // Return symbol
        else => {},
    };
    std.debug.print("{s}\n", .{line});
}

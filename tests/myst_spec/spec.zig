const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const atrus = @import("atrus");

pub const TestCase = struct {
    title: []const u8,
    myst: []const u8,
    mdast: json.Value,
    html: ?[]const u8 = null,
};

pub fn readTestCases(alloc: Allocator, path: []const u8) ![]const TestCase {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buffer: [64]u8 = undefined;
    var reader_impl = file.reader(&buffer);
    const reader = &reader_impl.interface;

    var json_reader = json.Reader.init(alloc, reader);
    defer json_reader.deinit();

    const parsed = try json.parseFromTokenSourceLeaky(
        []const TestCase,
        alloc,
        &json_reader,
        .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        },
    );
    return parsed;
}

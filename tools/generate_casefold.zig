//! This program reads the Unicode case fold mapping file (in the .txt form
//! made available by the Unicode Consortium) and writes out a ZON file with
//! only those mappings needed for the full case fold.
//!
//! The Unicode case fold mapping file for Unicode version 17.0 can be
//! retrieved from <https://www.unicode.org/Public/17.0.0/ucd/CaseFolding.txt>.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const fs = std.fs;
const Io = std.Io;
const zon = std.zon;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    const input_path = args[1];
    const output_path = args[2];

    const cwd = fs.cwd();

    var in_file = try cwd.openFile(input_path, .{});
    defer in_file.close();

    var in_buf: [128]u8 = undefined;
    var in_reader = in_file.reader(&in_buf);

    var out_file = try cwd.createFile(output_path, .{ .truncate = true });
    defer out_file.close();

    var out_buf: [128]u8 = undefined;
    var out_writer = out_file.writer(&out_buf);

    processCaseFoldMappings(
        alloc,
        &in_reader.interface,
        &out_writer.interface,
    ) catch |err| {
        switch (err) {
            else => return err,
        }
    };
}

// The output ZON file is a list of these.
const CaseFoldMapping = struct {
    codepoint: u21,
    mapped_codepoints: []const u21,

    fn lessThan(context: void, a: CaseFoldMapping, b: CaseFoldMapping) bool {
        _ = context;
        return a.codepoint < b.codepoint;
    }
};

fn processCaseFoldMappings(
    alloc: Allocator,
    reader: *Io.Reader,
    writer: *Io.Writer,
) !void {
    var mappings_list: ArrayList(CaseFoldMapping) = .empty;

    var line: [256]u8 = undefined;
    while (reader.peekByte()) |_| {
        var line_i: usize = 0;
        var seen_anything = false;

        // fill line
        while (reader.peekByte()) |c| {
            if (c == '\n' or c == '#') {
                break;
            }

            _ = try reader.takeByte();

            if (seen_anything or c != ' ') {
                seen_anything = true;
                line[line_i] = c;
                line_i += 1;
            }
        } else |err| {
            switch (err) {
                error.EndOfStream => break,
                else => return err,
            }
        }

        // skip rest of line
        while (reader.takeByte()) |c| {
            if (c == '\n') {
                break;
            }
        } else |err| {
            switch (err) {
                error.EndOfStream => {},
                else => return err,
            }
        }

        const filled_line = line[0..line_i];

        // split line
        if (filled_line.len > 0) {
            var it = std.mem.splitScalar(u8, filled_line, ';');
            const codepoint = blk: {
                const untrimmed = it.next() orelse continue;
                break :blk std.mem.trim(u8, untrimmed, " ");
            };
            const status = blk: {
                const untrimmed = it.next() orelse continue;
                break :blk std.mem.trim(u8, untrimmed, " ");
            };
            const mapped = blk: {
                const untrimmed = it.next() orelse continue;
                break :blk std.mem.trim(u8, untrimmed, " ");
            };

            if (std.mem.eql(u8, status, "C") or std.mem.eql(u8, status, "F")) {
                try mappings_list.append(
                    alloc,
                    try createMapping(alloc, codepoint, mapped),
                );
            }
        }
    } else |err| {
        switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
    }

    const mappings = try mappings_list.toOwnedSlice(alloc);
    std.mem.sort(CaseFoldMapping, mappings, {}, CaseFoldMapping.lessThan);

    try zon.stringify.serialize(mappings, .{}, writer);
    try writer.flush();
}

fn createMapping(
    alloc: Allocator,
    codepoint: []const u8,
    mapped_codepoints: []const u8,
) !CaseFoldMapping {
    var parsed_mapped: []u21 = try alloc.alloc(u21, 3);
    var num_mapped: u8 = 0;

    var it = std.mem.splitScalar(u8, mapped_codepoints, ' ');
    while (it.next()) |s| {
        const parsed = try std.fmt.parseInt(u21, s, 16);
        parsed_mapped[num_mapped] = parsed;
        num_mapped += 1;
    }

    return .{
        .codepoint = try std.fmt.parseInt(u21, codepoint, 16),
        .mapped_codepoints = parsed_mapped[0..num_mapped],
    };
}

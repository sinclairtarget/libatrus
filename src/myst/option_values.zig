//! Implements options value parsing for directives.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// Parses one or more integer ranges separated by commas.
///
/// E.g. 1-4, 9, 20-40
///
/// A range can be either a single integer or two integers separated by a
/// hyphen. If a range cannot be parsed (because it contains an invalid
/// character or is missing one end of the range) then it is skipped.
///
/// Returns a slice of all the integers covered by the ranges.
pub fn parseCommaSeparatedRanges(alloc: Allocator, s: []const u8) !?[]u16 {
    var ints: ArrayList(u16) = .empty; // unsorted, may contain duplicates

    var buf: [6]u8 = undefined;
    var int_len: usize = 0;
    const state: enum { start, num_open, num_close, reset } = .start;
    var s_i: usize = 0;
    var open_n: u16 = 0;
    fsm: switch (state) {
        .start => { // skip whitespace or commas until we get to a number
            if (s_i >= s.len) {
                break :fsm;
            }

            const char = s[s_i];
            switch (char) {
                '0'...'9' => continue :fsm .num_open,
                ' ', ',' => {
                    s_i += 1;
                    continue :fsm .start;
                },
                else => continue :fsm .reset,
            }
        },
        .num_open => { // read a single number, possibly opening a range
            if (s_i >= s.len) {
                if (int_len > 0) {
                    const n = std.fmt.parseInt(
                        u16,
                        buf[0..int_len],
                        10,
                    ) catch std.math.maxInt(u16);
                    try ints.append(alloc, n);
                    int_len = 0;
                }
                break :fsm;
            }

            const char = s[s_i];
            switch (char) {
                '0'...'9' => {
                    if (int_len >= buf.len) {
                        const n = std.math.maxInt(u16);
                        try ints.append(alloc, n);
                        int_len = 0;
                        continue :fsm .reset;
                    }

                    buf[int_len] = char;
                    int_len += 1;
                    s_i += 1;
                    continue :fsm .num_open;
                },
                ',' => {
                    const n = std.fmt.parseInt(
                        u16,
                        buf[0..int_len],
                        10,
                    ) catch std.math.maxInt(u16);
                    try ints.append(alloc, n);
                    int_len = 0;
                    s_i += 1;
                    continue :fsm .start;
                },
                '-' => {
                    open_n = std.fmt.parseInt(
                        u16,
                        buf[0..int_len],
                        10,
                    ) catch std.math.maxInt(u16);
                    int_len = 0;
                    s_i += 1;
                    continue :fsm .num_close;
                },
                else => continue :fsm .reset,
            }
        },
        .num_close => { // read single number, ending range
            if (s_i >= s.len) {
                if (int_len > 0) {
                    const close_n = std.fmt.parseInt(
                        u16,
                        buf[0..int_len],
                        10,
                    ) catch std.math.maxInt(u16);
                    for (open_n..close_n + 1) |n| {
                        try ints.append(alloc, @intCast(n));
                    }
                }
                break :fsm;
            }

            const char = s[s_i];
            switch (char) {
                '0'...'9' => {
                    if (int_len >= buf.len) {
                        const close_n = std.math.maxInt(u16);
                        for (open_n..close_n + 1) |n| {
                            try ints.append(alloc, @intCast(n));
                        }
                        int_len = 0;
                        continue :fsm .reset;
                    }

                    buf[int_len] = char;
                    int_len += 1;
                    s_i += 1;
                    continue :fsm .num_close;
                },
                ',' => {
                    if (int_len > 0) {
                        const close_n = std.fmt.parseInt(
                            u16,
                            buf[0..int_len],
                            10,
                        ) catch std.math.maxInt(u16);
                        for (open_n..close_n + 1) |n| {
                            try ints.append(alloc, @intCast(n));
                        }
                    }
                    int_len = 0;
                    s_i += 1;
                    continue :fsm .start;
                },
                else => continue :fsm .reset,
            }
        },
        .reset => { // just keep reading until next comma
            int_len = 0;
            if (s_i >= s.len) {
                break :fsm;
            }

            const char = s[s_i];
            switch (char) {
                ',' => {
                    s_i += 1;
                    continue :fsm .start;
                },
                else => {
                    s_i += 1;
                    continue :fsm .reset;
                },
            }
        },
    }

    const int_slice = try ints.toOwnedSlice(alloc);
    defer alloc.free(int_slice);
    std.mem.sort(u16, int_slice, {}, comptime std.sort.asc(u16));

    var deduped: ArrayList(u16) = .empty;
    for (int_slice, 0..) |num, i| {
        if (i == 0 or num != int_slice[i - 1]) {
            try deduped.append(alloc, num);
        }
    }

    return try deduped.toOwnedSlice(alloc);
}

//-----------------------------------------------------------------------------
// Unit Tests
//-----------------------------------------------------------------------------
const testing = std.testing;
const util = @import("../util/util.zig");

fn testParseCommaSeparatedRanges(s: []const u8, expected: []const u16) !void {
    const maybe_answer = try parseCommaSeparatedRanges(testing.allocator, s);
    const answer = try util.testing.expectNonNull(maybe_answer);
    defer testing.allocator.free(answer);

    try testing.expectEqualSlices(u16, expected, answer);
}

test "parse single int" {
    try testParseCommaSeparatedRanges("427", &.{ 427 });
}

test "parse single int with trailing comma" {
    try testParseCommaSeparatedRanges("4,", &.{ 4 });
}

test "parse comma-separated ints with duplicate" {
    try testParseCommaSeparatedRanges("1, 4, 5, 2, 4", &.{ 1, 2, 4, 5 });
}

test "parse range" {
    try testParseCommaSeparatedRanges("4-7", &.{ 4, 5, 6, 7 });
}

test "parse comma-separated ranges with overlaps" {
    try testParseCommaSeparatedRanges(
        "2-8, 4-10, 3, 9",
        &.{ 2, 3, 4, 5, 6, 7, 8, 9, 10 },
    );
}

test "parse overflow" {
    try testParseCommaSeparatedRanges("65535", &.{ 65535 });

    // saturate at max
    try testParseCommaSeparatedRanges("65536", &.{ 65535 });
    try testParseCommaSeparatedRanges("6553714124", &.{ 65535 });
}

test "parse failures" {
    try testParseCommaSeparatedRanges("%^&$!gh", &.{});
    try testParseCommaSeparatedRanges("-4, 5", &.{ 5 });
    try testParseCommaSeparatedRanges("3-, 5,,,", &.{ 5 });
    try testParseCommaSeparatedRanges("3-4-7, 5,,,", &.{ 5 });
}

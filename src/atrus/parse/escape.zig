//! Handles removing backslash escapes from text.
//!
//! We do this during parsing rather than during tokenization because in some
//! contexts (e.g. inline code) the backslashes shouldn't be removed. So we
//! can't remove the backslashes during tokenization because we don't yet know
//! how the token will get parsed.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Returns a copy of the given string with backslash characters that are
/// triggering backslash-escaping removed.
///
/// This function just cleans up the backslash characters that we no longer
/// need. The actual semantic backslash-escaping is done elsewhere. This
/// function should only be called on text where the backslash-escapes were
/// respected.
///
/// This function only removes backslashes before ASCII punctuation characters
/// since only ASCII punctuation characters can be escaped. This function
/// removes all such backslashes since we assume all valid backslash-escapes in
/// the input string were respected.
///
/// https://spec.commonmark.org/0.30/#backslash-escapes
pub fn strip(alloc: Allocator, s: []const u8) ![]const u8 {
    const copy = try alloc.alloc(u8, s.len);

    const State = enum { normal, escape };
    var source_index: usize = 0;
    var dest_index: usize = 0;
    fsm: switch (State.normal) {
        .normal => {
            if (source_index >= s.len) {
                break :fsm;
            }

            switch (s[source_index]) {
                '\\' => {
                    source_index += 1;
                    continue :fsm .escape;
                },
                else => {
                    copy[dest_index] = s[source_index];
                    source_index += 1;
                    dest_index += 1;
                    continue :fsm .normal;
                },
            }
        },
        .escape => {
            if (source_index >= s.len) {
                // Backslash was last character, keep it
                copy[dest_index] = '\\';
                dest_index += 1;
                break :fsm;
            }

            switch (s[source_index]) {
                // literal backslash
                '\\' => {
                    copy[dest_index] = s[source_index];
                    source_index += 1;
                    dest_index += 1;
                },
                // ascii punctuation can be escaped
                '!'...'/', ':'...'@', '[', ']'...'`', '{'...'~' => {},
                // everything else is considered just a backslash
                else => {
                    copy[dest_index] = '\\';
                    dest_index += 1;
                },
            }

            continue :fsm .normal;
        },
    }

    return try alloc.realloc(copy, dest_index);
}

/// Strips backslash escapes but only for a particular character.
///
/// Returns a newly allocated string owned by the caller.
pub fn stripOnly(
    alloc: Allocator,
    s: []const u8,
    comptime escaped: u8,
) ![]const u8 {
    const copy = try alloc.alloc(u8, s.len);

    const State = enum { normal, escape };
    var source_index: usize = 0;
    var dest_index: usize = 0;
    fsm: switch (State.normal) {
        .normal => {
            if (source_index >= s.len) {
                break :fsm;
            }

            switch (s[source_index]) {
                '\\' => {
                    source_index += 1;
                    continue :fsm .escape;
                },
                else => {
                    copy[dest_index] = s[source_index];
                    source_index += 1;
                    dest_index += 1;
                    continue :fsm .normal;
                },
            }
        },
        .escape => {
            if (source_index >= s.len) {
                // Backslash was last character, keep it
                copy[dest_index] = '\\';
                dest_index += 1;
                break :fsm;
            }

            if (escaped != '\\' and s[source_index] == '\\' ) {
                // Backslash escaping a backslash, keep both
                copy[dest_index] = '\\';
                dest_index += 1;
                copy[dest_index] = s[source_index];
                source_index += 1;
                dest_index += 1;
            } else if (s[source_index] != escaped) {
                // Not a character we should touch, keep the backslash
                copy[dest_index] = '\\';
                dest_index += 1;
            }

            continue :fsm .normal;
        },
    }

    return try alloc.realloc(copy, dest_index);
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

test "escape text" {
    const value = "/url\\bar\\*baz";
    const result = try strip(testing.allocator, value);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("/url\\bar*baz", result);
}

test "escape escaped backslash" {
    const value = "foo\\\\bar";
    const result = try strip(testing.allocator, value);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("foo\\bar", result);
}

test "terminating backslash not removed" {
    const value = "foo\\";
    const result = try strip(testing.allocator, value);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("foo\\", result);
}

test "escape only pipes" {
    const value = "\\*my\\* \\| foo";
    const result = try stripOnly(testing.allocator, value, '|');
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("\\*my\\* | foo", result);
}

// Ensures that if the backslash preceding the pipe is itself escaped, then we
// don't treat the backslash as escaping the pipe!
test "escape only pipes escaped backslash" {
    const value = "\\*my\\* \\\\| foo";
    const result = try stripOnly(testing.allocator, value, '|');
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("\\*my\\* \\\\| foo", result);
}

// Are we ever going to do this? Probably no. But for the sake of completeness
// let's make sure this works.
test "escape only backslashes" {
    const value = "\\*my\\* \\\\| foo";
    const result = try stripOnly(testing.allocator, value, '\\');
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("\\*my\\* \\| foo", result);
}

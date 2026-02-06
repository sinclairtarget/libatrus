//! Handles removing backslash escapes from text.
//!
//! We do this here rather than during tokenization because in some contexts
//! (e.g. inline code) the backslashes shouldn't be removed. So we can't remove
//! the backslashes during tokenization because we don't yet know how the token
//! will get parsed.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Returns a copy of the given string with backslash escapes removed.
///
/// https://spec.commonmark.org/0.30/#backslash-escapes
pub fn copyEscape(alloc: Allocator, s: []const u8) ![]const u8 {
    const copy = try alloc.alloc(u8, s.len);

    var state: enum { normal, escape } = .normal;
    var source_index: usize = 0;
    var dest_index: usize = 0;
    while (source_index < s.len) {
        switch (state) {
            .normal => {
                switch (s[source_index]) {
                    '\\' => {
                        source_index += 1;
                        state = .escape;
                    },
                    else => {
                        copy[dest_index] = s[source_index];
                        source_index += 1;
                        dest_index += 1;
                    },
                }
            },
            .escape => {
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
                state = .normal;
            },
        }
    }

    return try alloc.realloc(copy, dest_index);
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

test "escape text" {
    const value = "/url\\bar\\*baz";
    const result = try copyEscape(testing.allocator, value);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("/url\\bar*baz", result);
}

test "escape escaped backslash" {
    const value = "foo\\\\bar";
    const result = try copyEscape(testing.allocator, value);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("foo\\bar", result);
}

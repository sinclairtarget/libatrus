const std = @import("std");
const Allocator = std.mem.Allocator;

/// If s contains only the bytes in chars, returns true. False otherwise.
pub fn containsOnly(s: []const u8, chars: []const u8) bool {
    for (s) |byte| {
        for (chars) |c| {
            if (byte == c) {
                break;
            }
        } else return false;
    }

    return true;
}

/// Returns true if s contains an Ascii control char, otherwise false.
pub fn containsAsciiControl(s: []const u8) bool {
    for (s) |byte| {
        if (std.ascii.isControl(byte)) {
            return true;
        }
    }

    return false;
}

pub fn isPunctuation(s: []const u8) bool {
    // TODO: Handle unicode punctuation characters
    if (s.len > 1) {
        @panic("handling for unicode punctuation not yet implemented");
    }

    return switch (s[0]) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}

/// How long a whitespace token is for the purposes of indentation.
///
/// Counts tabs as four spaces.
pub fn whitespaceIndentLen(s: []const u8) usize {
    var len: usize = 0;
    for (s) |byte| {
        switch (byte) {
            ' '  => len += 1,
            '\t' => len += 4,
            else => unreachable,
        }
    }

    return len;
}

/// Removes whitespace from the start of the string, up to the given number of
/// spaces.
///
/// Tabs count as four spaces.
pub fn trimWhitespaceStart(s: []const u8, count: usize) []const u8 {
    var begin: usize = 0;
    var count_used: usize = 0;
    while (count_used < count and begin < s.len) : (begin += 1) {
        if (s[begin] == '\t') {
            count_used += 4;
        } else {
            count_used += 1;
        }
    }
    return s[begin..];
}

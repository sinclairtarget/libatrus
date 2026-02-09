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

const std = @import("std");

const util = @import("../util/util.zig");

/// Returns true if the given string is a valid HTML tag name according to the
/// CommonMark spec.
///
/// A tag name consists of an ASCII letter followed by zero or more ASCII
/// letters, digits, or hyphens.
pub fn isValidTagName(s: []const u8) bool {
    if (s.len == 0) {
        return false;
    }

    if (!std.ascii.isAlphabetic(s[0])) {
        return false;
    }

    for (1..s.len) |i| {
        if (!std.ascii.isAlphanumeric(s[i]) and s[i] != '-') {
            return false;
        }
    }

    return true;
}

/// Returns true if the given string is a valid HTML attribute name according
/// to the CommonMark spec.
///
/// The attribute name must consist of an ASCII letter, _, or :, followed by
/// zero or more ASCII letters, digits, _, ., :, or -.
pub fn isValidAttributeName(s: []const u8) bool {
    if (s.len == 0) {
        return false;
    }

    if (!std.ascii.isAlphabetic(s[0]) and
        !util.strings.containsScalar("_:", s[0]))
    {
        return false;
    }

    for (1..s.len) |i| {
        if (!std.ascii.isAlphanumeric(s[i]) and
            !util.strings.containsScalar("_:.-", s[i]))
        {
            return false;
        }
    }

    return true;
}

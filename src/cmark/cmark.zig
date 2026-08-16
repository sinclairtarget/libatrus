//! Logic specified by the CommonMark specification that doesn't fit neatly
//! into either lexing, parsing, or rendering.

const std = @import("std");
const fmt = std.fmt;

pub const character_refs = @import("character_refs.zig");
pub const html = @import("html.zig");
pub const uri = @import("uri.zig");

/// Sequence of 1 to 9 arabic digits. Can begin with 0s.
pub fn parseOrderedListNumber(s: []const u8) !u32 {
    if (s.len > 9) {
        return error.TooManyDigits;
    }

    for (s) |c| {
        if (!std.ascii.isDigit(c)) {
            return error.ContainedNonDigit;
        }
    }

    return try fmt.parseInt(u32, s, 10);
}

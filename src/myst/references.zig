const std = @import("std");
const Allocator = std.mem.Allocator;

const label_max_len_bytes = 999;

pub fn normalizeIdentifier(alloc: Allocator, s: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\n");

    // collapse interior whitespace
    var collapse_buf: [label_max_len_bytes]u8 = undefined;
    const collapsed = collapseInteriorWhitespace(trimmed, &collapse_buf);

    // TODO: Value must be normalized such that whitespace is collapsed to a
    // single space and case is folded
    return try std.ascii.allocLowerString(alloc, collapsed);
}

fn collapseInteriorWhitespace(s: []const u8, buf: []u8) []u8 {
    std.debug.assert(buf.len >= s.len);

    var buf_i: usize = 0;
    var skippping_whitespace = false;
    for (s) |c| {
        if (std.ascii.isWhitespace(c)) {
            if (skippping_whitespace) {
                continue;
            }

            buf[buf_i] = ' ';
            buf_i += 1;
            skippping_whitespace = true;
            continue;
        }

        buf[buf_i] = c;
        buf_i += 1;
        skippping_whitespace = false;
    }

    return buf[0..buf_i];
}

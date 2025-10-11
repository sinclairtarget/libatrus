pub fn containsOnly(s: []const u8, chars: []const u8) bool {
    for (s) |byte| {
        const wasAllowedChar = blk: {
            for (chars) |c| {
                if (byte == c) {
                    break :blk true;
                }
            }

            break :blk false;
        };

        if (!wasAllowedChar) {
            return false;
        }
    }

    return true;
}

// https://spec.commonmark.org/0.30/#blank-line
pub fn isBlankLine(s: []const u8) bool {
    return s.len == 0 or containsOnly(s, " \t");
}

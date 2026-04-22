pub fn isValidRoleName(name: []const u8) bool {
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
            else => {
                return false;
            },
        }
    }

    return true;
}

pub fn isValidDirectiveName(name: []const u8) bool {
    return isValidRoleName(name); // these happen to be the same right now
}

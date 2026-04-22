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

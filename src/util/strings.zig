pub fn containsOnly(s: []const u8, c: u8) bool {
    for (s) |byte| {
        if (byte != c) {
            return false;
        }
    }

    return true;
}

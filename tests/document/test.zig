pub const TestCase = struct {
    mystmd_path: []const u8,
    json_path: []const u8,
    html_path: []const u8,
    typst_path: ?[]const u8 = null,
    skip_reason: ?[]const u8 = null,

    pub fn name(self: TestCase) []const u8 {
        return self.mystmd_path;
    }
};

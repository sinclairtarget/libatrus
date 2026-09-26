pub const TestCase = struct {
    /// Name identifying the test.
    name: []const u8,
    mystmd: []const u8,
    json_pre: []const u8,
    json_post: ?[]const u8 = null,
    html: ?[]const u8 = null,
    typst: ?[]const u8 = null,
    /// Test will be skipped if a reason is given.
    skip_reason: ?[]const u8 = null,
};

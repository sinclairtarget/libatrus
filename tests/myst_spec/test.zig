const std = @import("std");
const json = std.json;

pub const TestCase = struct {
    title: []const u8,
    myst: []const u8,
    mdast: json.Value,
    html: ?[]const u8 = null,
    /// Rendered HTML should be indented this case
    html_indented: bool = false,
    /// Skip only the HTML comparison if non-null
    skip_html_reason: ?[]const u8 = null,
};

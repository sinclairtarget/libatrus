const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const TokenType = enum {
    text,
    pound, // one or more consecutive '#' symbols, word-bounded
    newline,
};

pub const Token = struct {
    token_type: TokenType,
    lexeme: ?[]const u8 = null,

    const Self = @This();

    pub fn format(self: Self, w: *Io.Writer) !void {
        var buf: [128]u8 = undefined;
        const name = std.ascii.upperString(&buf, @tagName(self.token_type));

        if (self.lexeme) |lexeme| {
            try w.print("{s} \"{s}\"", .{ name, lexeme });
        } else {
            try w.print("{s}", .{name});
        }
    }
};

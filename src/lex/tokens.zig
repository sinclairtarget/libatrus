const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const TokenType = enum {
    text,
    indent, // indent at beginning of line
    pound, // one or more consecutive '#' symbols, word-bounded
    newline,
    rule_star,
    rule_underline,
    rule_dash_with_whitespace,
    rule_dash,
    rule_equals,
};

pub const InlineTokenType = enum {
    decimal_character_reference,
    hexadecimal_character_reference,
    entity_reference,
};

pub const Token = MakeToken(TokenType);
pub const InlineToken = MakeToken(InlineTokenType);

fn MakeToken(comptime T: type) type {
    return struct {
        token_type: T,
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
}

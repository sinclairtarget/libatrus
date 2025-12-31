const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Tokens recognized by the block parser.
pub const BlockTokenType = enum {
    text,                      // indent at beginning of line
    indent,                    // one or more consecutive '#' symbols
    pound,
    newline,
    rule_star,
    rule_underline,
    rule_dash_with_whitespace,
    rule_dash,
    rule_equals,
};

/// Tokens recognized by the inline parser.
pub const InlineTokenType = enum {
    text,
    newline,
    decimal_character_reference,
    hexadecimal_character_reference,
    entity_reference,
    l_delim_star,
    r_delim_star,
    lr_delim_star,
    l_delim_underscore,
    r_delim_underscore,
    lr_delim_underscore,
    backtick,                           // one or more consecutive backticks
    l_square_bracket,
    r_square_bracket,
    l_angle_bracket,
    r_angle_bracket,
    l_paren,
    r_paren,
};

pub const BlockToken = Token(BlockTokenType);
pub const InlineToken = Token(InlineTokenType);

// Additional data needed for some tokens
pub const Extra = union {
    empty: void,
    delim_star: DelimStarExtra,
    delim_underscore: DelimUnderscoreExtra,
};

pub const DelimStarExtra = struct {
    run_len: u16,
};

pub const DelimUnderscoreExtra = struct {
    run_len: u16,
    preceded_by_punct: bool,
    followed_by_punct: bool,
};

fn Token(comptime TokenType: type) type {
    return struct {
        token_type: TokenType,
        lexeme: []const u8 = "",
        extra: Extra = .{ .empty = {} },

        const Self = @This();

        pub fn format(self: Self, w: *Io.Writer) !void {
            var buf: [128]u8 = undefined;
            const name = std.ascii.upperString(&buf, @tagName(self.token_type));

            if (self.lexeme.len > 0) {
                try w.print("{s} \"{s}\"", .{ name, self.lexeme });
            } else {
                try w.print("{s}", .{name});
            }
        }
    };
}

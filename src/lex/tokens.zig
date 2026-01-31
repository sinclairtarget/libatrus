const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Tokens recognized by the block parser.
pub const BlockTokenType = enum {
    text,
    indent,                     // indent at beginning of line
    pound,                      // one or more consecutive '#' symbols
    newline,
    rule_star,
    rule_underline,
    rule_dash_with_whitespace,
    rule_dash,
    rule_equals,
    colon,
    l_square_bracket,
    r_square_bracket,
    l_angle_bracket,
    r_angle_bracket,
    double_quote,
};

/// Tokens recognized by the inline parser.
pub const InlineTokenType = enum {
    text,
    newline,
    whitespace,                         // space or tab (NOT unicode whitespace)
    decimal_character_reference,
    hexadecimal_character_reference,
    entity_reference,
    absolute_uri,
    email,
    l_delim_star,
    r_delim_star,
    lr_delim_star,
    l_delim_underscore,
    r_delim_underscore,
    lr_delim_underscore,
    backtick,                           // one or more consecutive backticks
    single_quote,
    double_quote,
    l_square_bracket,
    r_square_bracket,
    l_angle_bracket,
    r_angle_bracket,
    l_paren,
    r_paren,
    exclamation_mark,
};

pub const BlockToken = Token(BlockTokenType);
pub const InlineToken = Token(InlineTokenType);

// Additional "context" data needed for some tokens
pub const Context = union {
    empty: void,
    delim_star: DelimStarContext,
    delim_underscore: DelimUnderscoreContext,

    pub const default: Context = .{ .empty = {} };
};

pub const DelimStarContext = struct {
    run_len: u16,
};

pub const DelimUnderscoreContext = struct {
    run_len: u16,
    preceded_by_punct: bool,
    followed_by_punct: bool,
};

fn Token(comptime TokenType: type) type {
    return struct {
        token_type: TokenType,
        lexeme: []const u8 = "",
        context: Context = .{ .empty = {} },

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

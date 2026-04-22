const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Tokens recognized by the block parsers.
pub const BlockTokenType = enum {
    text,
    pound,                  // one or more consecutive '#' symbols
    newline,
    whitespace,
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
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    single_quote,
    double_quote,
    backtick_fence,         // three or more consecutive '`' symbols
    tilde_fence,            // three or more consecutive '~' symbols
    colon_fence,            // three or more consecutive ':' symbols
    close,                  // special token inserted by container block parser
};

/// Tokens recognized by the inline parser.
pub const InlineTokenType = enum {
    // --- single-character tokens ---
    newline,
    single_quote,
    double_quote,
    l_square_bracket,
    r_square_bracket,
    l_angle_bracket,
    r_angle_bracket,
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    exclamation_mark,
    question_mark,               // used only for HTML parsing
    equals,                      // used only for HTML parsing
    slash,                       // used only for HTML parsing
    hyphen,                      // used only for HTML parsing
    // --- single-character delimiters ---
    // These get matched as a run of multiple characters but then emitted as
    // single-character tokens.
    l_delim_star,
    r_delim_star,
    lr_delim_star,
    l_delim_underscore,
    r_delim_underscore,
    lr_delim_underscore,
    // --- multi-character tokens ---
    backtick,                    // one or more consecutive backticks
    whitespace,                  // run of spaces/tabs (NOT unicode whitespace)
    text,
    decimal_character_reference,
    hexadecimal_character_reference,
    entity_reference,
    hard_break,                  // char sequence that could be parsed as break
    // --- escaped tokens ---
    // Escaping is sometimes not allowed. See InlineTokenizer.
    // We need escaped versions of only these tokens because where
    // backslash-escaping isn't allowed these are the only tokens whose meaning
    // is important. In those contexts, these tokens get treated as equivalent
    // to their non-escaped counterparts. Otherwise they should be treated as
    // equivalent to text.
    escaped_single_quote,
    escaped_double_quote,
    escaped_r_angle_bracket,
    escaped_backtick,
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

pub fn Token(comptime TokenType: type) type {
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

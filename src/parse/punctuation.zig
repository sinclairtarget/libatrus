const std = @import("std");

const InlineToken = @import("../lex/tokens.zig").InlineToken;
const strings = @import("../util/strings.zig");

pub fn startsWithPunctuation(token: InlineToken) bool {
    if (isPunctuationToken(token)) {
        return true;
    }

    if (token.lexeme.len == 0) {
        return false;
    }

    // TODO: Unicode character handling, can't assume all chars are one
    // single byte.
    const first_char = token.lexeme[0..1];
    return strings.isPunctuation(first_char);
}

pub fn endsWithPunctuation(token: InlineToken) bool {
    if (isPunctuationToken(token)) {
        return true;
    }

    if (token.lexeme.len == 0) {
        return false;
    }

    // TODO: Unicode character handling, can't assume all chars are one
    // single byte.
    const last_char = token.lexeme[token.lexeme.len - 1..token.lexeme.len];
    return strings.isPunctuation(last_char);
}

fn isPunctuationToken(token: InlineToken) bool {
    return switch (token.token_type) {
        .l_delim_star, .r_delim_star, .lr_delim_star, .l_delim_underscore,
        .r_delim_underscore, .lr_delim_underscore => true,
        .text, .newline, .decimal_character_reference,
        .hexadecimal_character_reference, .entity_reference => false,
    };
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

test "starts with" {
    try testing.expectEqual(
        false,
        startsWithPunctuation(.{
            .token_type = .text,
            .lexeme = "foo",
        }),
    );
    try testing.expectEqual(
        true,
        startsWithPunctuation(.{
            .token_type = .text,
            .lexeme = "(foo",
        }),
    );
    try testing.expectEqual(
        true,
        startsWithPunctuation(.{
            .token_type = .l_delim_star,
        }),
    );
}

test "ends with" {
    try testing.expectEqual(
        false,
        endsWithPunctuation(.{
            .token_type = .text,
            .lexeme = "foo",
        }),
    );
    try testing.expectEqual(
        true,
        endsWithPunctuation(.{
            .token_type = .text,
            .lexeme = "foo)",
        }),
    );
    try testing.expectEqual(
        true,
        endsWithPunctuation(.{
            .token_type = .r_delim_star,
        }),
    );
}

//! Tokenizer for inline MyST syntax.
//!
//! Some transitions through the finite state machine might generate multiple
//! tokens. We do this to attach context to some tokens that need context to be
//! correctly parsed (e.g. we need the delimiter run length for individual
//! delimiter tokens). Since the token stream is meant to be consumed one token
//! at a time, when we have multiple tokens we "stage" them in an array list
//! until they can be consumed.
//!
//! Note on backslash-escaping: A backslash will be respected by the tokenizer,
//! such that the next character will not have its usual meaning (and probably
//! lead to a different token being emitted). The backslash stays present in
//! the lexeme for the token though and needs to be stripped out later if the
//! backslash is not supposed to appear in the final output.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const InlineToken = @import("tokens.zig").InlineToken;
const InlineTokenType = @import("tokens.zig").InlineTokenType;
const Context = @import("tokens.zig").Context;
const strings = @import("../util/strings.zig");

pub const Error = error{
    WriteFailed,
} || Allocator.Error;

/// Overall state for the tokenizer.
const TopLevelState = enum {
    normal,
    punct,      // Last token ended in punctuation
    whitespace, // Last token ended in whitespace
};

const TokenizeResult = struct {
    tokens: []const InlineToken,
    next_i: usize,
    next_state: TopLevelState = .normal,
};

in: []const u8,
i: usize,
state: TopLevelState,
staged: ArrayList(InlineToken),

const Self = @This();

pub fn init(in: []const u8) Self {
    return .{
        .in = in,
        .i = 0,
        .state = .whitespace, // Beginning of line treated as whitespace
        .staged = .empty,
    };
}

/// Returns the next token in the stream, or null if the stream is exhausted.
///
/// Caller owns the returned token.
pub fn next(self: *Self, scratch: Allocator) Error!?InlineToken {
    if (self.staged.pop()) |token| {
        return token;
    }

    if (self.i >= self.in.len) {
        return null;
    }

    return try self.tokenize(scratch);
}

fn tokenize(self: *Self, scratch: Allocator) !InlineToken {
    std.debug.assert(self.i < self.in.len);

    var running_text = Io.Writer.Allocating.init(scratch);

    const result: ?TokenizeResult = while (self.i < self.in.len) {
        // First, try regular tokens
        const regular_result: ?TokenizeResult = blk: {
            if (try self.tokenizeSingleCharTokens(scratch)) |result| {
                break :blk result;
            }

            if (try self.tokenizeDecimalCharacterReference(scratch)) |result| {
                break :blk result;
            }

            if (try self.tokenizeHexCharacterReference(scratch)) |result| {
                break :blk result;
            }

            if (try self.tokenizeEntityReference(scratch)) |result| {
                break :blk result;
            }

            if (try self.tokenizeBackticks(scratch)) |result| {
                break :blk result;
            }

            if (try self.tokenizeDelimStarRun(scratch, self.state)) |result| {
                break :blk result;
            }

            if (try self.tokenizeDelimUnderRun(scratch, self.state)) |result| {
                break :blk result;
            }

            if (try self.tokenizeWhitespace(scratch)) |result| {
                break :blk result;
            }

            break :blk null;
        };

        if (regular_result) |r| {
            self.i = r.next_i;
            self.state = r.next_state;
            break r;
        }

        // Didn't successfully scan a regular token. Handle fallback
        const fallback_result = blk: {
            if (try self.tokenizeText(scratch)) |result| {
                break :blk result;
            }

            @panic("could not tokenize remaining inline content");
        };

        // To ensure we don't yield sibling text tokens, we write the lexeme
        // to a buffer to be concatenated with the next text token's lexeme
        // if there is one.
        std.debug.assert(fallback_result.tokens.len == 1);
        _ = try running_text.writer.write(
            fallback_result.tokens[0].lexeme,
        );

        self.i = fallback_result.next_i;
        self.state = fallback_result.next_state;
    } else null;

    if (result) |r| {
        std.debug.assert(r.tokens.len > 0);

        // Add tokens to staged in reverse order
        var i = r.tokens.len;
        while (i > 0) {
            try self.staged.append(scratch, r.tokens[i - 1]);
            i -= 1;
        }
    }

    // Add text token if one is pending
    if (running_text.written().len > 0) {
        const token = (try evaluateTokens(
            scratch,
            .text,
            .default,
            running_text.written(),
        ))[0];
        try self.staged.append(scratch, token);
    }

    return self.staged.pop().?;
}

fn tokenizeSingleCharTokens(self: Self, scratch: Allocator) !?TokenizeResult {
    const result: struct {
        InlineTokenType,
        TopLevelState,
    } = switch (self.in[self.i]) {
            '\n' => .{ .newline, .whitespace },
            '[' => .{ .l_square_bracket, .punct },
            ']' => .{ .r_square_bracket, .punct },
            '<' => .{ .l_angle_bracket, .punct },
            '>' => .{ .r_angle_bracket, .punct },
            '(' => .{ .l_paren, .punct },
            ')' => .{ .r_paren, .punct },
            else => return null,
    };

    const token_type, const next_state = result;
    const tokens = try evaluateTokens(
        scratch,
        token_type,
        .default,
        self.in[self.i..self.i + 1],
    );
    return .{
        .tokens = tokens,
        .next_i = self.i + 1,
        .next_state = next_state,
    };
}

fn tokenizeEntityReference(self: Self, scratch: Allocator) !?TokenizeResult {
    var lookahead_i = self.i;

    const State = enum { started, rest };
    fsm: switch (State.started) {
        .started => {
            switch (self.in[lookahead_i]) {
                '&' => {
                    lookahead_i += 1;
                    continue :fsm .rest;
                },
                else => return null,
            }
        },
        .rest => {
            if (lookahead_i >= self.in.len) {
                return null;
            }

            switch (self.in[lookahead_i]) {
                'a'...'z', 'A'...'Z', '0'...'9' => {
                    lookahead_i += 1;
                    continue :fsm .rest;
                },
                ';' => {
                    lookahead_i += 1;
                    break :fsm;
                },
                else => return null,
            }
        },
    }

    const tokens = try evaluateTokens(
        scratch,
        .entity_reference,
        .default,
        self.in[self.i..lookahead_i],
    );
    return .{
        .tokens = tokens,
        .next_i = lookahead_i,
    };
}

fn tokenizeDecimalCharacterReference(
    self: Self,
    scratch: Allocator,
) !?TokenizeResult {
    var lookahead_i = self.i;

    const State = enum { started, pound, rest };
    var num_digits: u8 = 0;
    fsm: switch (State.started) {
        .started => {
            switch (self.in[lookahead_i]) {
                '&' => {
                    lookahead_i += 1;
                    continue :fsm .pound;
                },
                else => return null,
            }
        },
        .pound => {
            if (lookahead_i >= self.in.len) {
                return null;
            }

            switch (self.in[lookahead_i]) {
                '#' => {
                    lookahead_i += 1;
                    continue :fsm .rest;
                },
                else => return null,
            }
        },
        .rest => {
            if (lookahead_i >= self.in.len) {
                return null;
            }

            switch (self.in[lookahead_i]) {
                '0'...'9' => {
                    lookahead_i += 1;
                    num_digits += 1;
                    continue :fsm .rest;
                },
                ';' => {
                    lookahead_i += 1;
                    break :fsm;
                },
                else => return null,
            }
        },
    }

    if (num_digits < 1 or num_digits > 7) {
        return null;
    }

    const tokens = try evaluateTokens(
        scratch,
        .decimal_character_reference,
        .default,
        self.in[self.i..lookahead_i],
    );
    return .{
        .tokens = tokens,
        .next_i = lookahead_i,
    };
}

fn tokenizeHexCharacterReference(
    self: Self,
    scratch: Allocator,
) !?TokenizeResult {
    var lookahead_i = self.i;

    const State = enum { started, pound, base, rest };
    var num_digits: u8 = 0;
    fsm: switch (State.started) {
        .started => {
            switch (self.in[lookahead_i]) {
                '&' => {
                    lookahead_i += 1;
                    continue :fsm .pound;
                },
                else => return null,
            }
        },
        .pound => {
            if (lookahead_i >= self.in.len) {
                return null;
            }

            switch (self.in[lookahead_i]) {
                '#' => {
                    lookahead_i += 1;
                    continue :fsm .base;
                },
                else => return null,
            }
        },
        .base => {
            if (lookahead_i >= self.in.len) {
                return null;
            }

            switch (self.in[lookahead_i]) {
                'x', 'X' => {
                    lookahead_i += 1;
                    continue :fsm .rest;
                },
                else => return null,
            }
        },
        .rest => {
            if (lookahead_i >= self.in.len) {
                return null;
            }

            switch (self.in[lookahead_i]) {
                '0'...'9', 'a'...'f', 'A'...'F' => {
                    lookahead_i += 1;
                    num_digits += 1;
                    continue :fsm .rest;
                },
                ';' => {
                    lookahead_i += 1;
                    break :fsm;
                },
                else => return null,
            }
        },
    }

    if (num_digits < 1 or num_digits > 6) {
        return null;
    }

    const tokens = try evaluateTokens(
        scratch,
        .hexadecimal_character_reference,
        .default,
        self.in[self.i..lookahead_i],
    );
    return .{
        .tokens = tokens,
        .next_i = lookahead_i,
    };
}

fn tokenizeBackticks(self: Self, scratch: Allocator) !?TokenizeResult {
    var lookahead_i = self.i;

    const State = enum { start, rest };
    fsm: switch (State.start) {
        .start => {
            switch (self.in[lookahead_i]) {
                '`' => {
                    lookahead_i += 1;
                    continue :fsm .rest;
                },
                else => return null,
            }
        },
        .rest => {
            if (lookahead_i >= self.in.len) {
                break :fsm;
            }

            switch (self.in[lookahead_i]) {
                '`' => {
                    lookahead_i += 1;
                    continue :fsm .rest;
                },
                else => break :fsm,
            }
        },
    }

    const range = self.in[self.i..lookahead_i];
    const tokens = try evaluateTokens(scratch, .backtick, .default, range);
    return .{
        .tokens = tokens,
        .next_i = lookahead_i,
        .next_state = .punct,
    };
}

fn tokenizeDelimStarRun(
    self: Self,
    scratch: Allocator,
    top_level_state: TopLevelState,
) !?TokenizeResult {
    var lookahead_i = self.i;

    const State = enum {
        start,
        l_delim_run,
        r_delim_run,
        r_delim_punct_run,
    };
    const token_type: InlineTokenType = fsm: switch (State.start) {
        .start => {
            switch (self.in[lookahead_i]) {
                '*' => {
                    lookahead_i += 1;
                    switch (top_level_state) {
                        .whitespace => continue :fsm .l_delim_run,
                        .normal => continue :fsm .r_delim_run,
                        .punct => continue :fsm .r_delim_punct_run,
                    }
                },
                else => return null,
            }
        },
        .l_delim_run => {
            if (lookahead_i >= self.in.len) {
                return null; // Can't precede end of line
            }

            switch (self.in[lookahead_i]) {
                '*' => {
                    lookahead_i += 1;
                    continue :fsm .l_delim_run;
                },
                ' ', '\t', '\n' => return null,
                else => break :fsm .l_delim_star,
            }
        },
        .r_delim_run => {
            if (lookahead_i >= self.in.len) {
                break :fsm .r_delim_star;
            }

            switch (self.in[lookahead_i]) {
                '*' => {
                    lookahead_i += 1;
                    continue :fsm .r_delim_run;
                },
                ' ', '\t', '\n', '_', '!'...'%', '\''...')', '+'...'/',
                ':'...'@', '[', ']', '^', '`', '}'...'~' => {
                    // Following punctuation (or whitespace) means this can't
                    // be left-delimiting
                    break :fsm .r_delim_star;
                },
                else => break :fsm .lr_delim_star,
            }
        },
        .r_delim_punct_run => {
            if (lookahead_i >= self.in.len) {
                break :fsm .r_delim_star;
            }

            switch (self.in[lookahead_i]) {
                '*' => {
                    lookahead_i += 1;
                    continue :fsm .r_delim_punct_run;
                },
                ' ', '\t', '\n' => break :fsm .r_delim_star,
                '_', '!'...'%', '\''...')', '+'...'/', ':'...'@', '[', ']', '^',
                '`', '}'...'~' => {
                    break :fsm .lr_delim_star;
                },
                else => {
                    // Since this run started after punctuation, if it is not
                    // followed by punctuation it cannot be right-delimiting
                    break :fsm .l_delim_star;
                }
            }
        },
    };

    const range = self.in[self.i..lookahead_i];
    const context = evaluateDelimStarContext(range);
    const tokens = try evaluateTokens(scratch, token_type, context, range);
    return .{
        .tokens = tokens,
        .next_i = lookahead_i,
        .next_state = .punct,
    };
}

fn tokenizeDelimUnderRun(
    self: Self,
    scratch: Allocator,
    top_level_state: TopLevelState,
) !?TokenizeResult {
    var lookahead_i = self.i;

    const State = enum {
        start,
        l_delim_run,
        r_delim_run,
        r_delim_punct_run,
    };
    const token_type: InlineTokenType, const context = fsm: switch (State.start) {
        .start => {
            switch (self.in[lookahead_i]) {
                '_' => {
                    lookahead_i += 1;
                    switch (top_level_state) {
                        .whitespace => continue :fsm .l_delim_run,
                        .normal => continue :fsm .r_delim_run,
                        .punct => continue :fsm .r_delim_punct_run,
                    }
                },
                else => return null,
            }
        },
        .l_delim_run => {
            if (lookahead_i >= self.in.len) {
                return null; // Can't precede end of line
            }

            switch (self.in[lookahead_i]) {
                '_' => {
                    lookahead_i += 1;
                    continue :fsm .l_delim_run;
                },
                ' ', '\t', '\n' => return null,
                else => |b| {
                    break :fsm .{
                        .l_delim_underscore,
                        evaluateDelimUnderscoreContext(
                            self.in[self.i..lookahead_i],
                            false,
                            strings.isPunctuation(&.{ b }),
                        ),
                    };
                },
            }
        },
        .r_delim_run => {
            if (lookahead_i >= self.in.len) {
                break :fsm .{
                    .r_delim_underscore,
                    evaluateDelimUnderscoreContext(
                        self.in[self.i..lookahead_i],
                        false,
                        false,
                    ),
                };
            }

            switch (self.in[lookahead_i]) {
                '_' => {
                    lookahead_i += 1;
                    continue :fsm .r_delim_run;
                },
                ' ', '\t', '\n', '*', '!'...'%', '\''...')', '+'...'/',
                ':'...'@', '[', ']', '^', '`', '}'...'~' => |b| {
                    // Following punctuation (or whitespace) means this can't
                    // be left-delimiting
                    break :fsm .{
                        .r_delim_underscore,
                        evaluateDelimUnderscoreContext(
                            self.in[self.i..lookahead_i],
                            false,
                            strings.isPunctuation(&.{b}),
                        ),
                    };
                },
                else => |b| {
                    break :fsm .{
                        .lr_delim_underscore,
                        evaluateDelimUnderscoreContext(
                            self.in[self.i..lookahead_i],
                            false,
                            strings.isPunctuation(&.{b}),
                        ),
                    };
                },
            }
        },
        .r_delim_punct_run => {
            if (lookahead_i >= self.in.len) {
                break :fsm .{
                    .r_delim_underscore,
                    evaluateDelimUnderscoreContext(
                        self.in[self.i..lookahead_i],
                        true,
                        false,
                    ),
                };
            }

            switch (self.in[lookahead_i]) {
                '_' => {
                    lookahead_i += 1;
                    continue :fsm .r_delim_punct_run;
                },
                ' ', '\t', '\n' => {
                    break :fsm .{
                        .r_delim_underscore,
                        evaluateDelimUnderscoreContext(
                            self.in[self.i..lookahead_i],
                            true,
                            false,
                        ),
                    };
                },
                '*', '!'...'%', '\''...')', '+'...'/', ':'...'@', '[', ']', '^',
                '`', '}'...'~' => {
                    break :fsm .{
                        .lr_delim_underscore,
                        evaluateDelimUnderscoreContext(
                            self.in[self.i..lookahead_i],
                            true,
                            true,
                        ),
                    };
                },
                else => |b| {
                    // Since this run started after punctuation, if it is not
                    // followed by punctuation it cannot be right-delimiting
                    break :fsm .{
                        .l_delim_underscore,
                        evaluateDelimUnderscoreContext(
                            self.in[self.i..lookahead_i],
                            true,
                            strings.isPunctuation(&.{b}),
                        ),
                    };
                }
            }
        },
    };

    const range = self.in[self.i..lookahead_i];
    const tokens = try evaluateTokens(scratch, token_type, context, range);
    return .{
        .tokens = tokens,
        .next_i = lookahead_i,
        .next_state = .punct,
    };
}

fn tokenizeWhitespace(self: Self, scratch: Allocator) !?TokenizeResult {
    var lookahead_i = self.i;
    while (lookahead_i < self.in.len) {
        switch (self.in[lookahead_i]) {
            ' ', '\t' => {
                lookahead_i += 1;
            },
            else => break,
        }
    }

    if (lookahead_i == self.i) {
        return null;
    }

    const tokens = try evaluateTokens(
        scratch,
        .whitespace,
        .default,
        self.in[self.i..lookahead_i],
    );
    return .{
        .tokens = tokens,
        .next_i = lookahead_i,
        .next_state = .whitespace,
    };
}

/// Tokenize basic text.
///
/// This is basically anything that wasn't already tokenized as something else.
fn tokenizeText(self: Self, scratch: Allocator) !?TokenizeResult {
    var lookahead_i = self.i;

    const State = enum { start, normal, escaped, punct };
    const next_state: TopLevelState = fsm: switch (State.start) {
        .start => {
            // Allow the first character to be something that later we will
            // break on.
            switch (self.in[lookahead_i]) {
                '&', '`', '[', ']', '<', '>', '(', ')', '*', '_' => {
                    lookahead_i += 1;
                    continue :fsm .punct;
                },
                '\n', ' ', '\t' => {
                    lookahead_i += 1;
                    continue :fsm .normal;
                },
                else => continue :fsm .normal,
            }
        },
        .normal => {
            if (lookahead_i >= self.in.len) {
                break :fsm .normal;
            }

            switch (self.in[lookahead_i]) {
                '\n', ' ', '\t', '&', '`', '[', ']', '<', '>', '(', ')', '*',
                '_' => {
                    break :fsm .normal;
                },
                '\\' => {
                    lookahead_i += 1;
                    continue :fsm .escaped;
                },
                '!'...'%', '\'', '+'...'/', ':', ';', '=', '?', '@', '^',
                '{'...'~' => {
                    continue :fsm .punct;
                },
                else => {
                    lookahead_i += 1;
                    continue :fsm .normal;
                },
            }
        },
        .escaped => {
            if (lookahead_i >= self.in.len) {
                break :fsm .normal;
            }

            switch (self.in[lookahead_i]) {
                '`' => {
                    // Can't escape backticks
                    continue :fsm .normal;
                },
                '&', '[', ']', '<', '>', '(', ')', '*', '_',
                '!'...'%', '\'', '+'...'/', ':', ';', '=', '?', '@', '^',
                '{'...'~' => {
                    lookahead_i += 1; // skip escaped character
                    continue :fsm .punct;
                },
                ' ', '\t' => {
                    break :fsm .normal;
                },
                else => {
                    lookahead_i += 1; // skip escaped character
                    continue :fsm .normal;
                },
            }
        },
        .punct => {
            if (lookahead_i >= self.in.len) {
                break :fsm .punct;
            }

            switch (self.in[lookahead_i]) {
                '\n', ' ', '\t' ,'&', '`', '[', ']', '<', '>', '(', ')', '*',
                '_' => {
                    break :fsm .punct;
                },
                '!'...'%', '\'', '+'...'/', ':', ';', '=', '?', '@', '^',
                '{'...'~' => {
                    lookahead_i += 1;
                    continue :fsm .punct;
                },
                else => continue :fsm .normal,
            }
        },
    };

    const tokens = try evaluateTokens(
        scratch,
        .text,
        .default,
        self.in[self.i..lookahead_i],
    );
    return .{
        .tokens = tokens,
        .next_i = lookahead_i,
        .next_state = next_state,
    };
}

fn evaluateDelimStarContext(range: []const u8) Context {
    return .{
        .delim_star = .{
            .run_len = @intCast(range.len),
        }
    };
}

fn evaluateDelimUnderscoreContext(
    range: []const u8,
    preceded_by_punct: bool,
    followed_by_punct: bool,
) Context {
    return .{
        .delim_underscore = .{
            .run_len = @intCast(range.len),
            .preceded_by_punct = preceded_by_punct,
            .followed_by_punct = followed_by_punct,
        }
    };
}

fn evaluateTokens(
    scratch: Allocator,
    token_type: InlineTokenType,
    context: Context,
    range: []const u8,
) ![]InlineToken {
    std.debug.assert(range.len > 0);

    var tokens: ArrayList(InlineToken) = .empty;

    switch (token_type) {
        .newline => {
            try tokens.append(scratch, InlineToken{ .token_type = .newline });
        },
        .l_delim_star, .r_delim_star, .lr_delim_star, .l_delim_underscore,
        .r_delim_underscore, .lr_delim_underscore => {
            for (0..range.len) |_| {
                try tokens.append(scratch, InlineToken{
                    .token_type = token_type,
                    .context = context,
                });
            }
        },
        else => {
            try tokens.append(scratch, InlineToken{
                .token_type = token_type,
                .lexeme = try scratch.dupe(u8, range),
            });
        },
    }

    return try tokens.toOwnedSlice(scratch);
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

fn expectEqualTokens(
    expected: []const InlineTokenType,
    line: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var tokenizer = Self.init(line);

    for (expected) |exp| {
        const token = try tokenizer.next(scratch);
        try std.testing.expect(token != null);
        try std.testing.expectEqual(exp, token.?.token_type);
    }

    try std.testing.expect(try tokenizer.next(scratch) == null);
}

test "mixed delimiter runs" {
    const line = "*_foo_*_*bar*_";
    try expectEqualTokens(&.{
        .l_delim_star,
        .l_delim_underscore,
        .text,
        .r_delim_underscore,
        .lr_delim_star,
        .lr_delim_underscore,
        .l_delim_star,
        .text,
        .r_delim_star,
        .r_delim_underscore,
    }, line);
}

test "delim star context" {
    const line = "**foo**";

    const expected = [_]InlineTokenType{
        .l_delim_star,
        .l_delim_star,
        .text,
        .r_delim_star,
        .r_delim_star,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var tokenizer = Self.init(line);

    for (expected) |exp| {
        const token = (try tokenizer.next(scratch)).?;
        try std.testing.expectEqual(exp, token.token_type);

        if (token.token_type == .l_delim_star) {
            try testing.expectEqual(2, token.context.delim_star.run_len);
        }

        if (token.token_type == .r_delim_star) {
            try testing.expectEqual(2, token.context.delim_star.run_len);
        }
    }

    try std.testing.expect(try tokenizer.next(scratch) == null);
}

// We should record the run length of the delimiter runs as context for the
// delimiter tokens.
//
// Additionally, for underscore delimiter tokens, we want to attach whether the
// delimiter run is preceded by punctuation or followed by punctuation.
test "delim underscore context" {
    const line = "(__foo__)";

    const expected = [_]InlineTokenType{
        .l_paren,
        .l_delim_underscore,
        .l_delim_underscore,
        .text,
        .r_delim_underscore,
        .r_delim_underscore,
        .r_paren,
    };

    var tokenizer = Self.init(line);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    for (expected) |exp| {
        const token = (try tokenizer.next(scratch)).?;
        try testing.expectEqual(exp, token.token_type);

        if (token.token_type == .l_delim_underscore) {
            try testing.expectEqual(2, token.context.delim_underscore.run_len);
            try testing.expectEqual(
                true,
                token.context.delim_underscore.preceded_by_punct,
            );
            try testing.expectEqual(
                false,
                token.context.delim_underscore.followed_by_punct,
            );
        }

        if (token.token_type == .r_delim_underscore) {
            try testing.expectEqual(2, token.context.delim_underscore.run_len);
            try testing.expectEqual(
                false,
                token.context.delim_underscore.preceded_by_punct,
            );
            try testing.expectEqual(
                true,
                token.context.delim_underscore.followed_by_punct,
            );
        }
    }

    try testing.expect(try tokenizer.next(scratch) == null);
}

test "entity reference" {
    const line = "&amp;";
    try expectEqualTokens(&.{.entity_reference}, line);
}

test "character reference" {
    const line = "&#42; &#; &#xaf;";
    try expectEqualTokens(&.{
        .decimal_character_reference,
        .whitespace,
        .text,
        .whitespace,
        .hexadecimal_character_reference,
    }, line);
}

test "regular text" {
    const line = "hello foo bar";
    try expectEqualTokens(&.{
        .text,
        .whitespace,
        .text,
        .whitespace,
        .text,
    }, line);
}

test "backtick run" {
    const line = "``foobar``";
    try expectEqualTokens(&.{
        .backtick,
        .text,
        .backtick,
    }, line);
}

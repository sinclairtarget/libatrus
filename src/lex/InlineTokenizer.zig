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

const InlineToken = @import("tokens.zig").InlineToken;
const InlineTokenType = @import("tokens.zig").InlineTokenType;
const Context = @import("tokens.zig").Context;
const strings = @import("../util/strings.zig");

pub const Error = Allocator.Error;

/// States for the tokenizer FSM.
const State = enum {
    start,
    start_punct,                     // preceded by punctuation
    text,
    text_escaped,
    text_whitespace,
    text_punct,                      // preceded by punctuation
    entity_reference,
    decimal_character_reference,
    hexadecimal_character_reference,
    l_delim_star_run,
    r_delim_star_run,
    r_delim_star_punct_run,          // preceded by punctuation
    l_delim_underscore_run,
    r_delim_underscore_run,
    r_delim_underscore_punct_run,    // preceded by punctuation
    backtick_run,
    done,
};

/// Emitted by the tokenizer FSM when a character sequence is accepted.
const FSMResult = struct {
    token_type: InlineTokenType,
    context: Context = .{ .empty = {} },
    next_state: State = .start,
};

in: []const u8,
i: usize,
state: State,
staged: ArrayList(InlineToken),

const Self = @This();

pub fn init(in: []const u8) Self {
    return .{
        .in = in,
        .i = 0,
        .state = .start,
        .staged = .empty,
    };
}

/// Returns the next token in the stream, or null if the stream is exhausted.
///
/// Caller owns the returned token.
pub fn next(self: *Self, alloc: Allocator) Error!?InlineToken {
    if (self.staged.pop()) |token| {
        return token;
    }

    if (self.state == .done) {
        return null;
    }

    return try self.scan(alloc);
}

fn scan(self: *Self, alloc: Allocator) !?InlineToken {
    var lookahead_i = self.i;
    const result: FSMResult = fsm: switch (self.state) {
        .start => {
            switch (self.in[lookahead_i]) {
                '\n' => {
                    lookahead_i += 1;
                    break :fsm .{ .token_type = .newline };
                },
                '&' => {
                    lookahead_i += 1;
                    if (lookahead_i >= self.in.len) {
                        break :fsm .{ .token_type = .text };
                    }

                    switch (self.in[lookahead_i]) {
                        '#' => {
                            lookahead_i += 1;
                            continue :fsm .decimal_character_reference;
                        },
                        'a'...'z', 'A'...'Z', '0'...'9' => {
                            continue :fsm .entity_reference;
                        },
                        else => {
                            continue :fsm .text_punct;
                        },
                    }
                },
                '*' => {
                    lookahead_i += 1;
                    continue :fsm .l_delim_star_run;
                },
                '_' => {
                    lookahead_i += 1;
                    continue :fsm .l_delim_underscore_run;
                },
                '`' => {
                    lookahead_i += 1;
                    continue :fsm .backtick_run;
                },
                '[' => {
                    lookahead_i += 1;
                    break :fsm .{
                        .token_type = .l_square_bracket,
                        .next_state = .start_punct,
                    };
                },
                ']' => {
                    lookahead_i += 1;
                    break :fsm .{
                        .token_type = .r_square_bracket,
                        .next_state = .start_punct,
                    };
                },
                '<' => {
                    lookahead_i += 1;
                    break :fsm .{
                        .token_type = .l_angle_bracket,
                        .next_state = .start_punct,
                    };
                },
                '>' => {
                    lookahead_i += 1;
                    break :fsm .{
                        .token_type = .r_angle_bracket,
                        .next_state = .start_punct,
                    };
                },
                '(' => {
                    lookahead_i += 1;
                    break :fsm .{
                        .token_type = .l_paren,
                        .next_state = .start_punct,
                    };
                },
                ')' => {
                    lookahead_i += 1;
                    break :fsm .{
                        .token_type = .r_paren,
                        .next_state = .start_punct,
                    };
                },
                else => {
                    continue :fsm .text;
                },
            }
        },
        .start_punct => {
            switch (self.in[lookahead_i]) {
                '*' => {
                    lookahead_i += 1;
                    continue :fsm .r_delim_star_punct_run;
                },
                '_' => {
                    lookahead_i += 1;
                    continue :fsm .r_delim_underscore_punct_run;
                },
                else => {
                    continue :fsm .start;
                },
            }
        },
        .decimal_character_reference => {
            var num_digits: u8 = 0;
            while (num_digits < 8 and lookahead_i < self.in.len) {
                switch (self.in[lookahead_i]) {
                    '0'...'9' => {
                        lookahead_i += 1;
                        num_digits += 1;
                    },
                    ';' => {
                        lookahead_i += 1;

                        if (num_digits > 0) {
                            break :fsm .{
                                .token_type = .decimal_character_reference,
                            };
                        } else {
                            continue :fsm .text_punct;
                        }
                    },
                    'x', 'X' => {
                        lookahead_i += 1;
                        continue :fsm .hexadecimal_character_reference;
                    },
                    else => {
                        continue :fsm .text;
                    },
                }
            }

            continue :fsm .text;
        },
        .hexadecimal_character_reference => {
            var num_digits: u8 = 0;
            while (num_digits < 7 and lookahead_i < self.in.len) {
                switch (self.in[lookahead_i]) {
                    '0'...'9', 'a'...'f', 'A'...'F' => {
                        lookahead_i += 1;
                        num_digits += 1;
                    },
                    ';' => {
                        lookahead_i += 1;

                        if (num_digits > 0) {
                            break :fsm .{
                                .token_type = .hexadecimal_character_reference,
                            };
                        } else {
                            continue :fsm .text_punct;
                        }
                    },
                    else => {
                        continue :fsm .text;
                    },
                }
            }

            continue :fsm .text;
        },
        .entity_reference => {
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .token_type = .text };
            }

            switch (self.in[lookahead_i]) {
                'a'...'z', 'A'...'Z', '0'...'9' => {
                    lookahead_i += 1;
                    continue :fsm .entity_reference;
                },
                ';' => {
                    lookahead_i += 1;
                    break :fsm .{ .token_type = .entity_reference };
                },
                else => {
                    continue :fsm .text;
                },
            }
        },
        .l_delim_star_run => {
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .token_type = .text };
            }

            switch (self.in[lookahead_i]) {
                '*' => {
                    lookahead_i += 1;
                    continue :fsm .l_delim_star_run;
                },
                '_' => {
                    break :fsm .{
                        .token_type = .l_delim_star,
                        .context = evaluateDelimStarContext(
                            self.in[self.i..lookahead_i],
                        ),
                        .next_state = .r_delim_underscore_punct_run,
                    };
                },
                ' ', '\t', '\n' => {
                    continue :fsm .text;
                },
                else => {
                    break :fsm .{
                        .token_type = .l_delim_star,
                        .context = evaluateDelimStarContext(
                            self.in[self.i..lookahead_i],
                        ),
                    };
                }
            }
        },
        .r_delim_star_run => {
            if (lookahead_i >= self.in.len) {
                break :fsm .{
                    .token_type = .r_delim_star,
                    .context = evaluateDelimStarContext(
                        self.in[self.i..lookahead_i],
                    ),
                };
            }

            switch (self.in[lookahead_i]) {
                '*' => {
                    lookahead_i += 1;
                    continue :fsm .r_delim_star_run;
                },
                '_' => {
                    break :fsm .{
                        .token_type = .r_delim_star,
                        .context = evaluateDelimStarContext(
                            self.in[self.i..lookahead_i],
                        ),
                        .next_state = .r_delim_underscore_punct_run,
                    };
                },
                ' ', '\t', '\n', '!'...'%', '\''...')', '+'...'/', ':'...'@',
                '[', ']', '^', '`', '}'...'~' => {
                    break :fsm .{
                        .token_type = .r_delim_star,
                        .context = evaluateDelimStarContext(
                            self.in[self.i..lookahead_i],
                        ),
                    };
                },
                else => {
                    break :fsm .{
                        .token_type = .lr_delim_star,
                        .context = evaluateDelimStarContext(
                            self.in[self.i..lookahead_i],
                        ),
                    };
                }
            }
        },
        .r_delim_star_punct_run => {
            if (lookahead_i >= self.in.len) {
                break :fsm .{
                    .token_type = .r_delim_star,
                    .context = evaluateDelimStarContext(
                        self.in[self.i..lookahead_i],
                    ),
                };
            }

            switch (self.in[lookahead_i]) {
                '*' => {
                    lookahead_i += 1;
                    continue :fsm .r_delim_star_punct_run;
                },
                ' ', '\t', '\n' => {
                    break :fsm .{
                        .token_type = .r_delim_star,
                        .context = evaluateDelimStarContext(
                            self.in[self.i..lookahead_i],
                        ),
                    };
                },
                '_' => {
                    break :fsm .{
                        .token_type = .lr_delim_star,
                        .context = evaluateDelimStarContext(
                            self.in[self.i..lookahead_i],
                        ),
                        .next_state = .r_delim_underscore_punct_run,
                    };
                },
                '!'...'%', '\''...')', '+'...'/', ':'...'@', '[', ']', '^', '`',
                '}'...'~' => {
                    break :fsm .{
                        .token_type = .lr_delim_star,
                        .context = evaluateDelimStarContext(
                            self.in[self.i..lookahead_i],
                        ),
                    };
                },
                else => {
                    break :fsm .{
                        .token_type = .l_delim_star,
                        .context = evaluateDelimStarContext(
                            self.in[self.i..lookahead_i],
                        ),
                    };
                }
            }
        },
        .l_delim_underscore_run => {
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .token_type = .text };
            }

            switch (self.in[lookahead_i]) {
                '_' => {
                    lookahead_i += 1;
                    continue :fsm .l_delim_underscore_run;
                },
                '*' => {
                    break :fsm .{
                        .token_type = .l_delim_underscore,
                        .context = evaluateDelimUnderscoreContext(
                            self.in[self.i..lookahead_i],
                            false,
                            true,
                        ),
                        .next_state = .r_delim_star_punct_run,
                    };
                },
                ' ', '\t', '\n' => {
                    continue :fsm .text;
                },
                else => |b| {
                    break :fsm .{
                        .token_type = .l_delim_underscore,
                        .context = evaluateDelimUnderscoreContext(
                            self.in[self.i..lookahead_i],
                            false,
                            strings.isPunctuation(&.{ b }),
                        ),
                    };
                }
            }
        },
        .r_delim_underscore_run => {
            if (lookahead_i >= self.in.len) {
                break :fsm .{
                    .token_type = .r_delim_underscore,
                    .context = evaluateDelimUnderscoreContext(
                        self.in[self.i..lookahead_i],
                        false,
                        false,
                    ),
                };
            }

            switch (self.in[lookahead_i]) {
                '_' => {
                    lookahead_i += 1;
                    continue :fsm .r_delim_underscore_run;
                },
                '*' => {
                    break :fsm .{
                        .token_type = .r_delim_underscore,
                        .context = evaluateDelimUnderscoreContext(
                            self.in[self.i..lookahead_i],
                            false,
                            true,
                        ),
                        .next_state = .r_delim_star_punct_run,
                    };
                },
                ' ', '\t', '\n', '!'...'%', '\''...')', '+'...'/', ':'...'@',
                '[', ']', '^', '`', '}'...'~' => |b| {
                    break :fsm .{
                        .token_type = .r_delim_underscore,
                        .context = evaluateDelimUnderscoreContext(
                            self.in[self.i..lookahead_i],
                            false,
                            strings.isPunctuation(&.{b}),
                        ),
                    };
                },
                else => |b| {
                    break :fsm .{
                        .token_type = .lr_delim_underscore,
                        .context = evaluateDelimUnderscoreContext(
                            self.in[self.i..lookahead_i],
                            false,
                            strings.isPunctuation(&.{b}),
                        ),
                    };
                }
            }
        },
        .r_delim_underscore_punct_run => {
            if (lookahead_i >= self.in.len) {
                break :fsm .{
                    .token_type = .r_delim_underscore,
                    .context = evaluateDelimUnderscoreContext(
                        self.in[self.i..lookahead_i],
                        true,
                        false,
                    ),
                };
            }

            switch (self.in[lookahead_i]) {
                '_' => {
                    lookahead_i += 1;
                    continue :fsm .r_delim_underscore_punct_run;
                },
                ' ', '\t', '\n' => {
                    break :fsm .{
                        .token_type = .r_delim_underscore,
                        .context = evaluateDelimUnderscoreContext(
                            self.in[self.i..lookahead_i],
                            true,
                            false,
                        ),
                    };
                },
                '*' => {
                    break :fsm .{
                        .token_type = .lr_delim_underscore,
                        .context = evaluateDelimUnderscoreContext(
                            self.in[self.i..lookahead_i],
                            true,
                            true,
                        ),
                        .next_state = .r_delim_star_punct_run,
                    };
                },
                '!'...'%', '\''...')', '+'...'/', ':'...'@', '[', ']', '^', '`',
                '}'...'~' => {
                    break :fsm .{
                        .token_type = .lr_delim_underscore,
                        .context = evaluateDelimUnderscoreContext(
                            self.in[self.i..lookahead_i],
                            true,
                            true,
                        ),
                    };
                },
                else => |b| {
                    break :fsm .{
                        .token_type = .l_delim_underscore,
                        .context = evaluateDelimUnderscoreContext(
                            self.in[self.i..lookahead_i],
                            true,
                            strings.isPunctuation(&.{b}),
                        ),
                    };
                }
            }
        },
        .backtick_run => {
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .token_type = .backtick };
            }

            switch (self.in[lookahead_i]) {
                '`' => {
                    lookahead_i += 1;
                    continue :fsm .backtick_run;
                },
                else => {
                    break :fsm .{ .token_type = .backtick };
                },
            }
        },
        .text => {
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .token_type = .text };
            }

            switch (self.in[lookahead_i]) {
                '\n', '&', '`', '[', ']', '<', '>', '(', ')' => {
                    break :fsm .{ .token_type = .text };
                },
                '*' => {
                    break :fsm .{
                        .token_type = .text,
                        .next_state = .r_delim_star_run,
                    };
                },
                '_' => {
                    break :fsm .{
                        .token_type = .text,
                        .next_state = .r_delim_underscore_run,
                    };
                },
                '\\' => {
                    lookahead_i += 1;
                    continue :fsm .text_escaped;
                },
                ' ', '\t' => {
                    continue :fsm .text_whitespace;
                },
                '!'...'%', '\'', '+'...'/', ':', ';', '=', '?', '@', '^',
                '{'...'~' => {
                    lookahead_i += 1;
                    continue :fsm .text_punct;
                },
                else => {
                    lookahead_i += 1;
                    continue :fsm .text;
                },
            }
        },
        .text_whitespace => {
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .token_type = .text };
            }

            switch (self.in[lookahead_i]) {
                '*' => {
                    break :fsm .{
                        .token_type = .text,
                        .next_state = .l_delim_star_run,
                    };
                },
                '_' => {
                    break :fsm .{
                        .token_type = .text,
                        .next_state = .l_delim_underscore_run,
                    };
                },
                ' ', '\t' => {
                    lookahead_i += 1;
                    continue :fsm .text_whitespace;
                },
                else => {
                    continue :fsm .text;
                },
            }
        },
        .text_escaped => {
            if (lookahead_i >= self.in.len) {
                continue :fsm .text;
            }

            switch (self.in[lookahead_i]) {
                '`' => {
                    // Can't escape backticks
                    continue :fsm .text;
                },
                else => {
                    // Skip character
                    lookahead_i += 1;
                    continue :fsm .text;
                },
            }
        },
        .text_punct => {
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .token_type = .text };
            }

            switch (self.in[lookahead_i]) {
                '*' => {
                    break :fsm .{
                        .token_type = .text,
                        .next_state = .r_delim_star_punct_run,
                    };
                },
                '_' => {
                    break :fsm .{
                        .token_type = .text,
                        .next_state = .r_delim_underscore_punct_run,
                    };
                },
                else => {
                    continue :fsm .text;
                },
            }
        },
        .done => unreachable,
    };

    const tokens = try evaluateTokens(
        alloc,
        result.token_type,
        result.context,
        self.in[self.i..lookahead_i],
    );

    self.i = lookahead_i;
    self.state = result.next_state;
    if (self.i >= self.in.len) {
        self.state = .done;
    }

    if (tokens.len > 1) {
        var i = tokens.len - 1;
        while (i > 0) {
            try self.staged.append(alloc, tokens[i]);
            i -= 1;
        }
    }
    return tokens[0];
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
    alloc: Allocator,
    token_type: InlineTokenType,
    context: Context,
    range: []const u8,
) ![]InlineToken {
    var tokens: ArrayList(InlineToken) = .empty;

    switch (token_type) {
        .newline => {
            try tokens.append(alloc, InlineToken{ .token_type = .newline });
        },
        .l_delim_star, .r_delim_star, .lr_delim_star, .l_delim_underscore,
        .r_delim_underscore, .lr_delim_underscore => {
            for (0..range.len) |_| {
                try tokens.append(alloc, InlineToken{
                    .token_type = token_type,
                    .context = context,
                });
            }
        },
        else => {
            try tokens.append(alloc, InlineToken{
                .token_type = token_type,
                .lexeme = try alloc.dupe(u8, range),
            });
        },
    }

    return try tokens.toOwnedSlice(alloc);
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

test "tokenize mixed delimiter runs" {
    const line = "*_foo_*_*bar*_";

    const expected = [_]InlineTokenType{
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
    };

    var tokenizer = Self.init(line);

    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    for (expected) |exp| {
        const token = try tokenizer.next(arena);
        try testing.expectEqual(exp, token.?.token_type);
    }

    try testing.expect(try tokenizer.next(arena) == null);
}

// We should record the run length of the delimiter runs as context for the
// delimiter tokens.
test "tokenize delim star context" {
    const line = "**foo**";

    const expected = [_]InlineTokenType{
        .l_delim_star,
        .l_delim_star,
        .text,
        .r_delim_star,
        .r_delim_star,
    };

    var tokenizer = Self.init(line);

    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    for (expected) |exp| {
        const token = (try tokenizer.next(arena)).?;
        try testing.expectEqual(exp, token.token_type);

        if (
            token.token_type == .l_delim_star
            or token.token_type == .r_delim_star
        ) {
            try testing.expectEqual(2, token.context.delim_star.run_len);
        }
    }

    try testing.expect(try tokenizer.next(arena) == null);
}

// We should record the run length of the delimiter runs as context for the
// delimiter tokens.
//
// Additionally, for underscore delimiter tokens, we want to attach whether the
// delimiter run is preceded by punctuation or followed by punctuation.
test "tokenize delim underscore context" {
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

    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    for (expected) |exp| {
        const token = (try tokenizer.next(arena)).?;
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

    try testing.expect(try tokenizer.next(arena) == null);
}

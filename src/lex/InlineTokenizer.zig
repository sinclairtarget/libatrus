//! Tokenizer for inline MyST syntax.
//!
//! Some transitions through the finite state machine might generate multiple
//! tokens. We do this to attach context to some tokens that need them to be
//! correctly parsed (e.g. we need the delimiter run length for individual
//! delimiter tokens). Since the token stream is meant to be consumed one token
//! at a time, when we have multiple tokens we "stage" them in an array list
//! until they can be consumed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const InlineToken = @import("tokens.zig").InlineToken;
const InlineTokenType = @import("tokens.zig").InlineTokenType;
const Context = @import("tokens.zig").Context;
const strings = @import("../util/strings.zig");

const State = enum {
    started,
    started_punct,
    text,
    text_escaped,
    text_whitespace,
    text_punct,
    entity_reference,
    decimal_character_reference,
    hexadecimal_character_reference,
    l_delim_star_run,
    r_delim_star_run,
    r_delim_star_punct_run, // preceded by punctuation
    l_delim_underscore_run,
    r_delim_underscore_run,
    r_delim_underscore_punct_run, // preceded by punctuation
    backtick_run,
    done,
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
        .state = .started,
        .staged = .empty,
    };
}

pub fn next(self: *Self, arena: Allocator) !?InlineToken {
    if (self.staged.pop()) |token| {
        return token;
    }

    if (self.state == .done) {
        return null;
    }

    return try self.scan(arena);
}

fn scan(self: *Self, arena: Allocator) !?InlineToken {
    var lookahead_i = self.i;
    const result: struct { InlineTokenType, State } = fsm: switch (self.state) {
        .started => {
            self.state = .started; // Keep struct field in sync with switch
            switch (self.in[lookahead_i]) {
                '\n' => {
                    lookahead_i += 1;
                    break :fsm .{ .newline, .started };
                },
                '&' => {
                    lookahead_i += 1;
                    if (lookahead_i >= self.in.len) {
                        break :fsm .{ .text, .started };
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
                    break :fsm .{ .l_square_bracket, .started_punct };
                },
                ']' => {
                    lookahead_i += 1;
                    break :fsm .{ .r_square_bracket, .started_punct };
                },
                '<' => {
                    lookahead_i += 1;
                    break :fsm .{ .l_angle_bracket, .started_punct };
                },
                '>' => {
                    lookahead_i += 1;
                    break :fsm .{ .r_angle_bracket, .started_punct };
                },
                '(' => {
                    lookahead_i += 1;
                    break :fsm .{ .l_paren, .started_punct };
                },
                ')' => {
                    lookahead_i += 1;
                    break :fsm .{ .r_paren, .started_punct };
                },
                else => {
                    continue :fsm .text;
                },
            }
        },
        .started_punct => {
            self.state = .started_punct;
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
                    continue :fsm .started;
                },
            }
        },
        .decimal_character_reference => {
            self.state = .decimal_character_reference;

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
                                .decimal_character_reference,
                                .started,
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
            self.state = .hexadecimal_character_reference;

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
                                .hexadecimal_character_reference,
                                .started,
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
            self.state = .entity_reference;
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .text, .started };
            }

            switch (self.in[lookahead_i]) {
                'a'...'z', 'A'...'Z', '0'...'9' => {
                    lookahead_i += 1;
                    continue :fsm .entity_reference;
                },
                ';' => {
                    lookahead_i += 1;
                    break :fsm .{ .entity_reference, .started };
                },
                else => {
                    continue :fsm .text;
                },
            }
        },
        .l_delim_star_run => {
            self.state = .l_delim_star_run;
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .text, .started };
            }

            switch (self.in[lookahead_i]) {
                '*' => {
                    lookahead_i += 1;
                    continue :fsm .l_delim_star_run;
                },
                '_' => {
                    break :fsm .{ .l_delim_star, .r_delim_underscore_punct_run };
                },
                ' ', '\t', '\n' => {
                    continue :fsm .text;
                },
                else => {
                    break :fsm .{ .l_delim_star, .started };
                }
            }
        },
        .r_delim_star_run => {
            self.state = .r_delim_star_run;
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .r_delim_star, .started };
            }

            switch (self.in[lookahead_i]) {
                '*' => {
                    lookahead_i += 1;
                    continue :fsm .r_delim_star_run;
                },
                '_' => {
                    break :fsm .{ .r_delim_star, .r_delim_underscore_punct_run };
                },
                ' ', '\t', '\n', '!'...'%', '\''...')', '+'...'/', ':'...'@',
                '[', ']', '^', '`', '}'...'~' => {
                    break :fsm .{ .r_delim_star, .started };
                },
                else => {
                    break :fsm .{ .lr_delim_star, .started };
                }
            }
        },
        .r_delim_star_punct_run => {
            self.state = .r_delim_star_punct_run;
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .r_delim_star, .started };
            }

            switch (self.in[lookahead_i]) {
                '*' => {
                    lookahead_i += 1;
                    continue :fsm .r_delim_star_punct_run;
                },
                ' ', '\t', '\n' => {
                    break :fsm .{ .r_delim_star, .started };
                },
                '_' => {
                    break :fsm .{ .lr_delim_star, .r_delim_underscore_punct_run };
                },
                '!'...'%', '\''...')', '+'...'/', ':'...'@', '[', ']', '^', '`',
                '}'...'~' => {
                    break :fsm .{ .lr_delim_star, .started };
                },
                else => {
                    break :fsm .{ .l_delim_star, .started };
                }
            }
        },
        .l_delim_underscore_run => {
            self.state = .l_delim_underscore_run;
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .text, .started };
            }

            switch (self.in[lookahead_i]) {
                '_' => {
                    lookahead_i += 1;
                    continue :fsm .l_delim_underscore_run;
                },
                '*' => {
                    break :fsm .{ .l_delim_underscore, .r_delim_star_punct_run };
                },
                ' ', '\t', '\n' => {
                    continue :fsm .text;
                },
                else => {
                    break :fsm .{ .l_delim_underscore, .started };
                }
            }
        },
        .r_delim_underscore_run => {
            self.state = .r_delim_underscore_run;
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .r_delim_underscore, .started };
            }

            switch (self.in[lookahead_i]) {
                '_' => {
                    lookahead_i += 1;
                    continue :fsm .r_delim_underscore_run;
                },
                '*' => {
                    break :fsm .{ .r_delim_underscore, .r_delim_star_punct_run };
                },
                ' ', '\t', '\n', '!'...'%', '\''...')', '+'...'/', ':'...'@',
                '[', ']', '^', '`', '}'...'~' => {
                    break :fsm .{ .r_delim_underscore, .started };
                },
                else => {
                    break :fsm .{ .lr_delim_underscore, .started };
                }
            }
        },
        .r_delim_underscore_punct_run => {
            self.state = .r_delim_underscore_punct_run;
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .r_delim_underscore, .started };
            }

            switch (self.in[lookahead_i]) {
                '_' => {
                    lookahead_i += 1;
                    continue :fsm .r_delim_underscore_punct_run;
                },
                ' ', '\t', '\n' => {
                    break :fsm .{ .r_delim_underscore, .started };
                },
                '*' => {
                    break :fsm .{ .lr_delim_underscore, .r_delim_star_punct_run };
                },
                '!'...'%', '\''...')', '+'...'/', ':'...'@', '[', ']', '^', '`',
                '}'...'~' => {
                    break :fsm .{ .lr_delim_underscore, .started };
                },
                else => {
                    break :fsm .{ .l_delim_underscore, .started };
                }
            }
        },
        .backtick_run => {
            self.state = .backtick_run;
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .backtick, .started };
            }

            switch (self.in[lookahead_i]) {
                '`' => {
                    lookahead_i += 1;
                    continue :fsm .backtick_run;
                },
                else => {
                    break :fsm .{ .backtick, .started_punct };
                },
            }
        },
        .text => {
            self.state = .text;
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .text, .started };
            }

            switch (self.in[lookahead_i]) {
                '\n', '&', '`', '[', ']', '<', '>', '(', ')' => {
                    break :fsm .{ .text, .started };
                },
                '*' => {
                    break :fsm .{ .text, .r_delim_star_run };
                },
                '_' => {
                    break :fsm .{ .text, .r_delim_underscore_run };
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
            self.state = .text_whitespace;
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .text, .started };
            }

            switch (self.in[lookahead_i]) {
                '*' => {
                    break :fsm .{ .text, .l_delim_star_run };
                },
                '_' => {
                    break :fsm .{ .text, .l_delim_underscore_run };
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
            self.state = .text_escaped;
            if (lookahead_i >= self.in.len) {
                continue :fsm .text;
            }

            switch (self.in[lookahead_i]) {
                '`' => {
                    continue :fsm .text;
                },
                else => {
                    lookahead_i += 1;
                    continue :fsm .text;
                },
            }
        },
        .text_punct => {
            self.state = .text_punct;
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .text, .started };
            }

            switch (self.in[lookahead_i]) {
                '*' => {
                    break :fsm .{ .text, .r_delim_star_punct_run };
                },
                '_' => {
                    break :fsm .{ .text, .r_delim_underscore_punct_run };
                },
                else => {
                    continue :fsm .text;
                },
            }
        },
        .done => unreachable,
    };

    const token_type, const next_state = result;
    const tokens = try evaluateTokens(self, arena, token_type, lookahead_i);

    self.i = lookahead_i;
    self.state = next_state;
    if (self.i >= self.in.len) {
        self.state = .done;
    }

    if (tokens.len > 1) {
        var i = tokens.len - 1;
        while (i > 0) {
            try self.staged.append(arena, tokens[i]);
            i -= 1;
        }
    }
    return tokens[0];
}

fn evaluateTokens(
    self: *Self,
    arena: Allocator,
    token_type: InlineTokenType,
    lookahead_i: usize,
) ![]InlineToken {
    var tokens: ArrayList(InlineToken) = .empty;

    switch (token_type) {
        .newline => {
            try tokens.append(arena, InlineToken{ .token_type = .newline });
        },
        .l_delim_star, .r_delim_star, .lr_delim_star, .l_delim_underscore,
        .r_delim_underscore, .lr_delim_underscore => {
            const len = lookahead_i - self.i;
            for (0..len) |_| {
                try tokens.append(arena, InlineToken{
                    .token_type = token_type,
                    .context = self.evaluateContext(token_type, lookahead_i),
                });
            }
        },
        else => {
            try tokens.append(arena, InlineToken{
                .token_type = token_type,
                .lexeme = try arena.dupe(u8, self.in[self.i..lookahead_i]),
            });
        },
    }

    return try tokens.toOwnedSlice(arena);
}

fn evaluateContext(
    self: Self,
    token_type: InlineTokenType,
    lookahead_i: usize,
) Context {
    const last_state = self.state;
    return switch (token_type) {
        .l_delim_star, .r_delim_star, .lr_delim_star => .{
            .delim_star = .{
                .run_len = @intCast(lookahead_i - self.i),
            }
        },
        .l_delim_underscore, .r_delim_underscore, .lr_delim_underscore => .{
            .delim_underscore = .{
                .run_len = @intCast(lookahead_i - self.i),
                .preceded_by_punct = (
                    last_state == .r_delim_underscore_punct_run
                ),
                .followed_by_punct = (
                    lookahead_i < self.in.len
                    and strings.isPunctuation(
                        self.in[lookahead_i..lookahead_i + 1]
                    )
                ),
            }
        },
        else => .{ .empty = {} },
    };
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

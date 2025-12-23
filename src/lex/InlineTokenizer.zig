//! Tokenizer for inline MyST syntax.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const InlineToken = @import("../lex/tokens.zig").InlineToken;
const InlineTokenType = @import("../lex/tokens.zig").InlineTokenType;

const State = enum {
    started,
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
                        else => continue :fsm .text_punct,
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
                else => {
                    continue :fsm .text;
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
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .text, .started };
            }

            switch (self.in[lookahead_i]) {
                '*' => {
                    lookahead_i += 1;
                    continue :fsm .l_delim_star_run;
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
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .r_delim_star, .started };
            }

            switch (self.in[lookahead_i]) {
                '*' => {
                    lookahead_i += 1;
                    continue :fsm .r_delim_star_run;
                },
                ' ', '\t', '\n', '!'...'%', '\''...')', '+'...'/', ':'...'@',
                '[', ']'...'`', '}'...'~' => {
                    break :fsm .{ .r_delim_star, .started };
                },
                else => {
                    break :fsm .{ .lr_delim_star, .started };
                }
            }
        },
        .r_delim_star_punct_run => {
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
                '!'...'%', '\''...')', '+'...'/', ':'...'@', '[', ']'...'`',
                '}'...'~' => {
                    break :fsm .{ .lr_delim_star, .started };
                },
                else => {
                    break :fsm .{ .l_delim_star, .started };
                }
            }
        },
        .l_delim_underscore_run => {
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .text, .started };
            }

            switch (self.in[lookahead_i]) {
                '_' => {
                    lookahead_i += 1;
                    continue :fsm .l_delim_underscore_run;
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
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .r_delim_underscore, .started };
            }

            switch (self.in[lookahead_i]) {
                '_' => {
                    lookahead_i += 1;
                    continue :fsm .r_delim_underscore_run;
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
                '!'...'%', '\''...')', '+'...'/', ':'...'@', '[', ']', '^', '`',
                '}'...'~' => {
                    break :fsm .{ .lr_delim_underscore, .started };
                },
                else => {
                    break :fsm .{ .l_delim_underscore, .started };
                }
            }
        },
        .text => {
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .text, .started };
            }

            switch (self.in[lookahead_i]) {
                '\n', '&' => {
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
                '!'...'%', '\''...')', '+'...'/', ':'...'@', '[', ']', '^', '`',
                '}'...'~' => {
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
            if (lookahead_i < self.in.len) {
                lookahead_i += 1;
            }

            continue :fsm .text;
        },
        .text_punct => {
            if (lookahead_i >= self.in.len) {
                break :fsm .{ .text, .started };
            }

            switch (self.in[lookahead_i]) {
                '\n', '&' => {
                    break :fsm .{ .text, .started };
                },
                '*' => {
                    break :fsm .{ .text, .r_delim_star_punct_run };
                },
                '_' => {
                    break :fsm .{ .text, .r_delim_underscore_punct_run };
                },
                '\\' => {
                    lookahead_i += 1;
                    continue :fsm .text_escaped;
                },
                ' ', '\t' => {
                    continue :fsm .text_whitespace;
                },
                else => {
                    lookahead_i += 1;
                    continue :fsm .text;
                },
            }
        },
        .done => unreachable,
    };

    const token_type, const next_state = result;
    const tokens = try evaluate_tokens(self, arena, token_type, lookahead_i);

    self.i = lookahead_i;
    self.state = next_state;
    if (self.i >= self.in.len) {
        self.state = .done;
    }

    if (tokens.len > 1) {
        var i = tokens.len - 1;
        while (i > 1) {
            try self.staged.append(arena, tokens[i]);
            i -= 1;
        }
    }
    return tokens[0];
}

fn evaluate_tokens(
    self: *Self,
    arena: Allocator,
    token_type: InlineTokenType,
    lookahead_i: usize,
) ![]InlineToken {
    var tokens: ArrayList(InlineToken) = .empty;

    switch (token_type) {
        .newline => {
            try tokens.append(arena, InlineToken{
                .token_type = .newline,
            });
        },
        .text => {
            const lexeme = try copyWithoutEscapes(
                arena,
                self.in[self.i..lookahead_i],
            );
            try tokens.append(arena, InlineToken{
                .token_type = .text,
                .lexeme = lexeme,
            });
        },
        .l_delim_star, .r_delim_star, .lr_delim_star, .l_delim_underscore,
        .r_delim_underscore, .lr_delim_underscore => {
            for (self.i..lookahead_i + 1) |_| {
                try tokens.append(arena, InlineToken{
                    .token_type = token_type,
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

fn evaluate_lexeme(
    self: *Self,
    arena: Allocator,
    token_type: InlineTokenType,
    lookahead_i: usize,
) !?[]const u8 {
    switch (token_type) {
        .newline => {
            return null;
        },
        .text => {
            return try copyWithoutEscapes(arena, self.in[self.i..lookahead_i]);
        },
        else => {
            return try arena.dupe(u8, self.in[self.i..lookahead_i]);
        },
    }
}

/// Duplicates the given string, but skips all backslashes (unless they are
/// themselves escaped).
fn copyWithoutEscapes(alloc: Allocator, s: []const u8) ![]const u8 {
    const copy = try alloc.alloc(u8, s.len);

    var state: enum { normal, escape } = .normal;
    var source_index: usize = 0;
    var dest_index: usize = 0;
    while (source_index < s.len) {
        switch (state) {
            .normal => {
                switch (s[source_index]) {
                    '\\' => {
                        source_index += 1;
                        state = .escape;
                    },
                    else => {
                        copy[dest_index] = s[source_index];
                        source_index += 1;
                        dest_index += 1;
                    },
                }
            },
            .escape => {
                switch (s[source_index]) {
                    '\\' => {
                        // literal backslash
                        copy[dest_index] = s[source_index];
                        source_index += 1;
                        dest_index += 1;
                    },
                    else => {},
                }
                state = .normal;
            },
        }
    }

    return copy[0..dest_index];
}

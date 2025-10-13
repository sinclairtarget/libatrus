const std = @import("std");
const Allocator = std.mem.Allocator;

const tokens = @import("../lex/tokens.zig");
const InlineToken = tokens.InlineToken;
const InlineTokenType = tokens.InlineTokenType;

const State = enum {
    started,
    text,
    entity_reference,
    decimal_character_reference,
    hexadecimal_character_reference,
    done,
};

in: []const u8,
i: usize,
state: State,

const Self = @This();

pub fn init(in: []const u8) Self {
    return .{
        .in = in,
        .i = 0,
        .state = .started,
    };
}

pub fn next(self: *Self, arena: Allocator) !?InlineToken {
    if (self.state == .done) {
        return null;
    }

    return try self.scan(arena);
}

fn scan(self: *Self, arena: Allocator) !?InlineToken {
    var lookahead_i = self.i;
    const token_type: InlineTokenType = fsm: switch (self.state) {
        .started => {
            switch (self.in[lookahead_i]) {
                '\n' => {
                    lookahead_i += 1;
                    break :fsm .newline;
                },
                '&' => {
                    lookahead_i += 1;
                    if (lookahead_i >= self.in.len) {
                        break :fsm .text;
                    }

                    switch (self.in[lookahead_i]) {
                        '#' => {
                            lookahead_i += 1;
                            continue :fsm .decimal_character_reference;
                        },
                        'a'...'z', 'A'...'Z', '0'...'9' => {
                            continue :fsm .entity_reference;
                        },
                        else => continue :fsm .text,
                    }
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
                            break :fsm .decimal_character_reference;
                        } else {
                            continue :fsm .text;
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
                            break :fsm .hexadecimal_character_reference;
                        } else {
                            continue :fsm .text;
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
                break :fsm .text;
            }

            switch (self.in[lookahead_i]) {
                'a'...'z', 'A'...'Z', '0'...'9' => {
                    lookahead_i += 1;
                    continue :fsm .entity_reference;
                },
                ';' => {
                    lookahead_i += 1;
                    break :fsm .entity_reference;
                },
                else => {
                    continue :fsm .text;
                },
            }
        },
        .text => {
            if (lookahead_i >= self.in.len) {
                break :fsm .text;
            }

            switch (self.in[lookahead_i]) {
                '\n', '&' => {
                    break :fsm .text;
                },
                else => {
                    lookahead_i += 1;
                    continue :fsm .text;
                },
            }
        },
        .done => unreachable,
    };

    const lexeme = try evaluate_lexeme(self, arena, token_type, lookahead_i);
    const token = InlineToken{
        .token_type = token_type,
        .lexeme = lexeme,
    };

    self.i = lookahead_i;
    if (self.i >= self.in.len) {
        self.state = .done;
    }

    return token;
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

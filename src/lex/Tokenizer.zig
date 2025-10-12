//! Takes an input reader and tokenizes line by line.
const std = @import("std");
const ascii = std.ascii;
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const DelimiterError = Io.Reader.DelimiterError;
const ArrayList = std.ArrayList;

const Token = @import("tokens.zig").Token;
const TokenType = @import("tokens.zig").TokenType;

pub const Error = error{
    LineTooLong,
    ReadFailed,
    UnicodeError,
} || Allocator.Error;

const State = enum {
    started,
    indent,
    pound,
    text,
    text_whitespace,
    decimal_character_reference,
    hexadecimal_character_reference,
    entity_reference,
};

in: *Io.Reader,
line: []const u8,
i: usize,
state: State,

const Self = @This();

pub fn init(in: *Io.Reader) Self {
    return .{
        .in = in,
        .line = "",
        .i = 0,
        .state = .started,
    };
}

// Get next token from the stream.
//
// Caller responsible for freeing memory associated with each returned token.
pub fn next(self: *Self, arena: Allocator) Error!?Token {
    // Load new input line when needed
    while (self.i >= self.line.len) {
        self.line = read_line(arena, self.in) catch |err| {
            switch (err) {
                DelimiterError.EndOfStream => {
                    return null;
                },
                DelimiterError.StreamTooLong => {
                    return Error.LineTooLong;
                },
                else => |e| return e,
            }
        };
        self.i = 0;
    }

    return try self.scan(arena);
}

// Reads the next line from the input stream.
//
// Returned line will always be terminated by a newline character.
//
// This basically implements `takeDelimiterInclusive` so that it treats EOF as
// a break the same way `takeDelimiterExclusive` does.
fn read_line(arena: Allocator, in: *Io.Reader) ![]const u8 {
    const line = in.takeDelimiterInclusive('\n') catch |err| blk: {
        switch (err) {
            DelimiterError.EndOfStream => {
                if (in.bufferedLen() > 0) {
                    // terminate with newline
                    const line = try fmt.allocPrint(
                        arena,
                        "{s}\n",
                        .{ in.buffered() },
                    );
                    in.tossBuffered();
                    break :blk line;
                }

                return err;
            },
            DelimiterError.StreamTooLong => {
                // Next newline is further away than the capacity of the
                // reader's buffer. If the stream is about to end anyway though,
                // we just treat that the same as the end-of-stream case.
                const line = try fmt.allocPrint(
                    arena,
                    "{s}\n",
                    .{ in.buffered() },
                );
                in.tossBuffered();
                _ = in.peekByte() catch |peek_err| {
                    switch (peek_err) {
                        Io.Reader.Error.EndOfStream => {
                            break :blk line;
                        },
                        else => return peek_err,
                    }
                };

                return DelimiterError.StreamTooLong;
            },
            else => return err,
        }
    };

    return line;
}

// Returns the next token starting at the current index.
fn scan(self: *Self, arena: Allocator) !Token {
    var lookahead_i = self.i;
    const token_type: TokenType = fsm: switch (self.state) {
        .started => {
            switch (self.line[lookahead_i]) {
                '#' => {
                    continue :fsm .pound;
                },
                '\n' => {
                    lookahead_i += 1;
                    break :fsm .newline;
                },
                ' ', '\t' => {
                    if (lookahead_i == 0) { // indent only at beginning of line
                        continue :fsm .indent;
                    }

                    continue :fsm .text;
                },
                '&' => {
                    lookahead_i += 1;
                    switch (self.line[lookahead_i]) {
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
        .indent => {
            switch (self.line[lookahead_i]) {
                '\t' => {
                    lookahead_i += 1;
                    break :fsm .indent;
                },
                ' ' => {
                    lookahead_i += 1;
                    if (lookahead_i - self.i == 4) {
                        break :fsm .indent;
                    }

                    continue :fsm .indent;
                },
                '#' => continue :fsm .pound,
                else => continue :fsm .text,
            }
        },
        .pound => {
            switch (self.line[lookahead_i]) {
                '#' => {
                    lookahead_i += 1;
                    continue :fsm .pound;
                },
                ' ', '\t', '\n' => {
                    break :fsm .pound;
                },
                else => {
                    continue :fsm .text;
                },
            }
        },
        .decimal_character_reference => {
            var num_digits: u8 = 0;
            while (num_digits < 8) {
                switch (self.line[lookahead_i]) {
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
            while (num_digits < 7) {
                switch (self.line[lookahead_i]) {
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
            switch (self.line[lookahead_i]) {
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
            switch (self.line[lookahead_i]) {
                '\n' => {
                    break :fsm .text;
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
        .text_whitespace => {
            switch (self.line[lookahead_i]) {
                '\n', '#', '&' => {
                    break :fsm .text;
                },
                ' ', '\t' => {
                    lookahead_i += 1;
                    continue :fsm .text_whitespace;
                },
                else => {
                    lookahead_i += 1;
                    continue :fsm .text;
                },
            }
        },
    };

    const lexeme = try evaluate_lexeme(self, arena, token_type, lookahead_i);
    const token = Token{
        .token_type = token_type,
        .lexeme = lexeme,
    };

    self.i = lookahead_i;
    return token;
}

fn evaluate_lexeme(
    self: *Self,
    arena: Allocator,
    token_type: TokenType,
    lookahead_i: usize,
) !?[]const u8 {
    switch (token_type) {
        .newline, .indent => {
            return null;
        },
        .pound => {
            const lexeme = try copyWithoutEscapes(
                arena,
                std.mem.trim(u8, self.line[self.i..lookahead_i], " \t"),
            );
            return lexeme;
        },
        .decimal_character_reference, .hexadecimal_character_reference,
        .entity_reference => {
            return try arena.dupe(u8, self.line[self.i..lookahead_i]);
        },
        else => {
            return try copyWithoutEscapes(arena, self.line[self.i..lookahead_i]);
        },
    }
}

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
                    }
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
                    else => {}
                }
                state = .normal;
            },
        }
    }

    return copy[0..dest_index];
}

test "can tokenize" {
    const md =
        \\# Header
        \\## Subheader
        \\This is a paragraph.
        \\It has multiple lines.
        \\
        \\This is a new paragraph.
        \\
    ;

    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var tokens: ArrayList(Token) = .empty;
    errdefer tokens.deinit(arena);

    var reader: Io.Reader = .fixed(md);
    var tokenizer = Self.init(&reader);

    const expected = [_]TokenType{
        .pound,
        .text,
        .newline,
        .pound,
        .text,
        .newline,
        .text,
        .newline,
        .text,
        .newline,
        .newline,
        .text,
        .newline,
    };

    for (expected) |exp| {
        const token = try tokenizer.next(arena);
        try std.testing.expectEqual(exp, token.?.token_type);
    }

    try std.testing.expectEqual(null, try tokenizer.next(arena));
}

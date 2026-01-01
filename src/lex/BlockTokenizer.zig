//! Tokenizer that recognizes block-level tokens.
//!
//! Takes a line reader over a MyST markdown document. Reads the document one
//! line at a time, producing tokens on demand. Anything that isn't scanned as
//! a meaningful block-level token is yielded as a generic "text" token.

const std = @import("std");
const ascii = std.ascii;
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const DelimiterError = Io.Reader.DelimiterError;
const ArrayList = std.ArrayList;

const BlockToken = @import("tokens.zig").BlockToken;
const BlockTokenType = @import("tokens.zig").BlockTokenType;
const LineReader = @import("LineReader.zig");

pub const Error = error{
    /// Input reader did not have a large enough buffer to read a whole line.
    LineTooLong,
    /// Failure in reading from input stream.
    ReadFailed,
} || Allocator.Error;

/// Possible states for the FSM.
const State = enum {
    started,
    indent,
    pound,
    text,
    text_whitespace,
    rule,
};

reader: LineReader,
line: []const u8,
i: usize,                // current index into line
state: State,

const Self = @This();

pub fn init(reader: LineReader) Self {
    return .{
        .reader = reader,
        .line = "",
        .i = 0,
        .state = .started,
    };
}

/// Get next token from the stream. Returns null when the stream is exhausted.
///
/// Caller is responsible for freeing memory associated with each returned
/// token. (The returned tokens own the memory used to store their lexemes.)
pub fn next(self: *Self, alloc: Allocator) Error!?BlockToken {
    // Load new input line when needed
    if (self.i >= self.line.len) {
        self.line = try self.reader.next() orelse return null;
        self.i = 0;
    }

    return try self.scan(alloc);
}

/// Returns the next token starting at the current index.
fn scan(self: *Self, alloc: Allocator) !BlockToken {
    var lookahead_i = self.i;
    const token_type: BlockTokenType = fsm: switch (self.state) {
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
                '*', '-', '_', '=' => {
                    if (lookahead_i == 0) {
                        continue :fsm .rule;
                    }

                    continue :fsm .text;
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
                '*', '-', '_', '=' => continue :fsm .rule,
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
        .rule => {
            const char = self.line[lookahead_i];
            var num_chars: u32 = 0;
            var contains_whitespace = false;

            while (self.line[lookahead_i] != '\n') {
                if (self.line[lookahead_i] != char) {
                    if (self.line[lookahead_i] != ' ' and self.line[lookahead_i] != '\t') {
                        continue :fsm .text;
                    }

                    contains_whitespace = true;
                }

                num_chars += 1;
                lookahead_i += 1;
            }

            if (char != '-' and char != '=' and num_chars < 3) {
                continue :fsm .text;
            }

            switch (char) {
                '*' => break :fsm .rule_star,
                '_' => break :fsm .rule_underline,
                '-' => {
                    if (contains_whitespace) {
                        break :fsm .rule_dash_with_whitespace;
                    } else {
                        break :fsm .rule_dash;
                    }
                },
                '=' => {
                    if (contains_whitespace) {
                        continue :fsm .text;
                    } else {
                        break :fsm .rule_equals;
                    }
                },
                else => unreachable,
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
                '\n', '#' => {
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

    const lexeme = try evaluate_lexeme(self, alloc, token_type, lookahead_i);
    const token = BlockToken{
        .token_type = token_type,
        .lexeme = lexeme,
    };

    self.i = lookahead_i;
    return token;
}

/// Constructs the lexeme given the token type and what we have scanned over.
fn evaluate_lexeme(
    self: *Self,
    alloc: Allocator,
    token_type: BlockTokenType,
    lookahead_i: usize,
) ![]const u8 {
    switch (token_type) {
        .newline, .indent, .rule_star, .rule_underline,
        .rule_dash_with_whitespace => {
            return ""; // no lexeme
        },
        .pound => {
            const lexeme = try alloc.dupe(
                u8,
                std.mem.trim(u8, self.line[self.i..lookahead_i], " \t"),
            );
            return lexeme;
        },
        else => {
            return try alloc.dupe(u8, self.line[self.i..lookahead_i]);
        },
    }
}


// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
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

    var reader: Io.Reader = .fixed(md);
    var buf: [512]u8 = undefined;
    const line_reader: LineReader = .{ .in = &reader, .buf = &buf };
    var tokenizer = Self.init(line_reader);

    const expected = [_]BlockTokenType{
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

    try std.testing.expect(try tokenizer.next(arena) == null);
}

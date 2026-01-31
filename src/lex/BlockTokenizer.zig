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
const util = @import("../util/util.zig");

pub const Error = error{
    /// Input reader did not have a large enough buffer to read a whole line.
    LineTooLong,
    /// Failure in reading from input stream.
    ReadFailed,
} || Allocator.Error;

const TokenizeResult = struct {
    token: BlockToken,
    next_i: usize,
};

reader: LineReader,
line: []const u8,
i: usize,                // current index into line

const Self = @This();

pub fn init(reader: LineReader) Self {
    return .{
        .reader = reader,
        .line = "",
        .i = 0,
    };
}

/// Get next token from the stream. Returns null when the stream is exhausted.
///
/// Caller is responsible for freeing memory associated with each returned
/// token. (The returned tokens own the memory used to store their lexemes.)
pub fn next(self: *Self, scratch: Allocator) Error!?BlockToken {
    // Load new input line when needed
    if (self.i >= self.line.len) {
        self.line = try self.reader.next() orelse return null;
        self.i = 0;
    }

    return try self.tokenize(scratch);
}

/// Returns the next token starting at the current index.
fn tokenize(self: *Self, scratch: Allocator) !BlockToken {
    const result: TokenizeResult = blk: {
        if (try self.matchPound(scratch)) |result| {
            break :blk result;
        }

        if (try self.matchNewline(scratch)) |result| {
            break :blk result;
        }

        if (try self.matchIndent(scratch)) |result| {
            break :blk result;
        }

        if (try self.matchRule(scratch)) |result| {
            break :blk result;
        }

        break :blk try self.matchText(scratch);
    };

    self.i = result.next_i;
    return result.token;
}

fn matchPound(self: Self, scratch: Allocator) !?TokenizeResult {
    var lookahead_i = self.i;

    const State = enum { start, rest };
    fsm: switch (State.start) {
        .start => {
            switch (self.line[lookahead_i]) {
                '#' => {
                    lookahead_i += 1;
                    continue :fsm .rest;
                },
                else => return null,
            }
        },
        .rest => {
            switch (self.line[lookahead_i]) {
                '#' => {
                    lookahead_i += 1;
                    continue :fsm .rest;
                },
                ' ', '\t', '\n' => break :fsm,
                else => return null,
            }
        },
    }

    const lexeme = try evaluate_lexeme(self, scratch, .pound, lookahead_i);
    const token = BlockToken{
        .token_type = .pound,
        .lexeme = lexeme,
    };
    return .{
        .token = token,
        .next_i = lookahead_i,
    };
}

fn matchNewline(self: Self, scratch: Allocator) !?TokenizeResult {
    if (self.line[self.i] != '\n') {
        return null;
    }

    const lexeme = try evaluate_lexeme(self, scratch, .newline, self.i + 1);
    const token = BlockToken{
        .token_type = .newline,
        .lexeme = lexeme,
    };
    return .{
        .token = token,
        .next_i = self.i + 1,
    };
}

fn matchIndent(self: Self, scratch: Allocator) !?TokenizeResult {
    if (self.i > 0) {
        // valid only at beginning of line
        return null;
    }

    var lookahead_i = self.i;
    loop: for (0..util.safety.loop_bound) |_| {
        switch (self.line[lookahead_i]) {
            '\t' => {
                lookahead_i += 1;
                break :loop;
            },
            ' ' => {
                lookahead_i += 1;
                if (lookahead_i - self.i == 4) {
                    break :loop;
                }

                continue :loop;
            },
            else => return null,
        }
    } else @panic(util.safety.loop_bound_panic_msg);

    const lexeme = try evaluate_lexeme(self, scratch, .indent, lookahead_i);
    const token = BlockToken{
        .token_type = .indent,
        .lexeme = lexeme,
    };
    return .{
        .token = token,
        .next_i = lookahead_i,
    };
}

/// Tokenize a rule line (later parsed into setext headings or thematic
/// breaks).
fn matchRule(self: Self, scratch: Allocator) !?TokenizeResult {
    if (self.i > 0) {
        // valid only at beginning of line
        return null;
    }

    var lookahead_i = self.i;

    // Up to three leading spaces allowed
    loop: for (0..util.safety.loop_bound) |_| {
        switch (self.line[lookahead_i]) {
            ' ' => {
                lookahead_i += 1;
            },
            else => break :loop,
        }
    } else @panic(util.safety.loop_bound_panic_msg);
    if (lookahead_i > 3) {
        return null;
    }

    const start_char = self.line[lookahead_i];
    var num_chars: u32 = 0;
    var contains_whitespace = false;

    while (self.line[lookahead_i] != '\n') {
        if (self.line[lookahead_i] == start_char) {
            num_chars += 1;
        } else {
            if (
                self.line[lookahead_i] != ' '
                and self.line[lookahead_i] != '\t'
            ) {
                return null;
            }

            contains_whitespace = true;
        }

        lookahead_i += 1;
    }

    if (start_char != '-' and start_char != '=' and num_chars < 3) {
        return null;
    }

    const token_type: BlockTokenType = switch (start_char) {
        '*' => .rule_star,
        '_' => .rule_underline,
        '-' => blk: {
            if (contains_whitespace) {
                break :blk .rule_dash_with_whitespace;
            } else {
                break :blk .rule_dash;
            }
        },
        '=' => blk: {
            if (contains_whitespace) {
                return null;
            } else {
                break :blk .rule_equals;
            }
        },
        else => return null,
    };

    const lexeme = try evaluate_lexeme(self, scratch, token_type, lookahead_i);
    const token = BlockToken{
        .token_type = token_type,
        .lexeme = lexeme,
    };
    return .{
        .token = token,
        .next_i = lookahead_i,
    };
}

fn matchText(self: Self, scratch: Allocator) !TokenizeResult {
    var lookahead_i = self.i;

    const State = enum { start, whitespace };
    fsm: switch (State.start) {
        .start => {
            switch (self.line[lookahead_i]) {
                '\n' => break :fsm,
                ' ', '\t' => continue :fsm .whitespace,
                else => {
                    lookahead_i += 1;
                    continue :fsm .start;
                },
            }
        },
        .whitespace => {
            switch (self.line[lookahead_i]) {
                '\n', '#' => break :fsm,
                ' ', '\t' => {
                    lookahead_i += 1;
                    continue :fsm .whitespace;
                },
                else => continue :fsm .start,
            }
        },
    }

    const lexeme = try evaluate_lexeme(self, scratch, .text, lookahead_i);
    const token = BlockToken{
        .token_type = .text,
        .lexeme = lexeme,
    };
    return .{
        .token = token,
        .next_i = lookahead_i,
    };
}

/// Constructs the lexeme given the token type and what we have scanned over.
fn evaluate_lexeme(
    self: Self,
    scratch: Allocator,
    token_type: BlockTokenType,
    lookahead_i: usize,
) ![]const u8 {
    std.debug.assert(lookahead_i - self.i > 0);

    switch (token_type) {
        .newline, .indent, .rule_star, .rule_underline,
        .rule_dash_with_whitespace => {
            return ""; // no lexeme
        },
        .pound => {
            const lexeme = try scratch.dupe(
                u8,
                std.mem.trim(u8, self.line[self.i..lookahead_i], " \t"),
            );
            return lexeme;
        },
        else => {
            return try scratch.dupe(u8, self.line[self.i..lookahead_i]);
        },
    }
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
fn expectEqualTokens(expected: []const BlockTokenType, md: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var reader: Io.Reader = .fixed(md);
    var buf: [512]u8 = undefined;
    const line_reader: LineReader = .{ .in = &reader, .buf = &buf };
    var tokenizer = Self.init(line_reader);

    for (expected) |exp| {
        const token = try tokenizer.next(scratch);
        try std.testing.expectEqual(exp, token.?.token_type);
    }

    try std.testing.expect(try tokenizer.next(scratch) == null);
}

test "pound paragraph" {
    const md =
        \\# Header
        \\## Subheader
        \\This is a paragraph.
        \\It has multiple lines.
        \\
        \\This is a new paragraph.
        \\
    ;

    try expectEqualTokens(&.{
        .pound, .text, .newline,
        .pound, .text, .newline,
        .text, .newline,
        .text, .newline,
        .newline,
        .text, .newline,
    }, md);
}

test "rule" {
    const md =
        \\***
        \\---
        \\___
        \\ ---
        \\  ---
        \\   ---
        \\==
        \\ -- --
        \\
    ;

    try expectEqualTokens(&.{
        .rule_star, .newline,
        .rule_dash, .newline,
        .rule_underline, .newline,
        .rule_dash, .newline,
        .rule_dash, .newline,
        .rule_dash, .newline,
        .rule_equals, .newline,
        .rule_dash_with_whitespace, .newline,
    }, md);
}

test "indent" {
    // Can't use \t in multiline string literal
    const md = "    a simple\n      space-indented block\n\n\ttab indent\n";
    try expectEqualTokens(&.{
        .indent, .text, .newline,
        .indent, .text, .newline,
        .newline,
        .indent, .text, .newline,
    }, md);
}

//! Takes an input reader and tokenizes line by line.
const std = @import("std");
const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const DelimiterError = Io.Reader.DelimiterError;
const ArrayList = std.ArrayList;

const Token = @import("tokens.zig").Token;
const TokenType = @import("tokens.zig").TokenType;

pub const Error = error{
    LineTooLong,
    ReadFailed,
} || Allocator.Error;

const State = enum{
    started,
    pound,
    text,
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
pub fn next(self: *Self, alloc: Allocator) Error!Token {
    // Load new input line when needed
    while (self.i >= self.line.len) {
        self.line = read_line(self.in) catch |err| {
            switch (err) {
                DelimiterError.EndOfStream => {
                    return Token{ .token_type = .eof };
                },
                DelimiterError.StreamTooLong => {
                    return Error.LineTooLong;
                },
                else => |e| return e,
            }
        };
        self.i = 0;
    }

    return try self.scan(alloc);
}

// Returns the next token starting at the current index.
fn scan(self: *Self, alloc: Allocator) Allocator.Error!Token {
    var lookahead_i = self.i;
    const token_type: TokenType = fsm: switch (self.state) {
        .started => {
            const c = self.peek(lookahead_i) orelse break :fsm .newline;
            switch (c) {
                '#' => {
                    continue :fsm .pound;
                },
                ' ', '\t' => {
                    self.i += 1;
                    lookahead_i = self.i;
                    continue :fsm .started;
                },
                '\n' => {
                    self.i += 1;
                    lookahead_i = self.i;
                    break :fsm .newline;
                },
                else => {
                    continue :fsm .text;
                },
            }
        },
        .pound => {
            const c = self.peek(lookahead_i) orelse {
                lookahead_i = self.i;
                continue :fsm .text;
            };
            switch (c) {
                '#' => {
                    lookahead_i += 1;
                    continue :fsm .pound;
                },
                ' ', '\t'...'\r' => {
                    break :fsm .pound;
                },
                else => {
                    lookahead_i = self.i;
                    continue :fsm .text;
                },
            }
        },
        .text => {
            const c = self.peek(lookahead_i) orelse break :fsm .text;
            switch (c) {
                '\n' => {
                    break :fsm .text;
                },
                else => {
                    lookahead_i += 1;
                    continue :fsm .text;
                },
            }
        }
    };

    const token: Token = blk: {
        if (lookahead_i == self.i) {
            break :blk .{ .token_type = token_type };
        }

        const lexeme = try alloc.dupe(u8, self.line[self.i..lookahead_i]);
        break :blk .{ .token_type = token_type, .lexeme = lexeme };
    };

    self.i = lookahead_i;
    return token;
}

fn peek(self: Self, index: usize) ?u8 {
    if (index >= self.line.len) {
        return null;
    }

    return self.line[index];
}

// Reads the next line from the input stream.
fn read_line(in: *Io.Reader) DelimiterError![]const u8 {
    const line = in.takeDelimiterInclusive('\n') catch |err| {
        switch (err) {
            DelimiterError.EndOfStream => {
                return try in.takeDelimiterExclusive('\n');
            },
            else => return err,
        }
    };
    return line;
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
        .eof,
    };

    for (expected) |exp| {
        const token = try tokenizer.next(arena);
        try std.testing.expectEqual(exp, token.token_type);
    }
}

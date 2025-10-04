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
} || Allocator.Error;

const State = enum{
    started,
    pound,
    text,
    done,
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
pub fn next(self: *Self, alloc: Allocator) Error!?Token {
    if (self.state == .done) {
        return null;
    }

    // Load new input line when needed
    while (self.i >= self.line.len) {
        self.line = read_line(alloc, self.in) catch |err| {
            switch (err) {
                DelimiterError.EndOfStream => {
                    self.state = .done;
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

// Reads the next line from the input stream.
//
// Line will always be terminated by a newline character.
fn read_line(alloc: Allocator, in: *Io.Reader) ![]const u8 {
    const line = in.takeDelimiterInclusive('\n') catch |err| {
        switch (err) {
            DelimiterError.EndOfStream => {
                return try in.takeDelimiterExclusive('\n');
            },
            else => return err,
        }
    };

    std.debug.assert(line.len >= 1);
    if (line[line.len - 1] != '\n') {
        return fmt.allocPrint(alloc, "{s}\n", .{ line });
    }

    return line;
}

// Returns the next token starting at the current index.
fn scan(self: *Self, alloc: Allocator) Allocator.Error!Token {
    var lookahead_i = self.i;
    const token_type: TokenType = fsm: switch (self.state) {
        .done => unreachable,
        .started => {
            switch (self.line[lookahead_i]) {
                '#' => {
                    continue :fsm .pound;
                },
                ' ', '\t' => {
                    self.i += 1;
                    lookahead_i += 1;
                    continue :fsm .started;
                },
                '\n' => {
                    lookahead_i += 1;
                    break :fsm .newline;
                },
                '\\' => {
                    lookahead_i += 1;
                    break :fsm .backslash;
                },
                else => {
                    continue :fsm .text;
                },
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
        .text => {
            switch (self.line[lookahead_i]) {
                '\n', '\\', '#' => {
                    break :fsm .text;
                },
                else => {
                    lookahead_i += 1;
                    continue :fsm .text;
                },
            }
        },
    };

    const lexeme = try evaluate_lexeme(self, alloc, token_type, lookahead_i);
    const token = Token{
        .token_type = token_type,
        .lexeme = lexeme,
    };

    self.i = lookahead_i;
    return token;
}

fn evaluate_lexeme(
    self: *Self,
    alloc: Allocator,
    token_type: TokenType,
    lookahead_i: usize,
) !?[]const u8 {
    switch (token_type) {
        .backslash, .newline => {
            return null;
        },
        else => {
            return try alloc.dupe(u8, self.line[self.i..lookahead_i]);
        },
    }
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
        try std.testing.expectEqual(exp, token.?.token_type);
    }
}

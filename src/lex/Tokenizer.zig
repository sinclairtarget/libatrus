//! Takes an input reader and tokenizes line by line.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const DelimiterError = Io.Reader.DelimiterError;
const ArrayList = std.ArrayList;

const Token = @import("tokens.zig").Token;
const TokenType = @import("tokens.zig").TokenType;

pub const Error = error{
    LineTooLong,
};

pub const State = enum {
    not_started,
    started,
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
        .state = .not_started,
    };
}

// Get next token from the stream.
//
// Caller responsible for freeing memory associated with tokens.
pub fn next(self: *Self, alloc: Allocator) !Token {
    if (self.i >= self.line.len) {
        const should_emit_newline = self.state != .not_started;
        self.line = read_line(self.in) catch |err| {
            switch (err) {
                DelimiterError.EndOfStream => {
                    return Token{ .token_type = .eof };
                },
                DelimiterError.StreamTooLong => {
                    return Error.LineTooLong;
                },
                else => {
                    return err;
                },
            }
        };
        self.i = 0;
        self.state = .started;

        if (should_emit_newline) {
            return Token{ .token_type = .newline };
        }
    }

    const c = self.line[self.i];
    const token_type: TokenType = switch (c) {
        '#' => .pound,
        else => .text,
    };

    const value, const advance_to = try self.evaluate(alloc, token_type);
    self.i = advance_to;
    return Token{ .token_type = token_type, .value = value };
}

// Produces the value for the given token type by advancing through the current
// line.
//
// Returns the value for the token (if there is one) and the index to which we
// should advance.
fn evaluate(
    self: Self,
    alloc: Allocator,
    token_type: TokenType,
) !struct { ?[]const u8, usize } {
    switch (token_type) {
        .text => {
            const value = try alloc.dupe(u8, self.line[self.i..]);
            const trimmed_value = std.mem.trim(u8, value, " ");
            return .{ trimmed_value, self.line.len };
        },
        else => {
            return .{ null, self.i + 1 };
        },
    }
}

// Reads the next line from the input stream.
fn read_line(in: *Io.Reader) DelimiterError![]const u8 {
    return try in.takeDelimiterExclusive('\n');
}

const md =
    \\# Header
    \\## Subheader
    \\This is a paragraph.
    \\It has multiple lines.
    \\
    \\This is a new paragraph.
    \\
;

test "can tokenize example" {
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
        .pound,
        .text,
        .newline,
        .text,
        .newline,
        .text,
        .newline,
        .newline,
        .text,
        .eof,
    };

    for (expected) |exp| {
        const token = try tokenizer.next(arena);
        try std.testing.expectEqual(exp, token.token_type);
    }
}

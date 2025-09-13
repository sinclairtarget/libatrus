//! Takes an input reader and tokenizes line by line.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const DelimiterError = Io.Reader.DelimiterError;
 
const tokens = @import("tokens.zig");
const Token = tokens.Token;

pub const Error = error {
    LineTooLong,
};

in: *Io.Reader,
alloc: Allocator,
line: []const u8,
i: u16,

const Self = @This();

pub fn init(alloc: Allocator, in: *Io.Reader) Self {
    return .{
        .in = in,
        .alloc = alloc,
        .line = "",
        .i = 0,
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
    return;
}

// Get next token from the stream.
pub fn next(self: *Self) !Token {
    if (self.i >= self.line.len) {
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
    }

    self.i = @truncate(self.line.len);
    return Token{ .token_type = .text, .value = "Foo" };
}

// Reads the next line from the input stream.
fn read_line(in: *Io.Reader) DelimiterError![]const u8 {
    return try in.takeDelimiterExclusive('\n');
}

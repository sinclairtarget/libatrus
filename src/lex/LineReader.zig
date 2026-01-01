//! Iterator over lines from an input reader.
//!
//! Lines can be delimited by \n, \r, \r\n, or EOF.
//!
//! Each returned line is normalized such that it ends with a \n.
const std = @import("std");
const Io = std.Io;

pub const Error = error{
    LineTooLong,
    ReadFailed,
};

const State = enum {
    normal,
    carriage_return,
};

in: *Io.Reader,
buf: []u8,        // Scratch memory holding the modified next line

const Self = @This();

/// Returns the next line.
///
/// If there is no next line, returns null.
///
/// The previous line is invalidated.
pub fn next(self: Self) Error!?[]const u8 {
    var i: usize = 0;
    var state: State = .normal;
    loop: while (self.in.peekByte()) |b| {
        if (i >= self.buf.len) {
            return Error.LineTooLong;
        }

        switch (state) {
            .normal => {
                switch (b) {
                    '\n' => {
                        self.buf[i] = b;
                        i += 1;
                        self.in.toss(1);
                        break :loop;
                    },
                    '\r' => {
                        self.in.toss(1);
                        state = .carriage_return;
                    },
                    else => {
                        self.buf[i] = b;
                        i += 1;
                        self.in.toss(1);
                    },
                }
            },
            .carriage_return => {
                switch (b) {
                    '\n' => {
                        self.buf[i] = '\n';
                        i += 1;
                        self.in.toss(1);
                    },
                    else => {
                        // Write newline without consuming `b`
                        self.buf[i] = '\n';
                        i += 1;
                    },
                }

                state = .normal;
                break :loop;
            },
        }
    } else |err| {
        switch (err) {
            Io.Reader.Error.EndOfStream => {
                if (i == 0) {
                    return null;
                }

                // Make sure to end line with '\n' after hitting EOF
                self.buf[i] = '\n';
                i += 1;
            },
            else => |e| return e,
        }
    }

    // Since all lines end at least in '\n', we should never return an empty
    // line.
    std.debug.assert(i > 0);
    return self.buf[0..i]; // Returns next line
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

test "mixed line endings" {
    const md = "first\nsecond\rthird\r\nfourth\n";

    var reader: Io.Reader = .fixed(md);
    var buf: [16]u8 = undefined;
    var line_reader = Self{
        .in = &reader,
        .buf = &buf,
    };

    try testing.expectEqualStrings("first\n", (try line_reader.next()).?);
    try testing.expectEqualStrings("second\n", (try line_reader.next()).?);
    try testing.expectEqualStrings("third\n", (try line_reader.next()).?);
    try testing.expectEqualStrings("fourth\n", (try line_reader.next()).?);
}

test "eof" {
    const md = "first\nsecond";

    var reader: Io.Reader = .fixed(md);
    var buf: [16]u8 = undefined;
    var line_reader = Self{
        .in = &reader,
        .buf = &buf,
    };

    try testing.expectEqualStrings("first\n", (try line_reader.next()).?);
    try testing.expectEqualStrings("second\n", (try line_reader.next()).?);
}

test "line too long error" {
    const md = "supercalifragalisticespcialidocious\n";

    var reader: Io.Reader = .fixed(md);
    var buf: [16]u8 = undefined;
    var line_reader = Self{
        .in = &reader,
        .buf = &buf,
    };

    try testing.expectError(Error.LineTooLong, line_reader.next());
}

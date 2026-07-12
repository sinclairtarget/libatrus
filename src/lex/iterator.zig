const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Token = @import("tokens.zig").Token;
const BlockTokenType = @import("tokens.zig").BlockTokenType;
const whitespaceLen = @import("tokens.zig").whitespaceLen;

pub const Error = error{
    LineTooLong,
    ReadFailed,
    WriteFailed,
} || Allocator.Error;

/// An interface for iterating over a token stream.
///
/// Has an unbounded buffer to allow for backtracking.
pub fn TokenIterator(comptime TokenType: type) type {
    return struct {
        ctx: *anyopaque,
        nextFn: *const fn (*anyopaque, Allocator) Error!?Token(TokenType),
        tokens: ArrayList(Token(TokenType)),
        token_index: usize,
        is_exhausted: bool = false,

        const Self = @This();

        pub fn init(
            ctx: *anyopaque,
            nextFn: *const fn (*anyopaque, Allocator) Error!?Token(TokenType),
        ) Self {
            return .{
                .ctx = ctx,
                .nextFn = nextFn,
                .tokens = .empty,
                .token_index = 0,
            };
        }

        pub fn peek(self: *Self, scratch: Allocator) !?Token(TokenType) {
            return self.peekAhead(scratch, 1);
        }

        /// Should be used for looking ahead a fixed amount only.
        pub fn peekAhead(
            self: *Self,
            scratch: Allocator,
            comptime count: u16,
        ) !?Token(TokenType) {
            const index = self.token_index + (count - 1);
            while (index >= self.tokens.items.len) {
                if (self.is_exhausted) {
                    return null;
                }

                const next = try self.nextFn(self.ctx, scratch) orelse {
                    // end of stream
                    self.is_exhausted = true;
                    return null;
                };
                try self.tokens.append(scratch, next);
            }

            return self.tokens.items[index];
        }

        pub fn consume(
            self: *Self,
            scratch: Allocator,
            token_types: []const TokenType,
        ) !?Token(TokenType) {
            const current = try self.peek(scratch) orelse return null;
            for (token_types) |token_type| {
                if (current.token_type == token_type) {
                    self.token_index += 1;
                    return current;
                }
            }

            return null;
        }

        /// Consumes consecutive spaces and tabs.
        ///
        /// Returns the length of whitespace consumed (in spaces).
        ///
        /// Tabs count for between 0 and 4 spaces depending on their position
        /// relative to the next tab stop.
        pub fn consumeWhitespace(
            self: *TokenIterator(BlockTokenType),
            scratch: Allocator,
        ) ![]Token(BlockTokenType) {
            return try self.consumeWhitespaceUpTo(
                scratch,
                std.math.maxInt(usize),
            );
        }

        /// Consumes spaces or tabs up to the given length in spaces.
        ///
        /// Returns the length of whitespace consumed (in spaces).
        ///
        /// Tabs count for between 0 and 4 spaces depending on their position
        /// relative to the next tab stop. If a tab counts for more spaces than
        /// we can consume within the given length, then the tab is replaced by
        /// spaces in the token stream and only the spaces that fit within the
        /// length are consumed (the tab gets split).
        pub fn consumeWhitespaceUpTo(
            self: *TokenIterator(BlockTokenType),
            scratch: Allocator,
            len: usize,
        ) ![]Token(BlockTokenType) {
            var ws_tokens: ArrayList(Token(BlockTokenType)) = .empty;

            var len_consumed: usize = 0;
            while (len_consumed < len) {
                const token = try self.peek(scratch) orelse break;
                switch (token.token_type) {
                    .space => {
                        _ = try self.consume(scratch, &.{.space});
                        try ws_tokens.append(scratch, token);
                        len_consumed += 1;
                    },
                    .tab => {
                        _ = try self.consume(scratch, &.{.tab});

                        const tab_len = whitespaceLen(&.{token});
                        const tab_len_consumed = @min(
                            tab_len,
                            len - len_consumed,
                        );

                        if (tab_len_consumed == 4) {
                            try ws_tokens.append(scratch, token);
                        } else {
                            // split tab into spaces
                            for (0..tab_len_consumed) |_| {
                                try ws_tokens.append(scratch, .{
                                    .token_type = .space,
                                    .lexeme = " ",
                                });
                            }
                            for (0..(tab_len - tab_len_consumed)) |_| {
                                try self.tokens.append(scratch, .{
                                    .token_type = .space,
                                    .lexeme = " ",
                                });
                            }
                        }

                        len_consumed += tab_len_consumed;
                    },
                    else => break,
                }
            }

            return ws_tokens.toOwnedSlice(scratch);
        }

        pub fn clearConsumed(self: *Self) void {
            if (self.token_index == 0) {
                return; // no tokens to clear
            }

            std.debug.assert(self.tokens.items.len > 0);

            // Copy unconsumed tokens to beginning of list
            // Is there a way to do this with ArrayList's API? I haven't been
            // able to figure it out.
            const unparsed = self.tokens.items[self.token_index..];
            @memmove(self.tokens.items[0..unparsed.len], unparsed);
            self.tokens.shrinkRetainingCapacity(unparsed.len);
            self.token_index = 0;
        }

        pub fn checkpoint(self: *Self) usize {
            return self.token_index;
        }

        pub fn backtrack(self: *Self, checkpoint_index: usize) void {
            std.debug.assert(checkpoint_index <= self.token_index);
            while (self.token_index > checkpoint_index) {
                self.token_index -= 1;

                const token = self.tokens.items[self.token_index];
                if (token.token_type == .tab) {
                    // Remove all spaces after tab
                    var sorted_indexes: [4]usize = undefined;
                    var sorted_indexes_i: usize = 0;
                    const end = @min(
                        self.token_index + 5,
                        self.tokens.items.len,
                    );
                    for (self.token_index + 1..end) |i| {
                        if (self.tokens.items[i].token_type != .space) {
                            break;
                        }

                        sorted_indexes[sorted_indexes_i] = i;
                        sorted_indexes_i += 1;
                    }

                    self.tokens.orderedRemoveMany(
                        sorted_indexes[0..sorted_indexes_i],
                    );
                }
            }
        }
    };
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

/// An iterable slice of tokens.
pub fn TokenSliceStream(comptime TokenType: type) type {
    return struct {
        slice: []const Token(TokenType),
        token_index: usize,

        const Self = @This();

        pub fn init(slice: []const Token(TokenType)) Self {
            return .{
                .slice = slice,
                .token_index = 0,
            };
        }

        pub fn iterator(self: *Self) TokenIterator(TokenType) {
            return TokenIterator(TokenType).init(self, &next);
        }

        fn next(ctx: *anyopaque, scratch: Allocator) !?Token(TokenType) {
            _ = scratch;
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.token_index >= self.slice.len) {
                return null;
            }

            defer self.token_index += 1;
            return self.slice[self.token_index];
        }
    };
}

fn expectEqualTokens(
    expected: []const BlockTokenType,
    tokens: []Token(BlockTokenType),
) !void {
    try testing.expectEqual(expected.len, tokens.len);

    for (expected, tokens) |exp, token| {
        try testing.expectEqual(exp, token.token_type);
    }
}

test "consume tab" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var stream = TokenSliceStream(BlockTokenType).init(&.{
        .{
            .token_type = .tab,
            .lexeme = "\t",
        },
    });
    var it = stream.iterator();

    const tokens = try it.consumeWhitespaceUpTo(scratch, 4);
    try expectEqualTokens(&.{.tab}, tokens);
}

test "consume spaces and split tab" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var stream = TokenSliceStream(BlockTokenType).init(&.{
        .{
            .token_type = .space,
            .lexeme = " ",
        },
        .{
            .token_type = .space,
            .lexeme = " ",
        },
        .{
            .token_type = .tab,
            .lexeme = "\t",
        },
    });
    var it = stream.iterator();

    const tokens = try it.consumeWhitespaceUpTo(scratch, 4);
    try expectEqualTokens(&.{ .space, .space, .space, .space }, tokens);

    const trailing_tokens = try it.consumeWhitespaceUpTo(scratch, 2);
    try expectEqualTokens(&.{ .space, .space }, trailing_tokens);
}

test "backtrack over split tab" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var stream = TokenSliceStream(BlockTokenType).init(&.{
        .{
            .token_type = .space,
            .lexeme = " ",
        },
        .{
            .token_type = .tab,
            .lexeme = "\t",
        },
    });
    var it = stream.iterator();

    // consumes space and one "space" from the tab
    const tokens = try it.consumeWhitespaceUpTo(scratch, 2);
    try expectEqualTokens(&.{ .space, .space }, tokens);

    const checkpoint_index = it.checkpoint();

    // consumes the remaining "spaces" from the tab
    var trailing_tokens = try it.consumeWhitespaceUpTo(scratch, 3);
    try expectEqualTokens(&.{ .space, .space, .space }, trailing_tokens);

    // now the stream should be empty
    trailing_tokens = try it.consumeWhitespaceUpTo(scratch, 1);
    try testing.expectEqual(0, trailing_tokens.len);

    // backtrack to the checkpoint, we should still have the last three spaces
    // of the split tab in the stream
    it.backtrack(checkpoint_index);
    trailing_tokens = try it.consumeWhitespaceUpTo(scratch, 3);
    try expectEqualTokens(&.{ .space, .space, .space }, trailing_tokens);

    // backtrack to beginning, original tab is no longer split
    it.backtrack(0);
    trailing_tokens = try it.consumeWhitespaceUpTo(scratch, 6);
    try expectEqualTokens(&.{ .space, .tab }, trailing_tokens);
}

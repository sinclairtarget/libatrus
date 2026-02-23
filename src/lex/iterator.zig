const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Token = @import("tokens.zig").Token;

pub const Error = error {
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
            nextFn: *const fn(*anyopaque, Allocator) Error!?Token(TokenType),
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

        pub fn clearConsumed(self: *Self) void {
            if (self.token_index == 0) {
                return; // no tokens to clear
            }

            std.debug.assert(self.tokens.items.len > 0);

            // Copy unconsumed tokens to beginning of list
            const unparsed = self.tokens.items[self.token_index..];
            self.tokens.replaceRangeAssumeCapacity(
                0,
                self.tokens.items.len,
                unparsed,
            );
            self.token_index = 0;
        }

        pub fn checkpoint(self: *Self) usize {
            return self.token_index;
        }

        pub fn backtrack(self: *Self, checkpoint_index: usize) void {
            std.debug.assert(checkpoint_index <= self.token_index);
            self.token_index = checkpoint_index;
        }
    };
}

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

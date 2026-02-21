const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error {
    LineTooLong,
    ReadFailed,
    WriteFailed,
} || Allocator.Error;

pub fn TokenIterator(comptime T: type) type {
    return struct {
        ctx: *anyopaque,
        nextFn: *const fn (*anyopaque, Allocator) Error!?T,

        pub fn next(self: @This(), allocator: Allocator) !?T {
            return self.nextFn(self.ctx, allocator);
        }
    };
}

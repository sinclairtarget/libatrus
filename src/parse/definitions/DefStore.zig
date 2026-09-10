//! Container for link and footnote storage.

const std = @import("std");
const Allocator = std.mem.Allocator;

const LinkDefMap = @import("links.zig").DefMap;

links: LinkDefMap,

const Self = @This();

pub const empty: Self = .{
    .links = .empty,
};

pub fn deinit(self: *Self, alloc: Allocator) void {
    self.links.deinit(alloc);
}

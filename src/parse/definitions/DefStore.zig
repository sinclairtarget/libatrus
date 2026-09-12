//! Container for link and footnote storage.

const std = @import("std");
const Allocator = std.mem.Allocator;

const LinkDefMap = @import("links.zig").DefMap;
const FootnoteDefMap = @import("footnotes.zig").DefMap;

links: LinkDefMap,
footnotes: FootnoteDefMap,

const Self = @This();

pub const empty: Self = .{
    .links = .empty,
    .footnotes = .empty,
};

pub fn deinit(self: *Self, alloc: Allocator) void {
    self.links.deinit(alloc);
    self.footnotes.deinit(alloc);
}

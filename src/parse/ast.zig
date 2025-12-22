//! Abstract syntax tree for a MyST document.
//!
//! https://mystmd.org/spec

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const NodeType = enum {
    root,
    block,
    heading,
    paragraph,
    text,
    code,
    thematic_break,
    emphasis,
    strong,
};

pub const Node = union(NodeType) {
    root: Root,
    block: Container,
    heading: Heading,
    paragraph: Container,
    text: Text,
    code: Code,
    thematic_break: Empty,
    emphasis: Container,
    strong: Container,

    const Self = @This();

    pub fn deinit(self: *Self, alloc: Allocator) void {
        switch (self.*) {
            .thematic_break => {},
            inline else => |*payload| payload.deinit(alloc),
        }

        alloc.destroy(self);
    }
};

pub const Root = struct {
    children: []*Node,
    is_post_processed: bool = false,

    const Self = @This();

    pub fn deinit(self: *Self, alloc: Allocator) void {
        for (self.children) |child| {
            child.deinit(alloc);
        }
        alloc.free(self.children);
    }
};

pub const Container = struct {
    children: []*Node,

    const Self = @This();

    pub fn deinit(self: *Self, alloc: Allocator) void {
        for (self.children) |child| {
            child.deinit(alloc);
        }
        alloc.free(self.children);
    }
};

pub const Heading = struct {
    depth: u8,
    children: []*Node,

    const Self = @This();

    pub fn deinit(self: *Self, alloc: Allocator) void {
        for (self.children) |child| {
            child.deinit(alloc);
        }
        alloc.free(self.children);
    }
};

pub const Text = struct {
    value: []const u8,

    const Self = @This();

    pub fn deinit(self: *Self, alloc: Allocator) void {
        alloc.free(self.value);
    }
};

pub const Code = struct {
    value: []const u8,
    lang: []const u8,

    const Self = @This();

    pub fn deinit(self: *Self, alloc: Allocator) void {
        alloc.free(self.value);
        alloc.free(self.lang);
    }
};

pub const Empty = struct {};

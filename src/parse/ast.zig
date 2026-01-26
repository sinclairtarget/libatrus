//! Abstract syntax tree for a MyST document.
//!
//! https://mystmd.org/spec

const std = @import("std");
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
    inline_code,
    link,
    definition, // link definition
    image,
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
    inline_code: Text,
    link: Link,
    definition: LinkDefinition,
    image: Image,

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

pub const Link = struct {
    url: []const u8,
    title: []const u8,
    children: []*Node,

    const Self = @This();

    pub fn deinit(self: *Self, alloc: Allocator) void {
        for (self.children) |child| {
            child.deinit(alloc);
        }
        alloc.free(self.children);

        alloc.free(self.url);
        alloc.free(self.title);
    }
};

pub const LinkDefinition = struct {
    url: []const u8,
    title: []const u8,
    label: []const u8,

    const Self = @This();

    pub fn deinit(self: *Self, alloc: Allocator) void {
        alloc.free(self.url);
        alloc.free(self.title);
        alloc.free(self.label);
    }
};

pub const Image = struct {
    url: []const u8,
    title: []const u8,
    alt: []const u8,

    const Self = @This();

    pub fn deinit(self: *Self, alloc: Allocator) void {
        alloc.free(self.url);
        alloc.free(self.title);
        alloc.free(self.alt);
    }
};

pub const Empty = struct {};

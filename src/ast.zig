//! Abstract syntax tree for a MyST document.
//!
//! See https://mystmd.org/spec
//!
//! The AST is defined as "extern" because it is exposed via the libatrus
//! C API. The data structures defined here must be kept in sync with the C
//! data structures in atrus.h.
//!
//! Because "extern" data structures need to have a defined memory layout,
//! some useful Zig features are prohibited here: slices and (automatically)
//! tagged unions.

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
    @"break",       // line break
    emphasis,
    strong,
    inline_code,
    link,
    definition,     // link definition
    image,
    blockquote,
};

pub const Node = union(NodeType) {
    root: Root,
    block: Container,
    heading: Heading,
    paragraph: Container,
    text: Text,
    code: Code,
    thematic_break: void,
    @"break": void,
    emphasis: Container,
    strong: Container,
    inline_code: Text,
    link: Link,
    definition: LinkDefinition,
    image: Image,
    blockquote: Container,

    const Self = @This();

    pub fn deinit(self: *Self, alloc: Allocator) void {
        switch (self.*) {
            .thematic_break, .@"break" => {},
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

pub const Text = extern struct {
    value: [*:0]const u8,

    pub fn deinit(self: *Text, alloc: Allocator) void {
        alloc.free(std.mem.span(self.value));
    }
};

pub const Code = extern struct {
    value: [*:0]const u8,
    lang: [*:0]const u8,

    pub fn deinit(self: *Code, alloc: Allocator) void {
        alloc.free(std.mem.span(self.value));
        alloc.free(std.mem.span(self.lang));
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

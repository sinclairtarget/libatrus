//! Abstract syntax tree for a MyST document.
//!
//! See https://mystmd.org/spec
//!
//! The data structures comprising the AST are defined as "extern" because they
//! are exposed via the libatrus C API. They must be kept in sync with the C
//! data structures in atrus.h.
//!
//! Because "extern" data structures need to have a defined memory layout, some
//! useful Zig features are prohibited here, in particular slices and
//! (automatically) tagged unions.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const NodeType = enum(c_uint) {
    root = 0,
    block = 1,
    heading = 2,
    paragraph = 3,
    text = 4,
    code = 5,
    thematic_break = 6,
    @"break" = 7,       // line break
    emphasis = 8,
    strong = 9,
    inline_code = 10,
    link = 11,
    definition = 12,     // link definition
    image = 13,
    blockquote = 14,
};

pub const Node = extern struct {
    payload: extern union {
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
    },
    tag: NodeType,

    pub fn deinit(self: *Node, alloc: Allocator) void {
        switch (self.tag) {
            .thematic_break, .@"break" => {},
            inline else => |node_type| {
                var n = @field(self.payload, @tagName(node_type));
                n.deinit(alloc);
            },
        }

        alloc.destroy(self);
    }
};

pub const Root = extern struct {
    children: [*]*Node,
    n_children: c_uint,

    pub fn deinit(self: *Root, alloc: Allocator) void {
        const sliced = self.children[0..self.n_children];
        for (sliced) |child| {
            child.deinit(alloc);
        }
        alloc.free(sliced);
    }
};

pub const Container = extern struct {
    children: [*]*Node,
    n_children: c_uint,

    pub fn deinit(self: *Container, alloc: Allocator) void {
        const sliced = self.children[0..self.n_children];
        for (sliced) |child| {
            child.deinit(alloc);
        }
        alloc.free(sliced);
    }
};

pub const Heading = extern struct {
    children: [*]*Node,
    n_children: c_uint,
    depth: c_ushort,    // Headings cannot be deeper than six levels

    pub fn deinit(self: *Heading, alloc: Allocator) void {
        const sliced = self.children[0..self.n_children];
        for (sliced) |child| {
            child.deinit(alloc);
        }
        alloc.free(sliced);
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

pub const Link = extern struct {
    url: [*:0]const u8,
    title: [*:0]const u8,
    children: [*]*Node,
    n_children: c_uint,

    pub fn deinit(self: *Link, alloc: Allocator) void {
        const sliced = self.children[0..self.n_children];
        for (sliced) |child| {
            child.deinit(alloc);
        }
        alloc.free(sliced);

        alloc.free(std.mem.span(self.url));
        alloc.free(std.mem.span(self.title));
    }
};

pub const LinkDefinition = extern struct {
    url: [*:0]const u8,
    title: [*:0]const u8,
    label: [*:0]const u8,

    pub fn deinit(self: *LinkDefinition, alloc: Allocator) void {
        alloc.free(std.mem.span(self.url));
        alloc.free(std.mem.span(self.title));
        alloc.free(std.mem.span(self.label));
    }
};

pub const Image = extern struct {
    url: [*:0]const u8,
    title: [*:0]const u8,
    alt: [*:0]const u8,

    pub fn deinit(self: *Image, alloc: Allocator) void {
        alloc.free(std.mem.span(self.url));
        alloc.free(std.mem.span(self.title));
        alloc.free(std.mem.span(self.alt));
    }
};

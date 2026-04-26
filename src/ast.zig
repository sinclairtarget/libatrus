//! Abstract syntax tree for a MyST document.
//!
//! See https://mystmd.org/spec
//!
//! The data structures comprising the AST are defined as "extern" because they
//! are exposed via the libatrus C API. Their definitions must be kept in sync
//! with the C data structures defined in atrus.h.
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
    definition = 12,    // link definition
    image = 13,
    blockquote = 14,
    html = 15,          // either an HTML block or a single inline HTML tag
    container = 25,
    // built-in roles
    myst_role = 16,
    myst_role_error = 17,
    subscript = 18,
    superscript = 19,
    abbreviation = 20,
    // built-in directives
    myst_directive = 21,
    myst_directive_error = 22,
    admonition = 23,
    admonition_title = 24,
};

pub const Node = extern struct {
    payload: extern union {
        root: Root,
        block: Wrapper,
        heading: Heading,
        paragraph: Wrapper,
        text: Text,
        code: Code,
        thematic_break: void,
        @"break": void,
        emphasis: Wrapper,
        strong: Wrapper,
        inline_code: Text,
        link: Link,
        definition: LinkDefinition,
        image: Image,
        blockquote: Wrapper,
        html: Text,
        container: Container,
        myst_role: MySTRole,
        myst_role_error: MySTRoleError,
        subscript: Wrapper,
        superscript: Wrapper,
        abbreviation: Abbreviation,
        myst_directive: MySTDirective,
        myst_directive_error: MySTDirectiveError,
        admonition: Admonition,
        admonition_title: Wrapper,
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

pub const Wrapper = extern struct {
    children: [*]*Node,
    n_children: c_uint,

    pub fn deinit(self: *Wrapper, alloc: Allocator) void {
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
    children: [*]*Node,
    n_children: c_uint,
    url: [*:0]const u8,
    title: [*:0]const u8,

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

pub const MySTRole = extern struct {
    children: [*]*Node,
    n_children: c_uint,
    name: [*:0]const u8,
    value: [*:0]const u8,

    pub fn deinit(self: *MySTRole, alloc: Allocator) void {
        const sliced = self.children[0..self.n_children];
        for (sliced) |child| {
            child.deinit(alloc);
        }
        alloc.free(sliced);

        alloc.free(std.mem.span(self.name));
        alloc.free(std.mem.span(self.value));
    }
};

pub const MySTRoleError = extern struct {
    value: [*:0]const u8,

    pub fn deinit(self: *MySTRoleError, alloc: Allocator) void {
        alloc.free(std.mem.span(self.value));
    }
};

pub const Abbreviation = extern struct {
    children: [*]*Node,
    n_children: c_uint,
    title: [*:0]const u8,

    pub fn deinit(self: *Abbreviation, alloc: Allocator) void {
        const sliced = self.children[0..self.n_children];
        for (sliced) |child| {
            child.deinit(alloc);
        }
        alloc.free(sliced);

        alloc.free(std.mem.span(self.title));
    }
};

pub const MySTDirective = extern struct {
    children: [*]*Node,
    n_children: c_uint,
    name: [*:0]const u8,
    args: [*:0]const u8,
    value: [*:0]const u8,

    pub fn deinit(self: *MySTDirective, alloc: Allocator) void {
        const sliced = self.children[0..self.n_children];
        for (sliced) |child| {
            child.deinit(alloc);
        }
        alloc.free(sliced);

        alloc.free(std.mem.span(self.name));
        alloc.free(std.mem.span(self.args));
        alloc.free(std.mem.span(self.value));
    }
};

pub const MySTDirectiveError = extern struct {
    children: [*]*Node,
    n_children: c_uint,
    message: [*:0]const u8,

    pub fn deinit(self: *MySTDirectiveError, alloc: Allocator) void {
        const sliced = self.children[0..self.n_children];
        for (sliced) |child| {
            child.deinit(alloc);
        }
        alloc.free(sliced);

        alloc.free(std.mem.span(self.message));
    }
};

pub const Admonition = extern struct {
    children: [*]*Node,
    n_children: c_uint,
    kind: [*:0]const u8,

    pub fn deinit(self: *Admonition, alloc: Allocator) void {
        const sliced = self.children[0..self.n_children];
        for (sliced) |child| {
            child.deinit(alloc);
        }
        alloc.free(sliced);

        alloc.free(std.mem.span(self.kind));
    }
};

pub const Container = extern struct {
    children: [*]*Node,
    n_children: c_uint,
    kind: [*:0]const u8,

    pub fn deinit(self: *Container, alloc: Allocator) void {
        const sliced = self.children[0..self.n_children];
        for (sliced) |child| {
            child.deinit(alloc);
        }
        alloc.free(sliced);

        alloc.free(std.mem.span(self.kind));
    }
};

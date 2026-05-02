//! Abstract syntax tree for a MyST document.
//!
//! See https://mystmd.org/spec
//!
//! All strings appearing in the AST are null-terminated. Null-terminated
//! strings are easy enough to work with in Zig and having the strings be
//! null-terminated already makes it possible to expose the AST via the C ABI
//! without creating copies of all the strings.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// All available MyST node types.
///
/// This enum is also used by C-ABI-compatible AST, hence the backing type.
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
    caption = 26,
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

/// A MyST AST node.
pub const Node = union(NodeType) {
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
    caption: Wrapper,
    myst_role: MySTRole,
    myst_role_error: MySTRoleError,
    subscript: Wrapper,
    superscript: Wrapper,
    abbreviation: Abbreviation,
    myst_directive: MySTDirective,
    myst_directive_error: MySTDirectiveError,
    admonition: Admonition,
    admonition_title: Wrapper,

    pub fn deinit(self: *Node, alloc: Allocator) void {
        switch (self.*) {
            .thematic_break, .@"break" => {}, // no cleanup needed
            inline else => |*n| {
                n.deinit(alloc);
            },
        }

        alloc.destroy(self);
    }
};

pub const Root = struct {
    children: []*Node,

    pub fn deinit(self: *Root, alloc: Allocator) void {
        freeChildren(alloc, self.children);
    }
};

pub const Wrapper = struct {
    children: []*Node,

    pub fn deinit(self: *Wrapper, alloc: Allocator) void {
        freeChildren(alloc, self.children);
    }
};

pub const Heading = struct {
    children: []*Node,
    depth: u8,          // Headings cannot be deeper than six levels

    pub fn deinit(self: *Heading, alloc: Allocator) void {
        freeChildren(alloc, self.children);
    }
};

pub const Text = struct {
    value: [:0]const u8,

    pub fn deinit(self: *Text, alloc: Allocator) void {
        alloc.free(self.value);
    }
};

pub const Code = struct {
    value: [:0]const u8,
    lang: [:0]const u8,

    pub fn deinit(self: *Code, alloc: Allocator) void {
        alloc.free(self.value);
        alloc.free(self.lang);
    }
};

pub const Link = struct {
    children: []*Node,
    url: [:0]const u8,
    title: [:0]const u8,

    pub fn deinit(self: *Link, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        alloc.free(self.url);
        alloc.free(self.title);
    }
};

pub const LinkDefinition = struct {
    url: [:0]const u8,
    title: [:0]const u8,
    label: [:0]const u8,

    pub fn deinit(self: *LinkDefinition, alloc: Allocator) void {
        alloc.free(self.url);
        alloc.free(self.title);
        alloc.free(self.label);
    }
};

pub const Image = struct {
    url: [:0]const u8,
    title: [:0]const u8,
    alt: [:0]const u8,

    pub fn deinit(self: *Image, alloc: Allocator) void {
        alloc.free(self.url);
        alloc.free(self.title);
        alloc.free(self.alt);
    }
};

pub const Container = struct {
    children: []*Node,
    kind: [:0]const u8,

    pub fn deinit(self: *Container, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        alloc.free(self.kind);
    }
};

pub const MySTRole = struct {
    children: []*Node,
    name: [:0]const u8,
    value: [:0]const u8,

    pub fn deinit(self: *MySTRole, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        alloc.free(self.name);
        alloc.free(self.value);
    }
};

pub const MySTRoleError = struct {
    value: [:0]const u8,

    pub fn deinit(self: *MySTRoleError, alloc: Allocator) void {
        alloc.free(self.value);
    }
};

pub const Abbreviation = struct {
    children: []*Node,
    title: [:0]const u8,

    pub fn deinit(self: *Abbreviation, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        alloc.free(self.title);
    }
};

pub const MySTDirective = struct {
    children: []*Node,
    name: [:0]const u8,
    args: [:0]const u8,
    value: [:0]const u8,

    pub fn deinit(self: *MySTDirective, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        alloc.free(self.name);
        alloc.free(self.args);
        alloc.free(self.value);
    }
};

pub const MySTDirectiveError = struct {
    children: []*Node,
    message: [:0]const u8,

    pub fn deinit(self: *MySTDirectiveError, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        alloc.free(self.message);
    }
};

pub const Admonition = struct {
    children: []*Node,
    kind: [:0]const u8,

    pub fn deinit(self: *Admonition, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        alloc.free(self.kind);
    }
};

fn freeChildren(alloc: Allocator, children: []*Node) void {
    for (children) |child| {
        child.deinit(alloc);
    }
    alloc.free(children);
}

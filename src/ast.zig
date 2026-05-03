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

    /// Returns a "restricted node," i.e. one that has been type-narrowed to a
    /// subset of all possible nodes types.
    ///
    /// The returned union should be considered a "view" on the union payload
    /// of the node and not a node itself.
    pub fn restrict(
        self: *Node,
        comptime RestrictionEnum: type,
        comptime choice: RestrictionEnum,
    ) RestrictedNode(RestrictionEnum, choice) {
        switch (self.*) {
            inline else => |*n, tag| {
                if (comptime RestrictionEnum.fromNodeType(tag) != choice) {
                    @panic("wrong node type for restriction choice");
                }

                return @unionInit(
                    RestrictedNode(RestrictionEnum, choice),
                    @tagName(tag),
                    n,
                );
            },
        }
    }

    /// Returns a union bisecting nodes into those that have children and those
    /// that don't.
    pub fn hasChildren(self: *Node) HasChildrenRestriction {
        return switch (HasChildren.fromNodeType(self.*)) {
            .yes => .{ .yes = self.restrict(HasChildren, .yes) },
            .no  => .{ .no = self.restrict(HasChildren, .no) },
        };
    }

    /// Returns the type name as a string.
    ///
    /// The MyST spec uses camel case for type names.
    pub fn name(self: Node) [:0]const u8 {
        return switch (self) {
            .thematic_break => "thematicBreak",
            .inline_code => "inlineCode",
            .myst_role => "mystRole",
            .myst_role_error => "mystRoleError",
            .myst_directive => "mystDirective",
            .myst_directive_error => "mystDirectiveError",
            .admonition_title => "admonitionTitle",
            else => @tagName(self),
        };
    }

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

// ----------------------------------------------------------------------------
// Fancy-Pants Comptime Union Subsets
// ----------------------------------------------------------------------------
const HasChildren = enum {
    yes,
    no,

    /// Maps node types onto a value in the HasChildren enum.
    ///
    /// In other words, answers whether a type of node has children.
    fn fromNodeType(node_type: NodeType) HasChildren {
        return switch (node_type) {
            .root, .block, .heading, .paragraph, .emphasis, .strong, .link,
            .blockquote, .container, .caption, .myst_role, .subscript,
            .superscript, .abbreviation, .myst_directive,
            .myst_directive_error, .admonition, .admonition_title => .yes,
            else => .no,
        };
    }
};

// Bisects nodes into those that have children and those that don't.
pub const HasChildrenRestriction = union(HasChildren) {
    yes: RestrictedNode(HasChildren, .yes),
    no: RestrictedNode(HasChildren, .no),
};

// Creates an enum containing only the subset of node types matching the given
// restriction choice.
fn RestrictedNodeType(
    comptime RestrictionEnum: type,
    comptime choice: RestrictionEnum,
) type {
    @setEvalBranchQuota(10000);

    const e_info = @typeInfo(NodeType);
    const all_fields = e_info.@"enum".fields;

    var i: usize = 0;
    var fields: [all_fields.len]std.builtin.Type.EnumField = undefined;
    for (all_fields) |field| {
        const node = @unionInit(Node, field.name, undefined);
        if (RestrictionEnum.fromNodeType(node) == choice) {
            fields[i] = field;
            i += 1;
        }
    }

    return @Type(.{ .@"enum" = .{
        .tag_type = e_info.@"enum".tag_type,
        .fields = fields[0..i],
        .decls = &.{},
        .is_exhaustive = true,
    } });
}

// Creates a union containing only the subset of node types matching the given
// restriction choice.
//
// The union payloads are pointers to the original payloads in the node union.
pub fn RestrictedNode(
    comptime RestrictionEnum: type,
    comptime choice: RestrictionEnum,
) type {
    @setEvalBranchQuota(10000);

    const all_fields = @typeInfo(Node).@"union".fields;

    var i: usize = 0;
    var fields: [all_fields.len]std.builtin.Type.UnionField = undefined;
    for (all_fields) |field| {
        const node = @unionInit(Node, field.name, undefined);
        if (RestrictionEnum.fromNodeType(node) == choice) {
            fields[i] = .{
                .name = field.name,
                .type = *field.type,
                .alignment = field.alignment,
            };
            i += 1;
        }
    }

    return @Type(.{
        .@"union" = .{
            .layout = .auto,
            .tag_type = RestrictedNodeType(RestrictionEnum, choice),
            .fields = fields[0..i],
            .decls = &.{},
        },
    });
}

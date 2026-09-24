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
/// This enum is also used by the C-ABI-compatible AST, hence the backing type.
pub const NodeType = enum(c_uint) {
    root = 0,
    block = 1,
    heading = 2,
    paragraph = 3,
    text = 4,
    code = 5,
    thematic_break = 6,
    @"break" = 7, // line break
    emphasis = 8,
    strong = 9,
    inline_code = 10,
    link = 11,
    definition = 12, // link definition
    image = 13,
    blockquote = 14,
    html = 15, // either an HTML block or a single inline HTML tag
    container = 25,
    caption = 26,
    list = 27,
    list_item = 28,
    comment = 29,
    legend = 32,
    block_break = 33,
    footnote_definition = 34,
    footnote_reference = 35,
    target = 39,
    cross_reference = 40,
    // built-in roles
    myst_role = 16,
    myst_role_error = 17,
    subscript = 18,
    superscript = 19,
    abbreviation = 20,
    inline_math = 30,
    // built-in directives
    myst_directive = 21,
    myst_directive_error = 22,
    admonition = 23,
    admonition_title = 24,
    math = 31,
    table = 36,
    table_row = 37,
    table_cell = 38,

    pub fn name(self: NodeType) [:0]const u8 {
        return switch (self) {
            .thematic_break => "thematicBreak",
            .inline_code => "inlineCode",
            .myst_role => "mystRole",
            .myst_role_error => "mystRoleError",
            .inline_math => "inlineMath",
            .myst_directive => "mystDirective",
            .myst_directive_error => "mystDirectiveError",
            .admonition_title => "admonitionTitle",
            .list_item => "listItem",
            .comment => "mystComment", // NB: Not just camel casing
            .block_break => "blockBreak",
            .footnote_definition => "footnoteDefinition",
            .footnote_reference => "footnoteReference",
            .table_row => "tableRow",
            .table_cell => "tableCell",
            .target => "mystTarget",
            .cross_reference => "crossReference",
            else => @tagName(self),
        };
    }
};

/// A MyST AST node.
pub const Node = union(NodeType) {
    root: Root,
    block: Block,
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
    list: List,
    list_item: ListItem,
    comment: Text,
    legend: Wrapper,
    block_break: BlockBreak,
    footnote_definition: FootnoteDefinition,
    footnote_reference: FootnoteReference,
    target: ReferenceTarget,
    cross_reference: CrossReference,
    myst_role: MySTRole,
    myst_role_error: MySTRoleError,
    subscript: Wrapper,
    superscript: Wrapper,
    abbreviation: Abbreviation,
    inline_math: Text,
    myst_directive: MySTDirective,
    myst_directive_error: MySTDirectiveError,
    admonition: Admonition,
    admonition_title: Wrapper,
    math: Math,
    table: Table,
    table_row: Wrapper,
    table_cell: TableCell,

    /// Returns a union bisecting nodes into those that have children and those
    /// that don't.
    pub fn allowedChildren(self: *Node) AllowedChildrenSubsets {
        return switch (AllowedChildren.fromNodeType(self.*)) {
            .yes => .{ .yes = self.narrow(AllowedChildren, .yes) },
            .no => .{ .no = self.narrow(AllowedChildren, .no) },
        };
    }

    /// Returns the type name as a string.
    ///
    /// The MyST spec uses camel case for type names.
    pub fn name(self: Node) [:0]const u8 {
        return @as(NodeType, self).name();
    }

    /// Adds a node as the first child of this node.
    pub fn prependChild(
        self: *Node,
        alloc: Allocator,
        new_child_node: *Node,
    ) !void {
        switch (self.allowedChildren()) {
            .yes => |branch_node| switch (branch_node) {
                inline else => |n| {
                    // TODO: Should children be stored in array lists?
                    const new_children = try alloc.alloc(
                        *Node,
                        n.children.len + 1,
                    );
                    const old_children = n.children;
                    defer alloc.free(old_children);

                    new_children[0] = new_child_node;
                    for (old_children, 1..) |child, i| {
                        new_children[i] = child;
                    }
                    n.children = new_children;
                },
            },
            .no => {
                @panic("can't prepend child to node that can't have children");
            },
        }
    }

    /// Adds a node as the last child of this node.
    pub fn appendChild(
        self: *Node,
        alloc: Allocator,
        new_child_node: *Node,
    ) !void {
        switch (self.allowedChildren()) {
            .yes => |branch_node| switch (branch_node) {
                inline else => |n| {
                    // TODO: Should children be stored in array lists?
                    const new_children = try alloc.alloc(
                        *Node,
                        n.children.len + 1,
                    );
                    const old_children = n.children;
                    defer alloc.free(old_children);

                    for (old_children, 0..) |child, i| {
                        new_children[i] = child;
                    }
                    new_children[old_children.len] = new_child_node;
                    n.children = new_children;
                },
            },
            .no => {
                @panic("can't append child to node that can't have children");
            },
        }
    }

    /// Returns a deep copy of this node.
    ///
    /// Recursively copies all children!
    pub fn clone(self: Node, alloc: Allocator) Allocator.Error!Node {
        return switch (self) {
            .thematic_break, .@"break" => self,
            inline else => |n, tag| @unionInit(
                Node,
                @tagName(tag),
                try n.clone(alloc),
            ),
        };
    }

    pub fn deinit(self: *Node, alloc: Allocator) void {
        switch (self.*) {
            .thematic_break, .@"break" => {}, // no cleanup needed
            inline else => |*n| {
                n.deinit(alloc);
            },
        }

        // TODO: Should this be in a deinit()?
        alloc.destroy(self);
    }

    /// Returns a "narrowed node," i.e. one that has been type-narrowed to a
    /// subset of all possible nodes types.
    ///
    /// The returned union should be considered a view on the union payload of
    /// the node and not a node itself.
    ///
    /// Panics if the runtime node type is not in the given subset.
    fn narrow(
        self: *Node,
        comptime SubsetEnum: type,
        comptime choice: SubsetEnum,
    ) NarrowedNode(SubsetEnum, choice) {
        switch (self.*) {
            inline else => |*n, tag| {
                if (comptime SubsetEnum.fromNodeType(tag) != choice) {
                    @panic("runtime node type mismatch in narrow()");
                }

                return @unionInit(
                    NarrowedNode(SubsetEnum, choice),
                    @tagName(tag),
                    n,
                );
            },
        }
    }
};

pub const Root = struct {
    children: []*Node,

    pub fn clone(self: Root, alloc: Allocator) !Root {
        return .{
            .children = try cloneChildren(alloc, self.children),
        };
    }

    pub fn deinit(self: *Root, alloc: Allocator) void {
        freeChildren(alloc, self.children);
    }
};

pub const Block = struct {
    children: []*Node,
    meta: [:0]const u8,

    pub fn clone(self: Block, alloc: Allocator) !Block {
        return .{
            .children = try cloneChildren(alloc, self.children),
            .meta = try alloc.dupeZ(u8, self.meta),
        };
    }

    pub fn deinit(self: *Block, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        alloc.free(self.meta);
    }
};

pub const Wrapper = struct {
    children: []*Node,

    pub fn clone(self: Wrapper, alloc: Allocator) !Wrapper {
        return .{
            .children = try cloneChildren(alloc, self.children),
        };
    }

    pub fn deinit(self: *Wrapper, alloc: Allocator) void {
        freeChildren(alloc, self.children);
    }
};

pub const Heading = struct {
    children: []*Node,
    depth: u8, // Headings cannot be deeper than six levels
    label: ?[:0]const u8 = null,
    identifier: ?[:0]const u8 = null,

    pub fn clone(self: Heading, alloc: Allocator) !Heading {
        return .{
            .children = try cloneChildren(alloc, self.children),
            .depth = self.depth,
            .label = if (self.label) |label|
                try alloc.dupeZ(u8, label)
            else
                null,
            .identifier = if (self.identifier) |identifier|
                try alloc.dupeZ(u8, identifier)
            else
                null,
        };
    }

    pub fn deinit(self: *Heading, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        if (self.label) |label| alloc.free(label);
        if (self.identifier) |identifier| alloc.free(identifier);
    }
};

pub const Text = struct {
    value: [:0]const u8,

    pub fn clone(self: Text, alloc: Allocator) !Text {
        return .{
            .value = try alloc.dupeZ(u8, self.value),
        };
    }

    pub fn deinit(self: *Text, alloc: Allocator) void {
        alloc.free(self.value);
    }
};

pub const Code = struct {
    value: [:0]const u8,
    lang: [:0]const u8,
    show_line_numbers: bool = false,
    starting_line_number: ?u32 = null,
    filename: ?[:0]const u8 = null,
    emphasize_lines: ?[]u16 = null,
    class: ?[:0]const u8 = null, // user-defined class for code block
    label: ?[:0]const u8 = null,
    identifier: ?[:0]const u8 = null,

    pub fn clone(self: Code, alloc: Allocator) !Code {
        return .{
            .value = try alloc.dupeZ(u8, self.value),
            .lang = try alloc.dupeZ(u8, self.lang),
            .show_line_numbers = self.show_line_numbers,
            .starting_line_number = self.starting_line_number,
            .filename = if (self.filename) |filename|
                try alloc.dupeZ(u8, filename)
            else
                null,
            .emphasize_lines = if (self.emphasize_lines) |emphasize_lines|
                try alloc.dupe(u16, emphasize_lines)
            else
                null,
            .class = if (self.class) |class|
                try alloc.dupeZ(u8, class)
            else
                null,
            .label = if (self.label) |label|
                try alloc.dupeZ(u8, label)
            else
                null,
            .identifier = if (self.identifier) |identifier|
                try alloc.dupeZ(u8, identifier)
            else
                null,
        };
    }

    pub fn deinit(self: *Code, alloc: Allocator) void {
        alloc.free(self.value);
        alloc.free(self.lang);
        if (self.filename) |f| {
            alloc.free(f);
        }
        if (self.emphasize_lines) |l| {
            alloc.free(l);
        }
        if (self.class) |c| {
            alloc.free(c);
        }
        if (self.label) |l| {
            alloc.free(l);
        }
        if (self.identifier) |i| {
            alloc.free(i);
        }
    }
};

pub const Link = struct {
    children: []*Node,
    url: [:0]const u8,
    title: [:0]const u8,

    pub fn clone(self: Link, alloc: Allocator) !Link {
        return .{
            .children = try cloneChildren(alloc, self.children),
            .url = try alloc.dupeZ(u8, self.url),
            .title = try alloc.dupeZ(u8, self.title),
        };
    }

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

    pub fn clone(self: LinkDefinition, alloc: Allocator) !LinkDefinition {
        return .{
            .url = try alloc.dupeZ(u8, self.url),
            .title = try alloc.dupeZ(u8, self.title),
            .label = try alloc.dupeZ(u8, self.label),
        };
    }

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
    class: ?[:0]const u8 = null,
    @"align": ?[:0]const u8 = null,
    width: ?[:0]const u8 = null,

    pub fn clone(self: Image, alloc: Allocator) !Image {
        return .{
            .url = try alloc.dupeZ(u8, self.url),
            .title = try alloc.dupeZ(u8, self.title),
            .alt = try alloc.dupeZ(u8, self.alt),
            .class = if (self.class) |class|
                try alloc.dupeZ(u8, class)
            else
                null,
            .@"align" = if (self.@"align") |a|
                try alloc.dupeZ(u8, a)
            else
                null,
            .width = if (self.width) |width|
                try alloc.dupeZ(u8, width)
            else
                null,
        };
    }

    pub fn deinit(self: *Image, alloc: Allocator) void {
        alloc.free(self.url);
        alloc.free(self.title);
        alloc.free(self.alt);
        if (self.class) |class| alloc.free(class);
        if (self.@"align") |a| alloc.free(a);
        if (self.width) |width| alloc.free(width);
    }
};

pub const Container = struct {
    children: []*Node,
    kind: [:0]const u8,
    label: ?[:0]const u8 = null,
    identifier: ?[:0]const u8 = null,
    class: ?[:0]const u8 = null,
    enumerated: bool = false,
    enumerator: ?[:0]const u8 = null,

    pub fn clone(self: Container, alloc: Allocator) !Container {
        return .{
            .children = try cloneChildren(alloc, self.children),
            .kind = try alloc.dupeZ(u8, self.kind),
            .label = if (self.label) |label|
                try alloc.dupeZ(u8, label)
            else
                null,
            .identifier = if (self.identifier) |identifier|
                try alloc.dupeZ(u8, identifier)
            else
                null,
            .class = if (self.class) |class|
                try alloc.dupeZ(u8, class)
            else
                null,
            .enumerated = self.enumerated,
            .enumerator = if (self.enumerator) |enumerator|
                try alloc.dupeZ(u8, enumerator)
            else
                null,
        };
    }

    pub fn deinit(self: *Container, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        alloc.free(self.kind);
        if (self.label) |label| alloc.free(label);
        if (self.identifier) |identifier| alloc.free(identifier);
        if (self.class) |class| alloc.free(class);
        if (self.enumerator) |enumerator| alloc.free(enumerator);
    }
};

pub const List = struct {
    children: []*Node,
    ordered: bool,
    start: u32 = 1,
    spread: bool = false,

    pub fn clone(self: List, alloc: Allocator) !List {
        return .{
            .children = try cloneChildren(alloc, self.children),
            .ordered = self.ordered,
            .start = self.start,
            .spread = self.spread,
        };
    }

    pub fn deinit(self: *List, alloc: Allocator) void {
        freeChildren(alloc, self.children);
    }
};

pub const ListItem = struct {
    children: []*Node,
    spread: bool = false,

    pub fn clone(self: ListItem, alloc: Allocator) !ListItem {
        return .{
            .children = try cloneChildren(alloc, self.children),
            .spread = self.spread,
        };
    }

    pub fn deinit(self: *ListItem, alloc: Allocator) void {
        freeChildren(alloc, self.children);
    }
};

pub const BlockBreak = struct {
    meta: [:0]const u8,

    pub fn clone(self: BlockBreak, alloc: Allocator) !BlockBreak {
        return .{
            .meta = try alloc.dupeZ(u8, self.meta),
        };
    }

    pub fn deinit(self: *BlockBreak, alloc: Allocator) void {
        alloc.free(self.meta);
    }
};

pub const FootnoteDefinition = struct {
    children: []*Node,
    identifier: [:0]const u8,
    label: [:0]const u8,
    enumerator: ?[:0]const u8 = null,

    pub fn clone(
        self: FootnoteDefinition,
        alloc: Allocator,
    ) !FootnoteDefinition {
        return .{
            .children = try cloneChildren(alloc, self.children),
            .identifier = try alloc.dupeZ(u8, self.identifier),
            .label = try alloc.dupeZ(u8, self.label),
            .enumerator = if (self.enumerator) |enumerator|
                try alloc.dupeZ(u8, enumerator)
            else
                null,
        };
    }

    pub fn deinit(self: *FootnoteDefinition, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        alloc.free(self.identifier);
        alloc.free(self.label);
        if (self.enumerator) |enumerator| alloc.free(enumerator);
    }
};

pub const FootnoteReference = struct {
    identifier: [:0]const u8,
    label: [:0]const u8,
    enumerator: ?[:0]const u8 = null,

    pub fn clone(
        self: FootnoteReference,
        alloc: Allocator,
    ) !FootnoteReference {
        return .{
            .identifier = try alloc.dupeZ(u8, self.identifier),
            .label = try alloc.dupeZ(u8, self.label),
            .enumerator = if (self.enumerator) |enumerator|
                try alloc.dupeZ(u8, enumerator)
            else
                null,
        };
    }

    pub fn deinit(self: *FootnoteReference, alloc: Allocator) void {
        alloc.free(self.identifier);
        alloc.free(self.label);
        if (self.enumerator) |enumerator| alloc.free(enumerator);
    }
};

pub const MySTRole = struct {
    children: []*Node,
    name: [:0]const u8,
    value: [:0]const u8,

    pub fn clone(self: MySTRole, alloc: Allocator) !MySTRole {
        return .{
            .children = try cloneChildren(alloc, self.children),
            .name = try alloc.dupeZ(u8, self.name),
            .value = try alloc.dupeZ(u8, self.value),
        };
    }

    pub fn deinit(self: *MySTRole, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        alloc.free(self.name);
        alloc.free(self.value);
    }
};

pub const MySTRoleError = struct {
    value: [:0]const u8,

    pub fn clone(self: MySTRoleError, alloc: Allocator) !MySTRoleError {
        return .{
            .value = try alloc.dupeZ(u8, self.value),
        };
    }

    pub fn deinit(self: *MySTRoleError, alloc: Allocator) void {
        alloc.free(self.value);
    }
};

pub const Abbreviation = struct {
    children: []*Node,
    title: [:0]const u8,

    pub fn clone(self: Abbreviation, alloc: Allocator) !Abbreviation {
        return .{
            .children = try cloneChildren(alloc, self.children),
            .title = try alloc.dupeZ(u8, self.title),
        };
    }

    pub fn deinit(self: *Abbreviation, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        alloc.free(self.title);
    }
};

pub const MySTDirective = struct {
    pub const Option = struct {
        name: [:0]const u8,
        value: ?[:0]const u8 = null,

        pub fn clone(self: Option, alloc: Allocator) !Option {
            return .{
                .name = try alloc.dupeZ(u8, self.name),
                .value = if (self.value) |value|
                    try alloc.dupeZ(u8, value)
                else
                    null,
            };
        }

        pub fn deinit(self: Option, alloc: Allocator) void {
            alloc.free(self.name);
            if (self.value) |v| {
                alloc.free(v);
            }
        }
    };

    children: []*Node,
    name: [:0]const u8,
    args: [:0]const u8,
    options: []const Option,
    value: [:0]const u8,

    pub fn clone(self: MySTDirective, alloc: Allocator) !MySTDirective {
        const options = try alloc.alloc(Option, self.options.len);
        for (self.options, 0..) |opt, i| {
            options[i] = try opt.clone(alloc);
        }
        return .{
            .children = try cloneChildren(alloc, self.children),
            .name = try alloc.dupeZ(u8, self.name),
            .args = try alloc.dupeZ(u8, self.args),
            .options = options,
            .value = try alloc.dupeZ(u8, self.value),
        };
    }

    pub fn deinit(self: *MySTDirective, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        alloc.free(self.name);
        alloc.free(self.args);

        for (self.options) |option| {
            option.deinit(alloc);
        }
        alloc.free(self.options);

        alloc.free(self.value);
    }
};

pub const MySTDirectiveError = struct {
    children: []*Node,
    message: [:0]const u8,

    pub fn clone(
        self: MySTDirectiveError,
        alloc: Allocator,
    ) !MySTDirectiveError {
        return .{
            .children = try cloneChildren(alloc, self.children),
            .message = try alloc.dupeZ(u8, self.message),
        };
    }

    pub fn deinit(self: *MySTDirectiveError, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        alloc.free(self.message);
    }
};

pub const Admonition = struct {
    children: []*Node,
    kind: [:0]const u8,
    class: ?[:0]const u8 = null,

    pub fn clone(self: Admonition, alloc: Allocator) !Admonition {
        return .{
            .children = try cloneChildren(alloc, self.children),
            .kind = try alloc.dupeZ(u8, self.kind),
            .class = if (self.class) |class|
                try alloc.dupeZ(u8, class)
            else
                null,
        };
    }

    pub fn deinit(self: *Admonition, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        alloc.free(self.kind);
        if (self.class) |class| alloc.free(class);
    }
};

pub const Math = struct {
    value: [:0]const u8,
    identifier: ?[:0]const u8 = null,
    label: ?[:0]const u8 = null,
    enumerated: bool = true,
    enumerator: ?[:0]const u8 = null,

    pub fn clone(self: Math, alloc: Allocator) !Math {
        return .{
            .value = try alloc.dupeZ(u8, self.value),
            .identifier = if (self.identifier) |identifier|
                try alloc.dupeZ(u8, identifier)
            else
                null,
            .label = if (self.label) |label|
                try alloc.dupeZ(u8, label)
            else
                null,
            .enumerated = self.enumerated,
            .enumerator = if (self.enumerator) |enumerator|
                try alloc.dupeZ(u8, enumerator)
            else
                null,
        };
    }

    pub fn deinit(self: *Math, alloc: Allocator) void {
        alloc.free(self.value);
        if (self.identifier) |identifier| alloc.free(identifier);
        if (self.label) |label| alloc.free(label);
        if (self.enumerator) |enumerator| alloc.free(enumerator);
    }
};

pub const Table = struct {
    children: []*Node,
    @"align": ?[:0]const u8 = null,

    pub fn clone(self: Table, alloc: Allocator) !Table {
        return .{
            .children = try cloneChildren(alloc, self.children),
            .@"align" = if (self.@"align") |@"align"|
                try alloc.dupeZ(u8, @"align")
            else
                null,
        };
    }

    pub fn deinit(self: *Table, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        if (self.@"align") |a| alloc.free(a);
    }
};

pub const TableCell = struct {
    children: []*Node,
    header: bool,
    @"align": ?[:0]const u8 = null,

    pub fn clone(self: TableCell, alloc: Allocator) !TableCell {
        return .{
            .children = try cloneChildren(alloc, self.children),
            .header = self.header,
            .@"align" = if (self.@"align") |@"align"|
                try alloc.dupeZ(u8, @"align")
            else
                null,
        };
    }

    pub fn deinit(self: *TableCell, alloc: Allocator) void {
        freeChildren(alloc, self.children);

        if (self.@"align") |a| alloc.free(a);
    }
};

pub const ReferenceTarget = struct {
    label: [:0]const u8,

    pub fn clone(self: ReferenceTarget, alloc: Allocator) !ReferenceTarget {
        return .{
            .label = try alloc.dupeZ(u8, self.label),
        };
    }

    pub fn deinit(self: *ReferenceTarget, alloc: Allocator) void {
        alloc.free(self.label);
    }
};

pub const CrossReference = struct {
    children: []*Node,
    kind: [:0]const u8, // TODO: Should be an enum?
    label: [:0]const u8,
    identifier: [:0]const u8,
    title: ?[:0]const u8 = null,

    pub fn clone(self: CrossReference, alloc: Allocator) !CrossReference {
        return .{
            .children = try cloneChildren(alloc, self.children),
            .kind = try alloc.dupeZ(u8, self.kind),
            .label = try alloc.dupeZ(u8, self.label),
            .identifier = try alloc.dupeZ(u8, self.identifier),
            .title = if (self.title) |title|
                try alloc.dupeZ(u8, title)
            else
                null,
        };
    }

    pub fn deinit(self: *CrossReference, alloc: Allocator) void {
        alloc.free(self.kind);
        alloc.free(self.label);
        alloc.free(self.identifier);

        if (self.title) |title| alloc.free(title);

        freeChildren(alloc, self.children);
    }
};

fn cloneChildren(alloc: Allocator, children: []*Node) ![]*Node {
    const new_children = try alloc.alloc(*Node, children.len);
    for (children, 0..) |child, i| {
        new_children[i] = try alloc.create(Node);
        new_children[i].* = try child.clone(alloc);
    }
    return new_children;
}

fn freeChildren(alloc: Allocator, children: []*Node) void {
    for (children) |child| {
        child.deinit(alloc);
    }
    alloc.free(children);
}

// ----------------------------------------------------------------------------
// Fancy-Pants Comptime Union Subsets
// ----------------------------------------------------------------------------
pub const AllowedChildren = enum {
    yes,
    no,

    /// Maps node types onto a value in the AllowedChildren enum.
    ///
    /// In other words, answers whether a type of node has children.
    pub fn fromNodeType(node_type: NodeType) AllowedChildren {
        return switch (node_type) {
            .root,
            .block,
            .heading,
            .paragraph,
            .emphasis,
            .strong,
            .link,
            .blockquote,
            .container,
            .caption,
            .list,
            .list_item,
            .myst_role,
            .subscript,
            .superscript,
            .abbreviation,
            .myst_directive,
            .myst_directive_error,
            .admonition,
            .admonition_title,
            .legend,
            .footnote_definition,
            .table,
            .table_row,
            .table_cell,
            .cross_reference,
            => .yes,
            .text,
            .code,
            .thematic_break,
            .block_break,
            .@"break",
            .inline_code,
            .definition,
            .image,
            .html,
            .myst_role_error,
            .comment,
            .inline_math,
            .math,
            .footnote_reference,
            .target,
            => .no,
        };
    }
};

// Bisects nodes into those that have children and those that don't.
const AllowedChildrenSubsets = union(AllowedChildren) {
    yes: NarrowedNode(AllowedChildren, .yes),
    no: NarrowedNode(AllowedChildren, .no),
};

// Creates an enum containing only the subset of node types matching the given
// restriction choice.
fn NarrowedNodeType(
    comptime SubsetEnum: type,
    comptime choice: SubsetEnum,
) type {
    @setEvalBranchQuota(10000);

    const e_info = @typeInfo(NodeType);
    const all_fields = e_info.@"enum".fields;

    var i: usize = 0;
    var fields: [all_fields.len]std.builtin.Type.EnumField = undefined;
    for (all_fields) |field| {
        const node = @unionInit(Node, field.name, undefined);
        if (SubsetEnum.fromNodeType(node) == choice) {
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
fn NarrowedNode(
    comptime SubsetEnum: type,
    comptime choice: SubsetEnum,
) type {
    @setEvalBranchQuota(10000);

    const all_fields = @typeInfo(Node).@"union".fields;

    var i: usize = 0;
    var fields: [all_fields.len]std.builtin.Type.UnionField = undefined;
    for (all_fields) |field| {
        const node = @unionInit(Node, field.name, undefined);
        if (SubsetEnum.fromNodeType(node) == choice) {
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
            .tag_type = NarrowedNodeType(SubsetEnum, choice),
            .fields = fields[0..i],
            .decls = &.{},
        },
    });
}

//! Implements the C-ABI-compatible interface to libatrus.
//!
//! See include/atrus.h for usage documentation.
//!
//! Any "extern" data structures here must be kept in sync with the definitions
//! in include/atrus.h. Doing any of the following constitutes a breaking ABI
//! change:
//!
//! * Adding a new field to an extern struct.
//! * Changing the order of fields in an extern struct.
//! * Adding a new member to an extern union, if the member is bigger than the
//!   others.
//! * Changing any field types.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const atrus = @import("atrus");
const ParseError = atrus.ParseError;
const RenderJSONError = atrus.RenderJSONError;
const RenderHTMLError = atrus.RenderHTMLError;

const c_alloc = std.heap.c_allocator;

// TODO: Is atrus.version already null-terminated?
export const atrus_version: [*:0]const u8 = atrus.version ++ "\x00";

// ----------------------------------------------------------------------------
// Basic Atrus API (Opaque AST)
// ----------------------------------------------------------------------------
const ParseOptions = extern struct {
    parse_level: enum(c_uint) {
        post = 0, // Use zero for the default.
        pre = 1,
        block = 2,
        raw = 3,
    } = .post,
};

export fn atrus_parse(
    in: [*:0]const u8,
    out: **atrus.ast.Node,
    options: *const ParseOptions,
) c_int {
    var reader = Io.Reader.fixed(std.mem.span(in));
    const native_options: atrus.ParseOptions = .{
        .parse_level = switch (options.parse_level) {
            .block => .block,
            .raw => .raw,
            .pre => .pre,
            .post => .post,
        },
    };

    out.* = atrus.parse(c_alloc, &reader, native_options) catch |err| {
        switch (err) {
            ParseError.ReadFailed => return -1,
            else => return -2,
        }
    };

    return 0;
}

export fn atrus_free(root: *atrus.ast.Node) void {
    root.deinit(c_alloc);
}

export fn atrus_render_html(root: *atrus.ast.Node, out: *[*:0]const u8) c_int {
    var buf = Io.Writer.Allocating.init(c_alloc);
    atrus.renderHTML(root, &buf.writer, .{}) catch |err| {
        switch (err) {
            // TODO: Proper error propagation.
            RenderHTMLError.WriteFailed => return -1,
            RenderHTMLError.OutOfMemory => return -1,
            RenderHTMLError.NotPostProcessed => return -1,
        }
    };

    const s: [:0]const u8 = buf.toOwnedSliceSentinel(0) catch |err| {
        switch (err) {
            Allocator.Error.OutOfMemory => return -1,
        }
    };
    out.* = s.ptr;
    return @intCast(s.len);
}

const JSONOptions = extern struct {
    whitespace: enum(c_uint) {
        minified = 0,
        indent_2 = 1,
        indent_4 = 2,
    } = .minified,
};

export fn atrus_render_json(
    root: *atrus.ast.Node,
    out: *[*:0]const u8,
    options: *const JSONOptions,
) c_int {
    var buf = Io.Writer.Allocating.init(c_alloc);
    const native_options: atrus.JSONOptions = .{
        .whitespace = switch (options.whitespace) {
            .minified => .minified,
            .indent_2 => .indent_2,
            .indent_4 => .indent_4,
        },
    };
    atrus.renderJSON(root, &buf.writer, native_options) catch |err| {
        switch (err) {
            RenderJSONError.WriteFailed => return -1,
            RenderJSONError.OutOfMemory => return -1,
        }
    };

    const s: [:0]const u8 = buf.toOwnedSliceSentinel(0) catch |err| {
        switch (err) {
            Allocator.Error.OutOfMemory => return -1,
        }
    };
    out.* = s.ptr;
    return @intCast(s.len);
}

export fn atrus_load_json(in: [*:0]const u8, out: **atrus.ast.Node) c_int {
    var reader = Io.Reader.fixed(std.mem.span(in));
    out.* = atrus.loadJSON(c_alloc, &reader) catch |err| {
        switch (err) {
            error.NotImplemented => return -1,
        }
    };

    return 0;
}

// ----------------------------------------------------------------------------
// Advanced Atrus API (Exposed AST)
// ----------------------------------------------------------------------------
const Root = extern struct {
    children: [*]*ExposedNode,
    children_len: c_uint,

    fn init(alloc: Allocator, root: *atrus.ast.Root) !Root {
        const new_children = try exposeChildren(alloc, root.children);
        return .{
            .children = new_children,
            .children_len = @intCast(root.children.len),
        };
    }

    fn adopt(self: *Root, alloc: Allocator) !atrus.ast.Root {
        const new_children = try adoptChildren(
            alloc,
            self.children,
            self.children_len,
        );
        return .{
            .children = new_children,
        };
    }

    fn deinit(self: Root, alloc: Allocator) void {
        freeChildren(alloc, self.children, self.children_len);
    }
};

const Wrapper = extern struct {
    children: [*]*ExposedNode,
    children_len: c_uint,

    fn init(alloc: Allocator, wrapper: *atrus.ast.Wrapper) !Wrapper {
        const new_children = try exposeChildren(alloc, wrapper.children);
        return .{
            .children = new_children,
            .children_len = @intCast(wrapper.children.len),
        };
    }

    fn adopt(self: *Wrapper, alloc: Allocator) !atrus.ast.Wrapper {
        const new_children = try adoptChildren(
            alloc,
            self.children,
            self.children_len,
        );
        return .{
            .children = new_children,
        };
    }

    fn deinit(self: Wrapper, alloc: Allocator) void {
        freeChildren(alloc, self.children, self.children_len);
    }
};

const Heading = extern struct {
    children: [*]*ExposedNode,
    children_len: c_uint,
    depth: c_ushort,

    fn init(alloc: Allocator, heading: *atrus.ast.Heading) !Heading {
        const new_children = try exposeChildren(alloc, heading.children);
        return .{
            .children = new_children,
            .children_len = @intCast(heading.children.len),
            .depth = @intCast(heading.depth),
        };
    }

    fn adopt(self: *Heading, alloc: Allocator) !atrus.ast.Heading {
        const new_children = try adoptChildren(
            alloc,
            self.children,
            self.children_len,
        );
        return .{
            .children = new_children,
            .depth = @intCast(self.depth),
        };
    }

    fn deinit(self: *Heading, alloc: Allocator) void {
        freeChildren(alloc, self.children, self.children_len);
    }
};

const Text = extern struct {
    value: [*:0]const u8,

    fn init(alloc: Allocator, text: *atrus.ast.Text) !Text {
        _ = alloc;
        return .{
            .value = text.value.ptr,
        };
    }

    fn adopt(self: *Text, alloc: Allocator) !atrus.ast.Text {
        _ = alloc;
        return .{
            .value = std.mem.span(self.value),
        };
    }

    fn deinit(self: Text, alloc: Allocator) void {
        alloc.free(std.mem.span(self.value));
    }
};

const Code = extern struct {
    value: [*:0]const u8,
    lang: [*:0]const u8,
    show_line_numbers: bool,

    fn init(alloc: Allocator, code: *atrus.ast.Code) !Code {
        _ = alloc;
        return .{
            .value = code.value.ptr,
            .lang = code.lang.ptr,
            .show_line_numbers = code.show_line_numbers,
        };
    }

    fn adopt(self: *Code, alloc: Allocator) !atrus.ast.Code {
        _ = alloc;
        return .{
            .value = std.mem.span(self.value),
            .lang = std.mem.span(self.lang),
            .show_line_numbers = self.show_line_numbers,
        };
    }

    fn deinit(self: *Code, alloc: Allocator) void {
        alloc.free(std.mem.span(self.value));
        alloc.free(std.mem.span(self.lang));
    }
};

const Link = extern struct {
    children: [*]*ExposedNode,
    children_len: c_uint,
    url: [*:0]const u8,
    title: [*:0]const u8,

    fn init(alloc: Allocator, link: *atrus.ast.Link) !Link {
        const new_children = try exposeChildren(alloc, link.children);
        return .{
            .children = new_children,
            .children_len = @intCast(link.children.len),
            .url = link.url.ptr,
            .title = link.title.ptr,
        };
    }

    fn adopt(self: *Link, alloc: Allocator) !atrus.ast.Link {
        const new_children = try adoptChildren(
            alloc,
            self.children,
            self.children_len,
        );
        return .{
            .children = new_children,
            .url = std.mem.span(self.url),
            .title = std.mem.span(self.title),
        };
    }

    fn deinit(self: *Link, alloc: Allocator) void {
        freeChildren(alloc, self.children, self.children_len);
        alloc.free(std.mem.span(self.url));
        alloc.free(std.mem.span(self.title));
    }
};

const LinkDefinition = extern struct {
    url: [*:0]const u8,
    title: [*:0]const u8,
    label: [*:0]const u8,

    fn init(
        alloc: Allocator,
        link_def: *atrus.ast.LinkDefinition,
    ) !LinkDefinition {
        _ = alloc;
        return .{
            .url = link_def.url.ptr,
            .title = link_def.title.ptr,
            .label = link_def.label.ptr,
        };
    }

    fn adopt(
        self: *LinkDefinition,
        alloc: Allocator,
    ) !atrus.ast.LinkDefinition {
        _ = alloc;
        return .{
            .url = std.mem.span(self.url),
            .title = std.mem.span(self.title),
            .label = std.mem.span(self.label),
        };
    }

    fn deinit(self: *LinkDefinition, alloc: Allocator) void {
        alloc.free(std.mem.span(self.url));
        alloc.free(std.mem.span(self.title));
        alloc.free(std.mem.span(self.label));
    }
};

const Image = extern struct {
    url: [*:0]const u8,
    title: [*:0]const u8,
    alt: [*:0]const u8,

    fn init(alloc: Allocator, image: *atrus.ast.Image) !Image {
        _ = alloc;
        return .{
            .url = image.url.ptr,
            .title = image.title.ptr,
            .alt = image.alt.ptr,
        };
    }

    fn adopt(self: *Image, alloc: Allocator) !atrus.ast.Image {
        _ = alloc;
        return .{
            .url = std.mem.span(self.url),
            .title = std.mem.span(self.title),
            .alt = std.mem.span(self.alt),
        };
    }

    fn deinit(self: *Image, alloc: Allocator) void {
        alloc.free(std.mem.span(self.url));
        alloc.free(std.mem.span(self.title));
        alloc.free(std.mem.span(self.alt));
    }
};

const Container = extern struct {
    children: [*]*ExposedNode,
    children_len: c_uint,
    kind: [*:0]const u8,

    fn init(alloc: Allocator, container: *atrus.ast.Container) !Container {
        const new_children = try exposeChildren(alloc, container.children);
        return .{
            .children = new_children,
            .children_len = @intCast(container.children.len),
            .kind = container.kind.ptr,
        };
    }

    fn adopt(self: *Container, alloc: Allocator) !atrus.ast.Container {
        const new_children = try adoptChildren(
            alloc,
            self.children,
            self.children_len,
        );
        return .{
            .children = new_children,
            .kind = std.mem.span(self.kind),
        };
    }

    fn deinit(self: *Container, alloc: Allocator) void {
        freeChildren(alloc, self.children, self.children_len);
        alloc.free(std.mem.span(self.kind));
    }
};

const MySTRole = extern struct {
    children: [*]*ExposedNode,
    children_len: c_uint,
    name: [*:0]const u8,
    value: [*:0]const u8,

    fn init(alloc: Allocator, myst_role: *atrus.ast.MySTRole) !MySTRole {
        const new_children = try exposeChildren(alloc, myst_role.children);
        return .{
            .children = new_children,
            .children_len = @intCast(myst_role.children.len),
            .name = myst_role.name.ptr,
            .value = myst_role.value.ptr,
        };
    }

    fn adopt(self: *MySTRole, alloc: Allocator) !atrus.ast.MySTRole {
        const new_children = try adoptChildren(
            alloc,
            self.children,
            self.children_len,
        );
        return .{
            .children = new_children,
            .name = std.mem.span(self.name),
            .value = std.mem.span(self.value),
        };
    }

    fn deinit(self: *MySTRole, alloc: Allocator) void {
        freeChildren(alloc, self.children, self.children_len);
        alloc.free(std.mem.span(self.name));
        alloc.free(std.mem.span(self.value));
    }
};

const MySTRoleError = extern struct {
    value: [*:0]const u8,

    fn init(
        alloc: Allocator,
        myst_role_error: *atrus.ast.MySTRoleError,
    ) !MySTRoleError {
        _ = alloc;
        return .{
            .value = myst_role_error.value.ptr,
        };
    }

    fn adopt(self: *MySTRoleError, alloc: Allocator) !atrus.ast.MySTRoleError {
        _ = alloc;
        return .{
            .value = std.mem.span(self.value),
        };
    }

    fn deinit(self: *MySTRoleError, alloc: Allocator) void {
        alloc.free(std.mem.span(self.value));
    }
};

const Abbreviation = extern struct {
    children: [*]*ExposedNode,
    children_len: c_uint,
    title: [*:0]const u8,

    fn init(alloc: Allocator, abbrev: *atrus.ast.Abbreviation) !Abbreviation {
        const new_children = try exposeChildren(alloc, abbrev.children);
        return .{
            .children = new_children,
            .children_len = @intCast(abbrev.children.len),
            .title = abbrev.title.ptr,
        };
    }

    fn adopt(self: *Abbreviation, alloc: Allocator) !atrus.ast.Abbreviation {
        const new_children = try adoptChildren(
            alloc,
            self.children,
            self.children_len,
        );
        return .{
            .children = new_children,
            .title = std.mem.span(self.title),
        };
    }

    fn deinit(self: *Abbreviation, alloc: Allocator) void {
        freeChildren(alloc, self.children, self.children_len);
        alloc.free(std.mem.span(self.title));
    }
};

const MySTDirective = extern struct {
    children: [*]*ExposedNode,
    children_len: c_uint,
    name: [*:0]const u8,
    args: [*:0]const u8,
    value: [*:0]const u8,

    fn init(
        alloc: Allocator,
        myst_directive: *atrus.ast.MySTDirective,
    ) !MySTDirective {
        const new_children = try exposeChildren(
            alloc,
            myst_directive.children,
        );
        return .{
            .children = new_children,
            .children_len = @intCast(myst_directive.children.len),
            .name = myst_directive.name.ptr,
            .args = myst_directive.args.ptr,
            .value = myst_directive.value.ptr,
        };
    }

    fn adopt(self: *MySTDirective, alloc: Allocator) !atrus.ast.MySTDirective {
        const new_children = try adoptChildren(
            alloc,
            self.children,
            self.children_len,
        );
        return .{
            .children = new_children,
            .name = std.mem.span(self.name),
            .args = std.mem.span(self.args),
            .value = std.mem.span(self.value),
        };
    }

    fn deinit(self: *MySTDirective, alloc: Allocator) void {
        freeChildren(alloc, self.children, self.children_len);
        alloc.free(std.mem.span(self.name));
        alloc.free(std.mem.span(self.args));
        alloc.free(std.mem.span(self.value));
    }
};

const MySTDirectiveError = extern struct {
    children: [*]*ExposedNode,
    children_len: c_uint,
    message: [*:0]const u8,

    fn init(
        alloc: Allocator,
        directive_error: *atrus.ast.MySTDirectiveError,
    ) !MySTDirectiveError {
        const new_children = try exposeChildren(
            alloc,
            directive_error.children,
        );
        return .{
            .children = new_children,
            .children_len = @intCast(directive_error.children.len),
            .message = directive_error.message.ptr,
        };
    }

    fn adopt(
        self: *MySTDirectiveError,
        alloc: Allocator,
    ) !atrus.ast.MySTDirectiveError {
        const new_children = try adoptChildren(
            alloc,
            self.children,
            self.children_len,
        );
        return .{
            .children = new_children,
            .message = std.mem.span(self.message),
        };
    }

    fn deinit(self: *MySTDirectiveError, alloc: Allocator) void {
        freeChildren(alloc, self.children, self.children_len);
        alloc.free(std.mem.span(self.message));
    }
};

const Admonition = extern struct {
    children: [*]*ExposedNode,
    children_len: c_uint,
    kind: [*:0]const u8,

    fn init(alloc: Allocator, admonition: *atrus.ast.Admonition) !Admonition {
        const new_children = try exposeChildren(alloc, admonition.children);
        return .{
            .children = new_children,
            .children_len = @intCast(admonition.children.len),
            .kind = admonition.kind.ptr,
        };
    }

    fn adopt(self: *Admonition, alloc: Allocator) !atrus.ast.Admonition {
        const new_children = try adoptChildren(
            alloc,
            self.children,
            self.children_len,
        );
        return .{
            .children = new_children,
            .kind = std.mem.span(self.kind),
        };
    }

    fn deinit(self: *Admonition, alloc: Allocator) void {
        freeChildren(alloc, self.children, self.children_len);
        alloc.free(std.mem.span(self.kind));
    }
};

fn exposeChildren(
    alloc: Allocator,
    children: []*atrus.ast.Node,
) Allocator.Error![*]*ExposedNode {
    const new_children = try alloc.alloc(*ExposedNode, children.len);
    for (children, 0..) |child, i| {
        const new_child = try alloc.create(ExposedNode);
        new_child.* = try ExposedNode.init(alloc, child);
        new_children[i] = new_child;
    }
    return new_children.ptr;
}

fn adoptChildren(
    alloc: Allocator,
    children: [*]*ExposedNode,
    children_len: c_uint,
) Allocator.Error![]*atrus.ast.Node {
    const new_children = try alloc.alloc(*atrus.ast.Node, children_len);
    for (0..children_len) |i| {
        new_children[i] = try children[i].adopt(alloc);
    }
    return new_children;
}

fn freeChildren(alloc: Allocator, children: [*]*ExposedNode, n: c_uint) void {
    const sliced = children[0..n];
    for (sliced) |child| {
        child.deinit(alloc);
    }
    alloc.free(sliced);
}

/// An "exposed", C-ABI-compatible AST node.
const ExposedNode = extern struct {
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
    },
    tag: atrus.ast.NodeType,

    /// Initializes an ExposedNode from a normal libatrus node.
    fn init(
        alloc: Allocator,
        node: *atrus.ast.Node,
    ) Allocator.Error!ExposedNode {
        return .{
            .tag = node.*,
            .payload = switch (node.*) {
                inline .@"break", .thematic_break => |_, tag| blk: {
                    const PayloadUnion = @FieldType(ExposedNode, "payload");
                    break :blk @unionInit(PayloadUnion, @tagName(tag), void{});
                },
                inline else => |*n, tag| blk: {
                    const PayloadUnion = @FieldType(ExposedNode, "payload");
                    const Payload = @FieldType(PayloadUnion, @tagName(tag));
                    const payload = try Payload.init(alloc, n);
                    break :blk @unionInit(
                        PayloadUnion,
                        @tagName(tag),
                        payload,
                    );
                },
            },
        };
    }

    /// Turns this exposed node back into a normal libatrus node.
    fn adopt(self: *ExposedNode, alloc: Allocator) !*atrus.ast.Node {
        const adopted_node = try alloc.create(atrus.ast.Node);
        adopted_node.* = switch (self.tag) {
            inline .@"break", .thematic_break => |tag| @unionInit(
                atrus.ast.Node,
                @tagName(tag),
                void{},
            ),
            inline else => |tag| blk: {
                const exposed_payload = &@field(self.payload, @tagName(tag));
                const adopted_payload = try exposed_payload.adopt(alloc);
                break :blk @unionInit(
                    atrus.ast.Node,
                    @tagName(tag),
                    adopted_payload,
                );
            },
        };
        return adopted_node;
    }

    fn deinit(self: *ExposedNode, alloc: Allocator) void {
        switch (self.tag) {
            .@"break", .thematic_break => {},
            inline else => |tag| {
                const n = &@field(self.payload, @tagName(tag));
                n.deinit(alloc);
            },
        }

        alloc.destroy(self);
    }

    /// Cleans up the AST, but only frees memory used for the tree itself,
    /// leaving any strings owned by the tree alone.
    fn deinitTreeOnly(self: *ExposedNode, alloc: Allocator) void {
        switch (self.tag) {
            inline else => |tag| {
                if (comptime atrus.ast.HasChildren.fromNodeType(tag) == .yes) {
                    const n = @field(self.payload, @tagName(tag));
                    const sliced = n.children[0..n.children_len];
                    for (sliced) |child| {
                        child.deinitTreeOnly(alloc);
                    }
                    alloc.free(sliced);
                }
            },
        }

        alloc.destroy(self);
    }
};

// TODO: Error return values.
export fn atrus_expose(node: *atrus.ast.Node, out: **ExposedNode) c_int {
    // Free old AST.
    defer node.deinitTreeOnly(c_alloc);

    const exposed_node = c_alloc.create(ExposedNode) catch {
        return -1;
    };
    exposed_node.* = ExposedNode.init(c_alloc, node) catch {
        return -1;
    };

    out.* = exposed_node;
    return 0;
}

export fn atrus_name(node_type: atrus.ast.NodeType) [*:0]const u8 {
    return node_type.name();
}

// TODO: Error return values.
export fn atrus_adopt(node: *ExposedNode, out: **atrus.ast.Node) c_int {
    // Free old AST.
    defer node.deinitTreeOnly(c_alloc);

    out.* = node.adopt(c_alloc) catch {
        return -1;
    };

    return 0;
}

export fn atrus_free_exposed(node: *ExposedNode) void {
    node.deinit(c_alloc);
}

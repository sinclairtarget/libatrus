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
        const value = try alloc.dupeZ(u8, text.value);
        return .{
            .value = value.ptr,
        };
    }

    fn adopt(self: *Text, alloc: Allocator) !atrus.ast.Text {
        const value = std.mem.span(self.value);
        return .{
            .value = try alloc.dupeZ(u8, value),
        };
    }

    fn deinit(self: Text, alloc: Allocator) void {
        alloc.free(std.mem.span(self.value));
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
    },
    tag: atrus.ast.NodeType,

    /// Initializes an ExposedNode from a normal libatrus node.
    fn init(
        alloc: Allocator,
        node: *atrus.ast.Node,
    ) Allocator.Error!ExposedNode {
        // TODO: Use comptime to make this less verbose.
        return .{
            .tag = node.*,
            .payload = switch (node.*) {
                .root => |*n| .{
                    .root = try Root.init(alloc, n),
                },
                .block => |*n| .{
                    .block = try Wrapper.init(alloc, n),
                },
                .paragraph => |*n| .{
                    .paragraph = try Wrapper.init(alloc, n),
                },
                .heading => |*n| .{
                    .heading = try Heading.init(alloc, n),
                },
                .text => |*n| .{
                    .text = try Text.init(alloc, n),
                },
                else => @panic("unimplemented node type"),
            },
        };
    }

    /// Turns this exposed node back into a normal libatrus node.
    fn adopt(self: *ExposedNode, alloc: Allocator) !*atrus.ast.Node {
        const adopted_node = try alloc.create(atrus.ast.Node);
        adopted_node.* = switch (self.tag) {
            inline .root, .block, .heading, .paragraph, .text => |tag| blk: {
                const exposed_payload = &@field(self.payload, @tagName(tag));
                const adopted_payload = try exposed_payload.adopt(alloc);
                break :blk @unionInit(
                    atrus.ast.Node,
                    @tagName(tag),
                    adopted_payload,
                );
            },
            else => @panic("unimplemented node type"),
        };
        return adopted_node;
    }

    fn deinit(self: *ExposedNode, alloc: Allocator) void {
        switch (self.tag) {
            inline .root, .block, .heading, .paragraph, .text => |tag| {
                const n = &@field(self.payload, @tagName(tag));
                n.deinit(alloc);
            },
            else => @panic("unimplemented node type"),
        }

        alloc.destroy(self);
    }
};

// TODO: Error return values.
export fn atrus_expose(node: *atrus.ast.Node, out: **ExposedNode) c_int {
    // Free old AST.
    defer node.deinit(c_alloc);

    const exposed_node = c_alloc.create(ExposedNode) catch {
        return -1;
    };
    exposed_node.* = ExposedNode.init(c_alloc, node) catch {
        return -1;
    };

    out.* = exposed_node;
    return 0;
}

// TODO: Error return values.
export fn atrus_adopt(node: *ExposedNode, out: **atrus.ast.Node) c_int {
    // Free old AST.
    defer node.deinit(c_alloc);

    out.* = node.adopt(c_alloc) catch {
        return -1;
    };

    return 0;
}

export fn atrus_free_exposed(node: *ExposedNode) void {
    node.deinit(c_alloc);
}

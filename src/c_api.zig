//! Implements the C-ABI-compatible interface to libatrus.
//!
//! See include/atrus.h for usage documentation.
//!
//! TODO: Better error handling; return error code enums.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const atrus = @import("atrus");
const ParseError = atrus.ParseError;
const RenderJSONError = atrus.RenderJSONError;
const RenderHTMLError = atrus.RenderHTMLError;

const c_alloc = std.heap.c_allocator;

export fn atrus_version() [*:0]const u8 {
    return atrus.version[0.. :0];
}

export fn atrus_version_at_least(
    major: c_int,
    minor: c_int,
    patch: c_int,
) bool {
    const version: std.SemanticVersion = .{
        .major = @intCast(major),
        .minor = @intCast(minor),
        .patch = @intCast(patch),
    };

    const link_version = std.SemanticVersion.parse(atrus.version) catch
        @panic("could not parse linked libatrus version");

    return std.SemanticVersion.order(link_version, version) != .lt;
}

// ----------------------------------------------------------------------------
// Top-Level API
// ----------------------------------------------------------------------------
const ParseLevel = enum(c_uint) {
    post = 0, // Use zero for the default.
    pre = 1,
    block = 2,
    raw = 3,
};

export fn atrus_parse(
    in: [*:0]const u8,
    out: **atrus.ast.Node,
    parse_level: c_uint,
) c_int {
    var reader = Io.Reader.fixed(std.mem.span(in));

    const options: atrus.ParseOptions = .{
        .parse_level = switch (@as(ParseLevel, @enumFromInt(parse_level))) {
            .block => .block,
            .raw => .raw,
            .pre => .pre,
            .post => .post,
        },
    };

    out.* = atrus.parse(c_alloc, &reader, options) catch |err| {
        switch (err) {
            ParseError.ReadFailed => return -1,
            else => return -2,
        }
    };

    return 0;
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

const WhitespaceOption = enum(c_uint) {
    minified = 0,
    indent_2 = 1,
    indent_4 = 2,
};

export fn atrus_render_json(
    root: *atrus.ast.Node,
    out: *[*:0]const u8,
    whitespace_option: c_uint,
) c_int {
    var buf = Io.Writer.Allocating.init(c_alloc);
    const options: atrus.JSONOptions = .{
        .whitespace = switch (@as(
            WhitespaceOption,
            @enumFromInt(whitespace_option),
        )) {
            .minified => .minified,
            .indent_2 => .indent_2,
            .indent_4 => .indent_4,
        },
    };
    atrus.renderJSON(root, &buf.writer, options) catch |err| {
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

export fn atrus_free(root: *atrus.ast.Node) void {
    root.deinit(c_alloc);
}

// ----------------------------------------------------------------------------
// Node API
// ----------------------------------------------------------------------------
const child_out_of_bounds_panic_msg = "child index out of bounds";

export fn atrus_node_type(node: *atrus.ast.Node) atrus.ast.NodeType {
    return node.*;
}

export fn atrus_node_type_name(node: *atrus.ast.Node) [*:0]const u8 {
    return node.name();
}

export fn atrus_node_num_children(node: *atrus.ast.Node) c_uint {
    return @intCast(switch (node.hasChildren()) {
        .no => 0,
        .yes => |branch_node| switch (branch_node) {
            inline else => |n| n.children.len,
        },
    });
}

export fn atrus_node_child(node: *atrus.ast.Node, i: c_uint) *atrus.ast.Node {
    return switch (node.hasChildren()) {
        .no => @panic(child_out_of_bounds_panic_msg),
        .yes => |branch_node| switch (branch_node) {
            inline else => |n| {
                if (i >= n.children.len) {
                    @panic(child_out_of_bounds_panic_msg);
                }

                return n.children[i];
            },
        },
    };
}

export fn atrus_node_replace_child(
    node: *atrus.ast.Node,
    i: c_uint,
    new_child_node: *atrus.ast.Node,
) void {
    switch (node.hasChildren()) {
        .no => @panic(child_out_of_bounds_panic_msg),
        .yes => |branch_node| switch (branch_node) {
            inline else => |n| {
                if (i >= n.children.len) {
                    @panic(child_out_of_bounds_panic_msg);
                }

                const old_node = n.children[i];
                defer old_node.deinit(c_alloc);

                n.children[i] = new_child_node;
            },
        },
    }
}

// --- Heading ----------------------------------------------------------------
export fn atrus_node_heading_depth(node: *atrus.ast.Node) c_uint {
    return node.heading.depth;
}

export fn atrus_node_heading_create(
    out: **atrus.ast.Node,
    depth: c_uint,
) c_int {
    const heading = c_alloc.create(atrus.ast.Node) catch return -1;
    heading.* = .{
        .heading = .{
            .depth = @intCast(depth),
            .children = &.{},
        },
    };
    out.* = heading;
    return 0;
}

// ----Text -------------------------------------------------------------------
export fn atrus_node_text_value(node: *atrus.ast.Node) [*:0]const u8 {
    return node.text.value;
}

export fn atrus_node_text_create(
    out: **atrus.ast.Node,
    value: [*:0]const u8,
) c_int {
    const owned_value = c_alloc.dupeZ(u8, std.mem.span(value)) catch return -1;
    errdefer c_alloc.free(owned_value);

    const text = c_alloc.create(atrus.ast.Node) catch return -1;
    text.* = .{
        .text = .{
            .value = owned_value,
        },
    };
    out.* = text;
    return 0;
}

// --- HTML -------------------------------------------------------------------
export fn atrus_node_html_value(node: *atrus.ast.Node) [*:0]const u8 {
    return node.html.value;
}

export fn atrus_node_html_create(
    out: **atrus.ast.Node,
    value: [*:0]const u8,
) c_int {
    const owned_value = c_alloc.dupeZ(u8, std.mem.span(value)) catch return -1;
    errdefer c_alloc.free(owned_value);

    const html = c_alloc.create(atrus.ast.Node) catch return -1;
    html.* = .{
        .html = .{
            .value = owned_value,
        },
    };
    out.* = html;
    return 0;
}

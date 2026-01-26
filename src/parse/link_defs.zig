//! Store link definitions for lookup.

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMapUnmanaged = std.hash_map.StringHashMapUnmanaged;

const ast = @import("ast.zig");

pub const Error = Allocator.Error;

pub const LinkDefMap = StringHashMapUnmanaged(*ast.LinkDefinition);

/// Returns a hashmap mapping link labels to link definition nodes in the given
/// AST.
///
/// The returned hashmap is valid as long as the link definition nodes are
/// valid. If the AST is freed or the link definition nodes are removed from the
/// tree the hashmap will contain dangling pointers.
///
/// The caller owns the memory used for the hashmap itself.
pub fn mapLinkDefs(alloc: Allocator, root: *ast.Node) Error!LinkDefMap {
    var map: LinkDefMap = .empty;
    try fillLinkDefs(alloc, root, &map);
    return map;
}

fn fillLinkDefs(
    alloc: Allocator,
    root: *ast.Node,
    map: *LinkDefMap,
) Error!void {
    switch (root.*) {
        .root => |n| {
            for (n.children) |node| {
                try fillLinkDefs(alloc, node, map);
            }
        },
        .block, .paragraph, .emphasis, .strong => |n| {
            for (n.children) |node| {
                try fillLinkDefs(alloc, node, map);
            }
        },
        .heading => |n| {
            for (n.children) |node| {
                try fillLinkDefs(alloc, node, map);
            }
        },
        .definition => |*n| {
            try map.put(alloc, n.label, n);
        },
        .text, .code, .thematic_break, .inline_code, .link, .image => {},
    }
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

test "can map single link def" {
    var def: ast.Node = .{
        .definition = .{
            .url = "/foo",
            .title = "bar",
            .label = "bim",
        },
    };
    var children = [_]*ast.Node{&def};
    var root: ast.Node = .{
        .root = .{
            .children = &children,
        },
    };

    var map = try mapLinkDefs(testing.allocator, &root);
    defer map.deinit(testing.allocator);

    try testing.expectEqual(1, map.count());

    const val = map.get("bim") orelse unreachable;
    try testing.expectEqual("/foo", val.url);
    try testing.expectEqual("bar", val.title);
}

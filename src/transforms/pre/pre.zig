const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../../ast.zig");
const DefStore = @import("../../lookup/DefStore.zig");
const roles = @import("roles.zig");
const directives = @import("directives.zig");
const footnotes = @import("footnotes.zig");

/// Apply all "pre" stage transformations.
pub fn transform(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
    def_store: DefStore,
) !*ast.Node {
    // built-in rols and directives
    var node = try roles.transform(alloc, scratch, original_node);
    node = try directives.transform(alloc, scratch, node);

    // links and footnotes
    // careful... these transformations invalidate the def store because they
    // remove nodes from the tree
    node = try footnotes.transform(alloc, node, def_store);
    node = try transformDropLinkDefininitions(alloc, node);

    return node;
}

/// Removes all link definitions from the AST.
fn transformDropLinkDefininitions(
    alloc: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    switch (original_node.allowedChildren()) {
        .yes => |branch_node| switch (branch_node) {
            inline else => |n| {
                // If we have any definition children, replace the children
                // slice with a copy that skips the definitions.

                var num_definitions: u32 = 0;
                for (n.children) |child| {
                    switch (child.*) {
                        .definition => num_definitions += 1,
                        else => {},
                    }
                }

                if (num_definitions > 0) {
                    const new_children = try alloc.alloc(
                        *ast.Node,
                        n.children.len - num_definitions,
                    );
                    var i: usize = 0;
                    for (n.children) |child| {
                        switch (child.*) {
                            .definition => {
                                child.deinit(alloc);
                            },
                            else => {
                                new_children[i] = child;
                                i += 1;
                            },
                        }
                    }
                    alloc.free(n.children);
                    n.children = new_children;
                } else {
                    for (0..n.children.len) |i| {
                        n.children[i] = try transformDropLinkDefininitions(
                            alloc,
                            n.children[i],
                        );
                    }
                }

                return original_node;
            },
        },
        .no => return original_node,
    }
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

test "remove link definition nodes" {
    const def_node = try testing.allocator.create(ast.Node);
    def_node.* = .{
        .definition = .{
            .label = try testing.allocator.dupeZ(u8, "my label"),
            .url = try testing.allocator.dupeZ(u8, "http://cool.com"),
            .title = try testing.allocator.dupeZ(u8, "my title"),
        },
    };

    const root_node = try testing.allocator.create(ast.Node);
    root_node.* = .{
        .root = .{
            .children = try testing.allocator.dupe(*ast.Node, &.{def_node}),
        },
    };

    const transformed_node = try transformDropLinkDefininitions(
        testing.allocator,
        root_node,
    );
    defer transformed_node.deinit(testing.allocator);

    try testing.expectEqual(0, transformed_node.root.children.len);
}

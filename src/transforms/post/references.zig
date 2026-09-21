const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../../ast.zig");
const myst = @import("../../myst/myst.zig");

pub fn transform(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    var node = original_node;

    node = try transformTargets(alloc, scratch, node);

    return node;
}

/// Handles all reference targets in the tree, applying them to their next
/// sibling.
fn transformTargets(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    switch (original_node.allowedChildren()) {
        .yes => |branch_node| switch (branch_node) {
            inline else => |n| {
                if (n.children.len == 0) {
                    return original_node;
                }

                // recurse first
                for (0..n.children.len) |i| {
                    n.children[i] = try transformTargets(
                        alloc,
                        scratch,
                        n.children[i],
                    );
                }

                // now handle reference targets
                const old_children = n.children;
                defer alloc.free(old_children);

                const new_children = try alloc.alloc(
                    *ast.Node,
                    n.children.len,
                );

                var new_children_i: usize = 0;
                for (0..n.children.len - 1, 1..n.children.len) |i, j| {
                    const target = switch (n.children[i].*) {
                        .target => |target_n| target_n,
                        else => {
                            new_children[new_children_i] = n.children[i];
                            new_children_i += 1;
                            continue;
                        },
                    };
                    switch (n.children[j].*) {
                        inline .code, .heading => |*applied_n| {
                            if (applied_n.label != null) continue;
                            applied_n.label = try alloc.dupeZ(
                                u8,
                                target.label,
                            );

                            const id = try myst.references.normalizeIdentifier(
                                scratch,
                                target.label,
                            );
                            applied_n.identifier = try alloc.dupeZ(u8, id);

                            n.children[i].deinit(alloc);
                        },
                        else => {
                            new_children[new_children_i] = n.children[i];
                            new_children_i += 1;
                        },
                    }
                }

                new_children[new_children_i] = n.children[n.children.len - 1];
                new_children_i += 1;

                n.children = try alloc.realloc(new_children, new_children_i);

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
const util = @import("../../util/util.zig");

test "apply reference target to code block" {
    const target_node = try testing.allocator.create(ast.Node);
    target_node.* = .{
        .target = .{
            .label = try testing.allocator.dupeZ(u8, "Foo"),
        },
    };

    const code_node = try testing.allocator.create(ast.Node);
    code_node.* = .{
        .code = .{
            .value = try testing.allocator.dupeZ(u8, "def foo():\n    pass"),
            .lang = try testing.allocator.dupeZ(u8, "python"),
        },
    };

    const root_node: *ast.Node = blk: {
        const node = try testing.allocator.create(ast.Node);
        const children = try testing.allocator.dupe(*ast.Node, &[_]*ast.Node{
            target_node,
            code_node,
        });
        node.* = .{
            .root = .{ .children = children },
        };
        break :blk node;
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const post_node = try transform(
        testing.allocator,
        arena.allocator(),
        root_node,
    );
    defer post_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, post_node.*));
    try testing.expectEqual(1, post_node.root.children.len);

    const post_code_node = post_node.root.children[0];
    try testing.expectEqual(.code, @as(ast.NodeType, post_code_node.*));

    const label = try util.testing.expectNonNull(post_code_node.code.label);
    try testing.expectEqualStrings("Foo", label);

    const identifier = try util.testing.expectNonNull(
        post_code_node.code.identifier,
    );
    try testing.expectEqualStrings("foo", identifier);
}

test "handle reference target with no next sibling" {
    const target_node = try testing.allocator.create(ast.Node);
    target_node.* = .{
        .target = .{
            .label = try testing.allocator.dupeZ(u8, "Foo"),
        },
    };

    const root_node: *ast.Node = blk: {
        const node = try testing.allocator.create(ast.Node);
        const children = try testing.allocator.dupe(*ast.Node, &[_]*ast.Node{
            target_node,
        });
        node.* = .{
            .root = .{ .children = children },
        };
        break :blk node;
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const post_node = try transform(
        testing.allocator,
        arena.allocator(),
        root_node,
    );
    defer post_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, post_node.*));

    // Reference target node should stay in AST.
    try testing.expectEqual(1, post_node.root.children.len);
    const post_target_node = post_node.root.children[0];
    try testing.expectEqual(.target, @as(ast.NodeType, post_target_node.*));
}

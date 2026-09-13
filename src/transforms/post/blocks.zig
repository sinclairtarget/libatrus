const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const ast = @import("../../ast.zig");

/// Groups immediate children of the root node under blocks.
///
/// A block break begins a new block.
///
/// If there are block breaks in deeper nodes of the AST, they are left in
/// place.
pub fn transform(alloc: Allocator, node: *ast.Node) !*ast.Node {
    if (@as(ast.NodeType, node.*) != .root) {
        // This transformation should only be done on the root node.
        return node;
    }

    const original_children = node.root.children;
    defer alloc.free(original_children);

    var new_children: ArrayList(*ast.Node) = .empty;

    var current_block: ?*ast.Node = null;
    for (original_children) |child| {
        switch (child.*) {
            .block => {
                current_block = child;
            },
            .block_break => |n| {
                if (current_block) |block| {
                    try new_children.append(alloc, block);
                }

                current_block = try createBlockNode(alloc, n.meta);

                // This block break has served its purpose.
                child.deinit(alloc);
            },
            .footnote_definition => {
                // Footnote definitions always go outside of blocks at the end
                // of the AST. So we skip them for now.
            },
            else => {
                current_block = current_block orelse
                    try createBlockNode(alloc, "");

                // TODO: Find more efficient way to do this?
                try current_block.?.appendChild(alloc, child);
            },
        }
    }

    // Make sure we always have at least one block even if the root node
    // had no children.
    const last_block = current_block orelse try createBlockNode(alloc, "");
    try new_children.append(alloc, last_block);

    // Okay, now add trailing footnote definitions
    for (original_children) |child| {
        switch (child.*) {
            .footnote_definition => {
                try new_children.append(alloc, child);
            },
            else => {},
        }
    }

    node.root.children = try new_children.toOwnedSlice(alloc);
    return node;
}

fn createBlockNode(alloc: Allocator, meta: []const u8) !*ast.Node {
    const new = try alloc.create(ast.Node);
    new.* = .{
        .block = .{
            .children = &.{},
            .meta = try alloc.dupeZ(u8, meta),
        },
    };
    return new;
}

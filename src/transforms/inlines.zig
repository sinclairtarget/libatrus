const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;

const ast = @import("../ast.zig");
const InlineTokenizer = @import("../lex/InlineTokenizer.zig");
const InlineParser = @import("../parse/InlineParser.zig");
const DefStore = @import("../lookup/DefStore.zig");

/// Recursively transform AST nodes by parsing inline content.
pub fn transform(
    alloc: Allocator,
    scratch_arena: *ArenaAllocator,
    original_node: *ast.Node,
    def_store: DefStore,
) !*ast.Node {
    switch (original_node.*) {
        inline .root,
        .block,
        .blockquote,
        .list,
        .footnote_definition,
        .table,
        .table_row,
        => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(
                    alloc,
                    scratch_arena,
                    n.children[i],
                    def_store,
                );
            }
            return original_node;
        },
        .list_item => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(
                    alloc,
                    scratch_arena,
                    n.children[i],
                    def_store,
                );
            }

            const new_children = try parseInline(
                alloc,
                scratch_arena,
                n.children,
                def_store,
            );
            if (new_children.ptr == n.children.ptr) {
                return original_node; // nothing was changed
            }
            defer alloc.free(n.children);
            defer alloc.destroy(original_node);

            const node = try alloc.create(ast.Node);
            node.* = .{
                .list_item = .{
                    .children = new_children,
                    .spread = n.spread,
                },
            };
            return node;
        },
        .table_cell => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(
                    alloc,
                    scratch_arena,
                    n.children[i],
                    def_store,
                );
            }

            const new_children = try parseInline(
                alloc,
                scratch_arena,
                n.children,
                def_store,
            );
            if (new_children.ptr == n.children.ptr) {
                return original_node; // nothing was changed
            }
            defer alloc.free(n.children);
            defer alloc.destroy(original_node);

            const node = try alloc.create(ast.Node);
            node.* = .{
                .table_cell = .{
                    .children = new_children,
                    .header = n.header,
                    .@"align" = n.@"align",
                },
            };
            return node;
        },
        .paragraph => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(
                    alloc,
                    scratch_arena,
                    n.children[i],
                    def_store,
                );
            }

            const new_children = try parseInline(
                alloc,
                scratch_arena,
                n.children,
                def_store,
            );
            if (new_children.ptr == n.children.ptr) {
                return original_node; // nothing was changed
            }
            defer alloc.free(n.children);
            defer alloc.destroy(original_node);

            const node = try alloc.create(ast.Node);
            node.* = .{
                .paragraph = .{
                    .children = new_children,
                },
            };
            return node;
        },
        .heading => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(
                    alloc,
                    scratch_arena,
                    n.children[i],
                    def_store,
                );
            }

            const new_children = try parseInline(
                alloc,
                scratch_arena,
                n.children,
                def_store,
            );
            if (new_children.ptr == n.children.ptr) {
                return original_node; // nothing was changed
            }
            defer alloc.free(n.children);
            defer alloc.destroy(original_node);

            const node = try alloc.create(ast.Node);
            node.* = .{
                .heading = .{
                    .children = new_children,
                    .depth = @intCast(n.depth),
                },
            };
            return node;
        },
        // These nodes are leaf nodes or contain no inline content
        else => return original_node,
    }
}

/// Replaces the input nodes with inline-parsed nodes.
///
/// May return more nodes than there were originally, since a given node might
/// be parsed into multiple nodes. A text node, for example, might turn into an
/// emphasis node followed by a code span node.
fn parseInline(
    alloc: Allocator,
    scratch_arena: *ArenaAllocator,
    original_nodes: []*ast.Node,
    def_store: DefStore,
) ![]*ast.Node {
    // This function resets the arena after it parses inline content within
    // each block. The arena should be empty when passed to this function.
    std.debug.assert(scratch_arena.state.end_index == 0);

    var nodes: ArrayList(*ast.Node) = .empty;
    errdefer nodes.deinit(alloc);

    var did_replace_something = false;
    for (original_nodes) |node| {
        switch (node.*) {
            .text => |n| {
                var tokenizer = InlineTokenizer.init(n.value);
                var parser = InlineParser.init(&tokenizer, def_store);
                const replacement_nodes = try parser.parse(
                    alloc,
                    scratch_arena.allocator(),
                );
                defer node.deinit(alloc);
                errdefer alloc.free(replacement_nodes);

                for (replacement_nodes) |replacement| {
                    try nodes.append(alloc, replacement);
                }

                alloc.free(replacement_nodes);
                did_replace_something = true;
            },
            else => {
                try nodes.append(alloc, node);
            },
        }

        // Clear memory used for scratch and tokenization
        _ = scratch_arena.reset(.retain_capacity);
    }

    if (!did_replace_something) {
        nodes.deinit(alloc);
        return original_nodes;
    }

    return nodes.toOwnedSlice(alloc);
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

test "parse inlines within tables" {
    const text_node = try testing.allocator.create(ast.Node);
    text_node.* = .{
        .text = .{ .value = try testing.allocator.dupeZ(u8, "*foobar*") },
    };
    const table_cell_node = try testing.allocator.create(ast.Node);
    table_cell_node.* = .{
        .table_cell = .{
            .children = try testing.allocator.dupe(*ast.Node, &.{text_node}),
            .header = false,
        },
    };
    const table_row_node = try testing.allocator.create(ast.Node);
    table_row_node.* = .{
        .table_row = .{
            .children = try testing.allocator.dupe(
                *ast.Node,
                &.{table_cell_node},
            ),
        },
    };
    const table_node = try testing.allocator.create(ast.Node);
    table_node.* = .{
        .table = .{
            .children = try testing.allocator.dupe(
                *ast.Node,
                &.{table_row_node},
            ),
        },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const post_node = try transform(
        testing.allocator,
        &arena,
        table_node,
        .empty,
    );
    defer post_node.deinit(testing.allocator);

    try testing.expectEqual(.table, @as(ast.NodeType, post_node.*));
    try testing.expectEqual(1, post_node.table.children.len);

    const post_table_row_node = post_node.table.children[0];
    try testing.expectEqual(.table_row, @as(
        ast.NodeType,
        post_table_row_node.*,
    ));
    try testing.expectEqual(1, post_table_row_node.table_row.children.len);

    const post_table_cell_node = post_table_row_node.table_row.children[0];
    try testing.expectEqual(.table_cell, @as(
        ast.NodeType,
        post_table_cell_node.*,
    ));
    try testing.expectEqual(1, post_table_cell_node.table_cell.children.len);

    const emphasis_node = post_table_cell_node.table_cell.children[0];
    try testing.expectEqual(.emphasis, @as(ast.NodeType, emphasis_node.*));
    try testing.expectEqual(1, emphasis_node.emphasis.children.len);

    const post_text_node = emphasis_node.emphasis.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, post_text_node.*));
    try testing.expectEqualStrings("foobar", post_text_node.text.value);
}

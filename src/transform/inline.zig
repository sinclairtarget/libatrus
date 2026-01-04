const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;

const ast = @import("../parse/ast.zig");
const InlineTokenizer = @import("../lex/InlineTokenizer.zig");
const InlineParser = @import("../parse/InlineParser.zig");

/// Recursively transform AST nodes by parsing inline content.
pub fn transform(
    alloc: Allocator,
    scratch_arena: *ArenaAllocator,
    original_node: *ast.Node,
) !*ast.Node {
    switch (original_node.*) {
        .root => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(
                    alloc,
                    scratch_arena,
                    n.children[i],
                );
            }
            return original_node;
        },
        .block => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(
                    alloc,
                    scratch_arena,
                    n.children[i],
                );
            }
            return original_node;
        },
        .paragraph => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(
                    alloc,
                    scratch_arena,
                    n.children[i],
                );
            }

            const children = try parseInline(alloc, scratch_arena, n.children);
            if (children.ptr == n.children.ptr) {
                return original_node; // nothing was changed
            }
            defer original_node.deinit(alloc);

            const node = try alloc.create(ast.Node);
            node.* = .{
                .paragraph = .{
                    .children = children,
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
                );
            }

            const children = try parseInline(alloc, scratch_arena, n.children);
            if (children.ptr == n.children.ptr) {
                return original_node; // nothing was changed
            }
            defer original_node.deinit(alloc);

            const node = try alloc.create(ast.Node);
            node.* = .{
                .heading = .{
                    .children = children,
                    .depth = n.depth,
                },
            };
            return node;
        },
        .text, .code, .thematic_break, .emphasis, .strong, .inline_code,
        .link => {
            return original_node;
        },
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
) ![]*ast.Node {
    // This function resets the arena after it parses inline content within each
    // block. The arena should be empty when passed to this function.
    std.debug.assert(scratch_arena.state.end_index == 0);

    var nodes: ArrayList(*ast.Node) = .empty;

    var did_replace_something = false;
    for (original_nodes) |node| {
        switch (node.*) {
            .text => |n| {
                var tokenizer = InlineTokenizer.init(n.value);
                var parser = InlineParser.init(&tokenizer);
                const replacement_nodes = try parser.parse(
                    alloc,
                    scratch_arena.allocator(),
                );
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

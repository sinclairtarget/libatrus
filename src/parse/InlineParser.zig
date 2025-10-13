const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const ast = @import("ast.zig");
const tokens = @import("../lex/tokens.zig");
const InlineToken = tokens.InlineToken;

line: ArrayList(InlineToken),
i: usize,

const Self = @This();

const init = Self{
    .line = .empty,
    .i = 0,
};

fn parse(
    self: *Self,
    gpa: Allocator,
    node: *ast.Node,
    value: []const u8,
) !*ast.Node {
    _ = self;
    _ = gpa;
    _ = value;
    return node;
}

pub fn transform(gpa: Allocator, node: *ast.Node) !*ast.Node {
    switch (node.*) {
        .root => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(gpa, n.children[i]);
            }
            return node;
        },
        .block, .paragraph => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(gpa, n.children[i]);
            }
            return node;
        },
        .heading => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(gpa, n.children[i]);
            }
            return node;
        },
        .text => |n| {
            var parser = Self.init;
            const replacement = try parser.parse(gpa, node, n.value);
            if (replacement != node) {
                node.deinit(gpa); // TODO: Make sure same gpa??
            }
            return replacement;
        },
        .code, .thematic_break => return node,
    }
}

//! Functions that take an entire AST and return a modified AST.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../parse/ast.zig");
const post = @import("post.zig");
const @"inline" = @import("inline.zig");

pub fn postProcess(gpa: Allocator, root: *ast.Node) !*ast.Node {
    return try post.transform(gpa, root);
}

pub fn parseInline(gpa: Allocator, root: *ast.Node) !*ast.Node {
    return try @"inline".transform(gpa, root);
}

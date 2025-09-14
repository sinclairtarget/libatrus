//! Abstract syntax tree for a MyST document.
//!
//! https://mystmd.org/spec
const std = @import("std");
const ArrayList = std.ArrayList;

pub const NodeType = enum {
    root,
    heading,
    paragraph,
    text,
};

pub const AstNode = union(NodeType) {
    root: Container,
    heading: Heading,
    paragraph: Container,
    text: Text,
};

pub const Container = struct {
    children: []const AstNode,
};

pub const Heading = struct {
    depth: u8,
    children: []const AstNode,
};

pub const Text = struct {
    value: []const u8,
};

//! Abstract syntax tree for a MyST document.
//!
//! https://mystmd.org/spec

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const Node = union(enum) {
    root: Root,
    block: Container,
    heading: Heading,
    paragraph: Container,
    text: Text,
    code: Code,
    thematic_break: Empty,
    emphasis: Container,

    const Self = @This();

    pub fn deinit(self: *Self, alloc: Allocator) void {
        switch (self.*) {
            .root => |n| {
                for (n.children) |child| {
                    child.deinit(alloc);
                }
                alloc.free(n.children);
            },
            .paragraph, .block, .emphasis => |n| {
                for (n.children) |child| {
                    child.deinit(alloc);
                }
                alloc.free(n.children);
            },
            .heading => |n| {
                for (n.children) |child| {
                    child.deinit(alloc);
                }
                alloc.free(n.children);
            },
            .text => |n| alloc.free(n.value),
            .code => |n| {
                alloc.free(n.value);
                alloc.free(n.lang);
            },
            .thematic_break => {},
        }

        alloc.destroy(self);
    }
};

pub const Root = struct {
    children: []*Node,
    is_post_processed: bool = false,
};

pub const Container = struct {
    children: []*Node,
};

pub const Heading = struct {
    depth: u8,
    children: []*Node,
};

pub const Text = struct {
    value: []const u8,
};

pub const Code = struct {
    value: []const u8,
    lang: []const u8,
};

pub const Empty = struct {};

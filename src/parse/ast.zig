//! Abstract syntax tree for a MyST document.
//!
//! https://mystmd.org/spec

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const NodeType = enum {
    root,
    block,
    heading,
    paragraph,
    text,
    code,
    thematic_break,
    emphasis,
    strong,
    inline_code,
    link,
    image,
};

pub const Node = union(NodeType) {
    root: Root,
    block: Container,
    heading: Heading,
    paragraph: Container,
    text: Text,
    code: Code,
    thematic_break: Empty,
    emphasis: Container,
    strong: Container,
    inline_code: Text,
    link: Link,
    image: Image,

    const Self = @This();

    /// Writes "plain text content" of node to writer.
    ///
    /// Needed primarily to create alt text for images.
    pub fn writePlainText(self: *Self, out: *Io.Writer) Io.Writer.Error!void {
        switch (self.*) {
            .thematic_break => {},
            inline else => |*payload| try payload.writePlainText(out),
        }
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        switch (self.*) {
            .thematic_break => {},
            inline else => |*payload| payload.deinit(alloc),
        }

        alloc.destroy(self);
    }
};

pub const Root = struct {
    children: []*Node,
    is_post_processed: bool = false,

    const Self = @This();

    pub fn writePlainText(self: *Self, out: *Io.Writer) !void {
        for (self.children) |child| {
            try child.writePlainText(out);
        }
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        for (self.children) |child| {
            child.deinit(alloc);
        }
        alloc.free(self.children);
    }
};

pub const Container = struct {
    children: []*Node,

    const Self = @This();

    pub fn writePlainText(self: *Self, out: *Io.Writer) !void {
        for (self.children) |child| {
            try child.writePlainText(out);
        }
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        for (self.children) |child| {
            child.deinit(alloc);
        }
        alloc.free(self.children);
    }
};

pub const Heading = struct {
    depth: u8,
    children: []*Node,

    const Self = @This();

    pub fn writePlainText(self: *Self, out: *Io.Writer) !void {
        for (self.children) |child| {
            try child.writePlainText(out);
        }
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        for (self.children) |child| {
            child.deinit(alloc);
        }
        alloc.free(self.children);
    }
};

pub const Text = struct {
    value: []const u8,

    const Self = @This();

    pub fn writePlainText(self: *Self, out: *Io.Writer) !void {
        _ = try out.write(self.value);
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        alloc.free(self.value);
    }
};

pub const Code = struct {
    value: []const u8,
    lang: []const u8,

    const Self = @This();

    pub fn writePlainText(self: *Self, out: *Io.Writer) !void {
        _ = try out.write(self.value);
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        alloc.free(self.value);
        alloc.free(self.lang);
    }
};

pub const Link = struct {
    url: []const u8,
    title: []const u8,
    children: []*Node,

    const Self = @This();

    pub fn writePlainText(self: *Self, out: *Io.Writer) !void {
        for (self.children) |child| {
            try child.writePlainText(out);
        }
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        for (self.children) |child| {
            child.deinit(alloc);
        }
        alloc.free(self.children);

        alloc.free(self.url);
        alloc.free(self.title);
    }
};

pub const Image = struct {
    url: []const u8,
    title: []const u8,
    alt: []const u8,

    const Self = @This();

    pub fn writePlainText(self: *Self, out: *Io.Writer) !void {
        _ = try out.write(self.alt);
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        alloc.free(self.url);
        alloc.free(self.title);
        alloc.free(self.alt);
    }
};

pub const Empty = struct {};

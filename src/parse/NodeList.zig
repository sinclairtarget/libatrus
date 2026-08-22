//! An ArrayList of AST nodes with special handling for text nodes (to ensure
//! we don't end up with sibling text nodes).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const ast = @import("../ast.zig");

const Self = @This();

const CreateTextNode = *const fn (
    Allocator,
    []const u8,
) Allocator.Error!*ast.Node;

allocator: Allocator,
list: ArrayList(*ast.Node),
running_text: Io.Writer.Allocating,
createTextNodeFn: CreateTextNode,
values_to_strip: []const u8,

pub fn init(
    perm: Allocator,
    scratch: Allocator,
    createTextNodeFn: CreateTextNode,
    opts: struct { values_to_strip: []const u8 = "" },
) Self {
    return .{
        .allocator = perm,
        .list = .empty,
        .running_text = Io.Writer.Allocating.init(scratch),
        .createTextNodeFn = createTextNodeFn,
        .values_to_strip = opts.values_to_strip,
    };
}

pub fn deinit(self: *Self) void {
    self.list.deinit(self.allocator);
    self.running_text.deinit();
}

pub fn len(self: *Self) usize {
    if (self.hasUnflushed()) {
        @panic("called len() on NodeList with unflushed text");
    }

    return self.list.items.len;
}

pub fn items(self: Self) []*ast.Node {
    return self.list.items;
}

pub fn hasUnflushed(self: *Self) bool {
    return self.running_text.written().len > 0;
}

pub fn append(self: *Self, node: *ast.Node) !void {
    try self.flush();
    try self.list.append(self.allocator, node);
}

pub fn appendText(self: *Self, value: []const u8) !void {
    _ = try self.running_text.writer.write(value);
}

pub fn flush(self: *Self) !void {
    try self.checkAppendCollected(self, createTextNode);
}

/// Flushes text using an override of the default create text node func.
pub fn flushToNode(
    self: *Self,
    context: anytype,
    comptime createFn: fn (
        @TypeOf(context),
        Allocator,
        []const u8,
    ) Allocator.Error!*ast.Node,
) !void {
    try self.checkAppendCollected(context, createFn);
}

/// Returns the underlying array list as a slice.
///
/// It might still be necessary to call deinit() depending on the original
/// allocators used for the NodeList.
pub fn toOwnedSlice(self: *Self) ![]*ast.Node {
    try self.checkAppendCollected(self, createTextNode);
    return try self.list.toOwnedSlice(self.allocator);
}

/// Appends a text node with any text content accumulated since we last
/// appended a node.
fn checkAppendCollected(
    self: *Self,
    context: anytype,
    comptime createFn: fn (
        @TypeOf(context),
        Allocator,
        []const u8,
    ) Allocator.Error!*ast.Node,
) !void {
    if (!self.hasUnflushed()) {
        return;
    }

    const written = self.running_text.written();
    const trimmed = std.mem.trim(u8, written, self.values_to_strip);
    if (trimmed.len > 0) {
        const node = try createFn(context, self.allocator, trimmed);
        try self.list.append(self.allocator, node);
    }

    self.running_text.clearRetainingCapacity();
}

fn createTextNode(
    context: *Self,
    alloc: Allocator,
    value: []const u8,
) !*ast.Node {
    return try context.createTextNodeFn(alloc, value);
}

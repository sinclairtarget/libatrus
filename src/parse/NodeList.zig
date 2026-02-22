//! An ArrayList of AST nodes with special handling for text nodes (to ensure we
//! don't end up with sibling text nodes).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const ast = @import("ast.zig");

const Self = @This();
const CreateTextNodeFunc = *const fn (
    alloc: Allocator,
    value: []const u8,
) Allocator.Error!*ast.Node;

allocator: Allocator,
list: ArrayList(*ast.Node),
running_text: Io.Writer.Allocating,
create_text_node: CreateTextNodeFunc,

pub fn init(
    perm: Allocator,
    scratch: Allocator,
    create_text_node: CreateTextNodeFunc,
) Self {
    return .{
        .allocator = perm,
        .list = .empty,
        .running_text = Io.Writer.Allocating.init(scratch),
        .create_text_node = create_text_node,
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
    try self.checkAppendCollected();
    try self.list.append(self.allocator, node);
}

pub fn appendText(self: *Self, value: []const u8) !void {
    _ = try self.running_text.writer.write(value);
}

pub fn flush(self: *Self) !void {
    try self.checkAppendCollected();
}

/// Returns the underlying array list as a slice.
///
/// It might still be necessary to call deinit() depending on the original
/// allocators used for the NodeList.
pub fn toOwnedSlice(self: *Self) ![]*ast.Node {
    try self.checkAppendCollected();
    return try self.list.toOwnedSlice(self.allocator);
}

/// Appends a text node with any text content accumulated since we last appended
/// a node.
fn checkAppendCollected(self: *Self) !void {
    if (!self.hasUnflushed()) {
        return;
    }

    const text = try self.create_text_node(
        self.allocator,
        self.running_text.written(),
    );
    try self.list.append(self.allocator, text);
    self.running_text.clearRetainingCapacity();
}

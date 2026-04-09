const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../ast.zig");

/// Creates a text node with the given text value.
///
/// The value is copied and owned by the returned node.
pub fn createTextNode(alloc: Allocator, value: []const u8) !*ast.Node {
    const copy = try alloc.dupeZ(u8, value);
    errdefer alloc.free(copy);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .tag = .text,
        .payload = .{
            .text = .{
                .value = copy,
            },
        },
    };
    return node;
}

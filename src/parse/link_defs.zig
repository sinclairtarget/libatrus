//! Handles normalization, storage, and lookup of link references/destinations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMapUnmanaged = std.hash_map.StringHashMapUnmanaged;

const ast = @import("ast.zig");

pub const label_max_chars = 999; // Unicode code points

pub const Error = Allocator.Error;

/// A hashmap mapping link labels to link definitions. Lookup by label is
/// case-insensitive.
///
/// The hashmap does not take ownership of the labels or link definitions. But
/// it does create its own (downcased) keys from any given link labels. These
/// copies it owns.
///
/// Entries can only ever be added to the map, never removed.
pub const LinkDefMap = struct {
    backing_map: StringHashMapUnmanaged(*ast.LinkDefinition),
    keys: ArrayList([]const u8),

    const Self = @This();

    pub const empty = Self{
        .backing_map = .empty,
        .keys = .empty,
    };

    pub fn deinit(self: *Self, alloc: Allocator) void {
        for (self.keys.items) |key| {
            alloc.free(key);
        }

        self.keys.deinit(alloc);
        self.backing_map.deinit(alloc);
    }

    /// Adds a link definition to the map using the given label.
    ///
    /// If a link definition already exists with the same label, this is a
    /// no-op. (First definition takes precedence.)
    pub fn add(
        self: *Self,
        alloc: Allocator,
        label: []const u8,
        def: *ast.LinkDefinition,
    ) Error!void {
        const key = try normalize(alloc, label);
        errdefer alloc.free(key);

        const result = try self.backing_map.getOrPut(alloc, key);
        if (result.found_existing) {
            alloc.free(key);
            return;
        }

        try self.keys.append(alloc, key);
        result.value_ptr.* = def;
    }

    pub fn get(
        self: Self,
        alloc: Allocator,
        label: []const u8,
    ) Error!?*ast.LinkDefinition {
        const key = try normalize(alloc, label);
        defer alloc.free(key);
        return self.backing_map.get(key);
    }

    pub fn count(self: Self) u32 {
        return self.backing_map.count();
    }
};

/// Returns a hashmap mapping link labels to link definition nodes in the given
/// AST.
///
/// The returned hashmap is valid as long as the link definition nodes are
/// valid. If the AST is freed or the link definition nodes are removed from the
/// tree the hashmap will contain dangling pointers.
///
/// The caller owns the memory used for the returned hashmap itself.
pub fn buildMap(alloc: Allocator, root: *ast.Node) Error!LinkDefMap {
    var map: LinkDefMap = .empty;
    try fillLinkDefs(alloc, root, &map);
    return map;
}

fn fillLinkDefs(
    alloc: Allocator,
    root: *ast.Node,
    map: *LinkDefMap,
) Error!void {
    switch (root.*) {
        inline .root, .block => |n| {
            for (n.children) |node| {
                try fillLinkDefs(alloc, node, map);
            }
        },
        .definition => |*n| {
            try map.add(alloc, n.label, n);
        },
        .paragraph, .heading, .strong, .emphasis, .text, .code, .thematic_break,
        .inline_code, .link, .image => {},
    }
}

/// Normalizes the given link label, returning a new string.
///
/// Caller owns the returned string.
fn normalize(alloc: Allocator, link_label: []const u8) Error![]const u8 {
    // TODO: Non-ascii lowercase
    return try std.ascii.allocLowerString(alloc, link_label);
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;
const util = @import("../util/util.zig");

test "can map single link def" {
    var def: ast.Node = .{
        .definition = .{
            .url = "/foo",
            .title = "bar",
            .label = "bim",
        },
    };
    var children = [_]*ast.Node{&def};
    var root: ast.Node = .{
        .root = .{
            .children = &children,
        },
    };

    var map = try buildMap(testing.allocator, &root);
    defer map.deinit(testing.allocator);

    try testing.expectEqual(1, map.count());

    const val = try util.testing.expectNonNull(
        try map.get(testing.allocator, "bim"),
    );
    try testing.expectEqual("/foo", val.url);
    try testing.expectEqual("bar", val.title);
}

test "first link def takes precedence" {
    var def1: ast.Node = .{
        .definition = .{
            .url = "/foo",
            .title = "bar",
            .label = "bim",
        },
    };
    var def2: ast.Node = .{
        .definition = .{
            .url = "/zap",
            .title = "zim",
            .label = "bim",
        },
    };
    var children = [_]*ast.Node{&def1, &def2};
    var root: ast.Node = .{
        .root = .{
            .children = &children,
        },
    };

    var map = try buildMap(testing.allocator, &root);
    defer map.deinit(testing.allocator);

    try testing.expectEqual(1, map.count());

    const val = try util.testing.expectNonNull(
        try map.get(testing.allocator, "bim"),
    );
    try testing.expectEqual("/foo", val.url);
    try testing.expectEqual("bar", val.title);
}

test "match is case-insensitive" {
    var def: ast.Node = .{
        .definition = .{
            .url = "/foo",
            .title = "bar",
            .label = "bim",
        },
    };
    var children = [_]*ast.Node{&def};
    var root: ast.Node = .{
        .root = .{
            .children = &children,
        },
    };

    var map = try buildMap(testing.allocator, &root);
    defer map.deinit(testing.allocator);

    try testing.expectEqual(1, map.count());

    const val = try util.testing.expectNonNull(
        try map.get(testing.allocator, "Bim"),
    );
    try testing.expectEqual("/foo", val.url);
    try testing.expectEqual("bar", val.title);
}

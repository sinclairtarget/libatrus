//! Handles normalization, storage, and lookup of link references/destinations.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMapUnmanaged = std.hash_map.StringHashMapUnmanaged;

const ast = @import("../ast.zig");
const logger = @import("../logging.zig").logger;

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

    /// Adds a link definition to the map using the label on the given link
    /// definition.
    ///
    /// If a link definition already exists with the same label, this is a
    /// no-op. (First definition takes precedence.)
    pub fn add(
        self: *Self,
        alloc: Allocator,
        def: *ast.LinkDefinition,
    ) Error!void {
        const key = try normalize(alloc, def.label);
        errdefer alloc.free(key);

        const result = try self.backing_map.getOrPut(alloc, key);
        if (result.found_existing) {
            alloc.free(key);
            return;
        }

        try self.keys.append(alloc, key);
        result.value_ptr.* = def;

        logger.debug(
            "Added link reference definition under key \"{s}\".",
            .{key},
        );
    }

    pub fn get(
        self: Self,
        alloc: Allocator,
        label: []const u8,
    ) Error!?*ast.LinkDefinition {
        const key = try normalize(alloc, label);
        defer alloc.free(key);

        const value = self.backing_map.get(key);
        if (value == null) {
            logger.debug(
                "Link reference definition lookup failed for key \"{s}\".",
                .{key},
            );
        }

        return value;
    }

    pub fn count(self: Self) u32 {
        return self.backing_map.count();
    }
};

/// Normalizes the given link label, returning a new string.
///
/// To normalize a label, perform the Unicode case fold, strip leading and
/// trailing spaces, tabs, and line endings, and collapse consecutive internal
/// spaces, tabs, and line endings to a single space.
///
/// https://spec.commonmark.org/0.30/#matches
///
/// Caller owns the returned string.
fn normalize(alloc: Allocator, link_label: []const u8) Error![]const u8 {
    const trimmed = std.mem.trim(u8, link_label, " \t\n");

    // collapse interior whitespace
    const buf = try alloc.alloc(u8, trimmed.len);
    defer alloc.free(buf);

    var buf_i: usize = 0;
    var skippping_whitespace = false;
    for (trimmed) |c| {
        if (std.ascii.isWhitespace(c)) {
            if (skippping_whitespace) {
                continue;
            }

            buf[buf_i] = ' ';
            buf_i += 1;
            skippping_whitespace = true;
            continue;
        }

        buf[buf_i] = c;
        buf_i += 1;
        skippping_whitespace = false;
    }

    // TODO: Unicode case fold
    return try std.ascii.allocLowerString(alloc, buf[0..buf_i]);
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;
const util = @import("../util/util.zig");

test "can map single link def" {
    var def: ast.LinkDefinition = .{
        .url = "/foo",
        .title = "bar",
        .label = "bim",
    };

    var map: LinkDefMap = .empty;
    defer map.deinit(testing.allocator);

    try map.add(testing.allocator, &def);

    try testing.expectEqual(1, map.count());

    const val = try util.testing.expectNonNull(
        try map.get(testing.allocator, "bim"),
    );
    try testing.expectEqualStrings("/foo", val.url);
    try testing.expectEqualStrings("bar", val.title);
}

test "first link def takes precedence" {
    var def1: ast.LinkDefinition = .{
        .url = "/foo",
        .title = "bar",
        .label = "bim",
    };
    var def2: ast.LinkDefinition = .{
        .url = "/zap",
        .title = "zim",
        .label = "bim",
    };

    var map: LinkDefMap = .empty;
    defer map.deinit(testing.allocator);

    try map.add(testing.allocator, &def1);
    try map.add(testing.allocator, &def2);

    const val = try util.testing.expectNonNull(
        try map.get(testing.allocator, "bim"),
    );
    try testing.expectEqualStrings("/foo", val.url);
    try testing.expectEqualStrings("bar", val.title);
}

test "match is case-insensitive" {
    var def: ast.LinkDefinition = .{
        .url = "/foo",
        .title = "bar",
        .label = "bim",
    };

    var map: LinkDefMap = .empty;
    defer map.deinit(testing.allocator);

    try map.add(testing.allocator, &def);

    const val = try util.testing.expectNonNull(
        try map.get(testing.allocator, "Bim"),
    );
    try testing.expectEqualStrings("/foo", val.url);
    try testing.expectEqualStrings("bar", val.title);
}

test "leading and trailing whitespace is stripped from label" {
    var def: ast.LinkDefinition = .{
        .url = "/foo",
        .title = "bar",
        .label = "bim",
    };

    var map: LinkDefMap = .empty;
    defer map.deinit(testing.allocator);

    try map.add(testing.allocator, &def);

    const val = try util.testing.expectNonNull(
        try map.get(testing.allocator, "  bim  \t"),
    );
    try testing.expectEqual("/foo", val.url);
    try testing.expectEqual("bar", val.title);
}

test "interior whitespace is collapsed" {
    var def: ast.LinkDefinition = .{
        .url = "/foo",
        .title = "bar",
        .label = "bim bat",
    };

    var map: LinkDefMap = .empty;
    defer map.deinit(testing.allocator);

    try map.add(testing.allocator, &def);

    const val = try util.testing.expectNonNull(
        try map.get(testing.allocator, "bim  \t bat"),
    );
    try testing.expectEqual("/foo", val.url);
    try testing.expectEqual("bar", val.title);
}

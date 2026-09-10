//! Handles normalization, storage, and lookup of link definitions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMapUnmanaged = std.hash_map.StringHashMapUnmanaged;

const util = @import("../../util/util.zig");

pub const label_max_len = 999; // TODO: This is in bytes, but should be in
                               // Unicode codepoints.
const folded_label_max_len = util.unicode.utf8.caseFoldLenWorstCase(
    label_max_len,
);

pub const Error = Allocator.Error || util.unicode.CaseFoldError;

pub const Definition = struct {
    url: []const u8,
    title: []const u8,
    label: []const u8,

    fn deinit(self: Definition, alloc: Allocator) void {
        alloc.free(self.url);
        alloc.free(self.title);
        alloc.free(self.label);
    }

    /// Deep copy.
    fn dupe(self: Definition, alloc: Allocator) !Definition {
        return .{
            .url = try alloc.dupe(u8, self.url),
            .title = try alloc.dupe(u8, self.title),
            .label = try alloc.dupe(u8, self.label),
        };
    }
};

/// A hashmap mapping link labels to link definitions. Lookup by label is
/// case-insensitive.
///
/// Entries can only ever be added to the map, never removed.
///
/// Makes a copy of added definitions and takes ownership. We do this instead
/// of keeping pointers to definition nodes in the AST to ensure that later AST
/// modifications don't invalidate this map.
pub const DefMap = struct {
    backing_map: StringHashMapUnmanaged(Definition),

    const Self = @This();

    pub const empty = Self{
        .backing_map = .empty,
    };

    pub fn deinit(self: *Self, alloc: Allocator) void {
        var it = self.backing_map.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            entry.value_ptr.deinit(alloc);
        }

        self.backing_map.deinit(alloc);
    }

    pub fn add(self: *Self, alloc: Allocator, def: Definition) Error!void {
        var buf: [folded_label_max_len]u8 = undefined;
        const key = try normalizeLabel(def.label, &buf);

        const result = try self.backing_map.getOrPut(alloc, key);
        if (result.found_existing) {
            return;
        }

        // Allocate storage for the key.
        // This modifies the key in the backing map, but since we are just
        // copying the value to a new place it doesn't change the key's hash
        // value or invalidate the index.
        result.key_ptr.* = try alloc.dupe(u8, key);

        // Allocate storage for the value.
        result.value_ptr.* = try def.dupe(alloc);
    }

    pub fn get(self: Self, label: []const u8) Error!?Definition {
        var buf: [folded_label_max_len]u8 = undefined;
        const key = try normalizeLabel(label, &buf);
        return self.backing_map.get(key);
    }

    pub fn count(self: Self) u32 {
        return self.backing_map.count();
    }
};

/// Normalizes the given link label, writing the result into buf.
///
/// To normalize a label, perform the Unicode case fold, strip leading and
/// trailing spaces, tabs, and line endings, and collapse consecutive internal
/// spaces, tabs, and line endings to a single space.
///
/// https://spec.commonmark.org/0.30/#matches
fn normalizeLabel(link_label: []const u8, buf: []u8) ![]u8 {
    // trim
    const trimmed = std.mem.trim(u8, link_label, " \t\n");

    // collapse interior whitespace
    var collapse_buf: [label_max_len]u8 = undefined;
    const collapsed = collapseInteriorWhitespace(trimmed, &collapse_buf);

    // case fold
    return try util.unicode.utf8.caseFoldFull(collapsed, buf);
}

fn collapseInteriorWhitespace(s: []const u8, buf: []u8) []u8 {
    std.debug.assert(buf.len >= s.len);

    var buf_i: usize = 0;
    var skippping_whitespace = false;
    for (s) |c| {
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

    return buf[0..buf_i];
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

test "can map single link def" {
    const def: Definition = .{
        .url = "/foo",
        .title = "bar",
        .label = "bim",
    };

    var map: DefMap = .empty;
    defer map.deinit(testing.allocator);

    try map.add(testing.allocator, def);

    try testing.expectEqual(1, map.count());

    const retrieved = try util.testing.expectNonNull(try map.get("bim"));
    try testing.expectEqualStrings("/foo", retrieved.url);
    try testing.expectEqualStrings("bar", retrieved.title);
}

test "first link def takes precedence" {
    const def1: Definition = .{
        .url = "/foo",
        .title = "bar",
        .label = "bim",
    };
    const def2: Definition = .{
        .url = "/zap",
        .title = "zim",
        .label = "bim",
    };

    var map: DefMap = .empty;
    defer map.deinit(testing.allocator);

    try map.add(testing.allocator, def1);
    try map.add(testing.allocator, def2);

    const val = try util.testing.expectNonNull( try map.get("bim"));
    try testing.expectEqualStrings("/foo", val.url);
    try testing.expectEqualStrings("bar", val.title);
}

test "match is case-insensitive" {
    const def: Definition = .{
        .url = "/foo",
        .title = "bar",
        .label = "bim",
    };

    var map: DefMap = .empty;
    defer map.deinit(testing.allocator);

    try map.add(testing.allocator, def);

    const val = try util.testing.expectNonNull(try map.get("Bim"));
    try testing.expectEqualStrings("/foo", val.url);
    try testing.expectEqualStrings("bar", val.title);
}

test "leading and trailing whitespace is stripped from label" {
    const def: Definition = .{
        .url = "/foo",
        .title = "bar",
        .label = "bim",
    };

    var map: DefMap = .empty;
    defer map.deinit(testing.allocator);

    try map.add(testing.allocator, def);

    const val = try util.testing.expectNonNull(try map.get("  bim  \t"));
    try testing.expectEqualStrings("/foo", val.url);
    try testing.expectEqualStrings("bar", val.title);
}

test "interior whitespace is collapsed" {
    const def: Definition = .{
        .url = "/foo",
        .title = "bar",
        .label = "bim bat",
    };

    var map: DefMap = .empty;
    defer map.deinit(testing.allocator);

    try map.add(testing.allocator, def);

    const val = try util.testing.expectNonNull(try map.get("bim  \t bat"));
    try testing.expectEqualStrings("/foo", val.url);
    try testing.expectEqualStrings("bar", val.title);
}

test "label is case folded" {
    const def: Definition = .{
        .url = "/foo",
        .title = "bar",
        .label = "Straße",
    };

    var map: DefMap = .empty;
    defer map.deinit(testing.allocator);

    try map.add(testing.allocator, def);

    const val = try util.testing.expectNonNull(try map.get("Strasse"));
    try testing.expectEqualStrings("/foo", val.url);
    try testing.expectEqualStrings("bar", val.title);
}

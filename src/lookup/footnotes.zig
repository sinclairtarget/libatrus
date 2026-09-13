//! Stores footnote definitions parsed during block parsing for later
//! retrieval. We store a pointer to the defintion AST node.
//!
//! Every footnote has an identifier. These identifiers may not contain spaces,
//! tabs, newlinews, or the characters `^`, `[`, or `]`. You can retrieve the
//! full definition from this data structure using the identifier. Matching
//! between identifiers is case-insensitive (actually it uses the Unicode case
//! fold).
//!
//! The order in which footnotes are stored is remembered. Footnotes can later
//! be retrieved in insertion order. Footnotes will later be automatically
//! numbered based on this ordering.
//!
//! As a special case, if a footnote has a positive integer identifier, then
//! the footnote is numbered using that integer. All other footnotes are
//! assigned numbers according to insertion order, skipping any numbers that
//! have been manually assigned.

const std = @import("std");
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const StringArrayHashMapUnmanaged = std.StringArrayHashMapUnmanaged;
const StringHashMapUnmanaged = std.StringHashMapUnmanaged;
const BufSet = std.BufSet;
const BufMap = std.BufMap;

const ast = @import("../ast.zig");
const util = @import("../util/util.zig");

pub const Error = error{InvalidIdentifier} ||
    Allocator.Error ||
    util.unicode.CaseFoldError;

const max_identifier_chars = 999; // bytes
const normalization_buf_size = util.unicode.utf8.caseFoldLenWorstCase(
    max_identifier_chars,
);

/// A hash map that associates footnote identifiers with footnote definitions.
///
/// Entries can only ever be added to the map, never removed.
///
/// This map does not take ownership of anything added to it. Stored pointers
/// to definition AST nodes may be invalid if the nodes have been removed from
/// the tree.
pub const DefMap = struct {
    backing_map: StringArrayHashMapUnmanaged(*ast.Node),

    const Self = @This();

    pub const empty: Self = .{
        .backing_map = .empty,
    };

    pub fn deinit(self: *Self, alloc: Allocator) void {
        var it = self.backing_map.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
        }

        self.backing_map.deinit(alloc);
    }

    pub fn add(
        self: *Self,
        alloc: Allocator,
        def_node: *ast.Node,
    ) Error!void {
        std.debug.assert(@as(
            ast.NodeType,
            def_node.*,
        ) == .footnote_definition);

        var buf: [normalization_buf_size]u8 = undefined;
        const key = try normalizeIdentifier(
            def_node.footnote_definition.identifier,
            &buf,
        );

        const result = try self.backing_map.getOrPut(alloc, key);
        if (result.found_existing) {
            return;
        }

        // Allocate storage for the key.
        // This modifies the key in the backing map, but since we are just
        // copying the value to a new place it doesn't change the key's hash
        // value or invalidate the index.
        result.key_ptr.* = try alloc.dupe(u8, key);

        result.value_ptr.* = def_node;
    }

    pub fn get(self: Self, identifier: []const u8) Error!?*ast.Node {
        var buf: [normalization_buf_size]u8 = undefined;
        const key = try normalizeIdentifier(identifier, &buf);
        return self.backing_map.get(key);
    }

    pub fn contains(self: Self, identifier: []const u8) Error!bool {
        var buf: [normalization_buf_size]u8 = undefined;
        const key = try normalizeIdentifier(identifier, &buf);
        return self.backing_map.contains(key);
    }

    pub fn count(self: Self) usize {
        return self.backing_map.count();
    }

    /// Returns an iterator over stored footnotes.
    ///
    /// The iterator iterates over the footnotes in the order they were
    /// inserted.
    ///
    /// Iterator is invalidated if the map is modified during iteration.
    pub fn iterator(self: Self) Iterator {
        return Iterator.init(self.backing_map.values());
    }

    pub const Iterator = struct {
        slice: []*ast.Node,
        index: usize,

        fn init(slice: []*ast.Node) Iterator {
            return .{
                .slice = slice,
                .index = 0,
            };
        }

        pub fn next(self: *Iterator) ?*ast.Node {
            if (self.index >= self.slice.len)
                return null;

            defer self.index += 1;
            return self.slice[self.index];
        }
    };
};

/// Assigns footnote numbers to identifiers in the given definition map.
///
/// The numbers are assigned according to the order in which definitions were
/// inserted into the map.
///
/// Returns a BufMap, owned by the caller, that maps identifiers -> footnote
/// numbers (as strings).
pub fn number(alloc: Allocator, def_map: DefMap) !BufMap {
    var manual_numbers = BufSet.init(alloc);
    defer manual_numbers.deinit();

    // Add all manually numbered footnotes to set
    var it = def_map.iterator();
    while (it.next()) |def_node| {
        const identifier = def_node.footnote_definition.identifier;
        const parsed_num = fmt.parseInt(u32, identifier, 10) catch 0;
        if (parsed_num > 0) {
            try manual_numbers.insert(identifier);
        }
    }

    // Figure out number for each footnote, inserting into final map
    var number_map = BufMap.init(alloc);
    var counter: u32 = 1;
    var buf: [10]u8 = undefined; // scratch for printing number
    it = def_map.iterator();
    while (it.next()) |def_node| {
        const identifier = def_node.footnote_definition.identifier;
        const parsed_num = fmt.parseInt(u32, identifier, 10) catch 0;
        if (parsed_num > 0) {
            try number_map.put(identifier, identifier);
            if (parsed_num >= counter) {
                counter = parsed_num + 1;
            }
        } else {
            const counter_num = while (true) {
                const counter_num = fmt.bufPrint(
                    &buf,
                    "{d}",
                    .{counter},
                ) catch |err| switch (err) {
                    error.NoSpaceLeft => @panic("buffer not long enough"),
                    inline else => |e| return e,
                };
                if (!manual_numbers.contains(counter_num))
                    break counter_num;

                counter += 1;
            };

            try number_map.put(identifier, counter_num);
            counter += 1;
        }
    }

    return number_map;
}

/// Normalizes the given identifier, writing the result into buf.
///
/// We normalize by:
/// * first ensuring that the identifier is valid
/// * case-folding the entire thing
fn normalizeIdentifier(identifier: []const u8, buf: []u8) ![]u8 {
    if (!isValidIdentifier(identifier)) {
        return Error.InvalidIdentifier;
    }

    return try util.unicode.utf8.caseFoldFull(identifier, buf);
}

/// Identifiers may not contain spaces, tabs, newlines, or the characters `^`,
/// `[`, or `]`.
///
/// They must be shorter than the max len in bytes.
fn isValidIdentifier(identifier: []const u8) bool {
    if (identifier.len > max_identifier_chars)
        return false;

    for (identifier) |c| {
        switch (c) {
            // TODO: Should we allow unicode whitespace?
            '^', ']', '[', '\t', ' ', '\n' => return false,
            else => {},
        }
    }

    return true;
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

test "simple add and get" {
    var def_map: DefMap = .empty;
    defer def_map.deinit(testing.allocator);

    var def_node: ast.Node = .{
        .footnote_definition = .{
            .children = &.{},
            .identifier = "my-footnote",
            .label = "This is my footnote.",
        },
    };

    try def_map.add(testing.allocator, &def_node);

    const retrieved = try util.testing.expectNonNull(
        try def_map.get("my-footnote"),
    );
    try testing.expectEqualStrings(
        def_node.footnote_definition.label,
        retrieved.footnote_definition.label,
    );
}

test "iterate" {
    var def_map: DefMap = .empty;
    defer def_map.deinit(testing.allocator);

    var def_node_1: ast.Node = .{
        .footnote_definition = .{
            .children = &.{},
            .identifier = "my-footnote",
            .label = "This is my first footnote.",
        },
    };

    var def_node_2: ast.Node = .{
        .footnote_definition = .{
            .children = &.{},
            .identifier = "my-other-footnote",
            .label = "This is my second footnote.",
        },
    };

    try def_map.add(testing.allocator, &def_node_1);
    try def_map.add(testing.allocator, &def_node_2);

    // Iterate
    var it = def_map.iterator();

    var def_node = try util.testing.expectNonNull(it.next());
    try testing.expectEqualStrings(
        "my-footnote",
        def_node.footnote_definition.identifier,
    );
    try testing.expectEqualStrings(
        "This is my first footnote.",
        def_node.footnote_definition.label,
    );

    def_node = try util.testing.expectNonNull(it.next());
    try testing.expectEqualStrings(
        "my-other-footnote",
        def_node.footnote_definition.identifier,
    );
    try testing.expectEqualStrings(
        "This is my second footnote.",
        def_node.footnote_definition.label,
    );

    try testing.expectEqual(null, it.next());
}

test "case fold footnote" {
    var def_map: DefMap = .empty;
    defer def_map.deinit(testing.allocator);

    var def_node: ast.Node = .{
        .footnote_definition = .{
            .children = &.{},
            .identifier = "ΌΣΟΣ",
            .label = "This is my first footnote.",
        },
    };

    try def_map.add(testing.allocator, &def_node);

    const retrieved = try util.testing.expectNonNull(
        try def_map.get("όσος"),
    );
    try testing.expectEqualStrings(
        def_node.footnote_definition.label,
        retrieved.footnote_definition.label,
    );
}

test "number footnotes correctly" {
    var def_map: DefMap = .empty;
    defer def_map.deinit(testing.allocator);

    var def_node_1: ast.Node = .{
        .footnote_definition = .{
            .children = &.{},
            .identifier = "my-footnote",
            .label = "my-footnote",
        },
    };
    var def_node_2: ast.Node = .{
        .footnote_definition = .{
            .children = &.{},
            .identifier = "3",
            .label = "3",
        },
    };
    var def_node_3: ast.Node = .{
        .footnote_definition = .{
            .children = &.{},
            .identifier = "my-other-footnote",
            .label = "my-other-footnote",
        },
    };

    try def_map.add(testing.allocator, &def_node_1);
    try def_map.add(testing.allocator, &def_node_2);
    try def_map.add(testing.allocator, &def_node_3);

    var number_lookup = try number(testing.allocator, def_map);
    defer number_lookup.deinit();

    try testing.expectEqual(3, number_lookup.count());
    try testing.expectEqualStrings("1", number_lookup.get("my-footnote").?);
    try testing.expectEqualStrings("3", number_lookup.get("3").?);
    try testing.expectEqualStrings(
        "4",
        number_lookup.get("my-other-footnote").?,
    );
}

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
const Allocator = std.mem.Allocator;
const StringArrayHashMapUnmanaged = std.StringArrayHashMapUnmanaged;

const ast = @import("../../ast.zig");
const util = @import("../../util/util.zig");

pub const Error = error{InvalidIdentifier} ||
    Allocator.Error ||
    util.unicode.CaseFoldError;

const max_identifier_chars = 999; // bytes
const normalization_buf_size = util.unicode.utf8.caseFoldLenWorstCase(
    max_identifier_chars,
);

const StoredDefinition = struct {
    /// Pointer to definition node in the AST.
    node: *ast.Node,
    /// This is set to true if the footnote has been retrieved from the map at
    /// least once.
    has_been_referenced: bool,
};

/// A hash map that associates footnote identifiers with footnote definitions.
///
/// Entries can only ever be added to the map, never removed.
///
/// This map does not take ownership of anything added to it. Stored pointers
/// to definition AST nodes may be invalid if the nodes have been removed from
/// the tree.
pub const DefMap = struct {
    backing_map: StringArrayHashMapUnmanaged(StoredDefinition),

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

        // Allocate storage for the value.
        result.value_ptr.* = .{
            .node = def_node,
            .has_been_referenced = false,
        };
    }

    pub fn get(self: Self, identifier: []const u8) Error!?*ast.Node {
        var buf: [normalization_buf_size]u8 = undefined;
        const key = try normalizeIdentifier(identifier, &buf);

        const stored = self.backing_map.getPtr(key) orelse return null;
        stored.has_been_referenced = true;
        return stored.node;
    }

    /// Returns an iterator over stored footnotes.
    ///
    /// Iterator is invalidated if the map is modified during iteration.
    pub fn iterator(self: Self, options: Iterator.Options) Iterator {
        return Iterator.init(self.backing_map.values(), options);
    }

    pub const Iterator = struct {
        slice: []StoredDefinition,
        options: Options,
        index: usize,
        counter: u32,

        pub const Options = struct {
            /// Iterator skips footnotes that have never been retrieved from
            /// the map.
            skip_unreferenced: bool = false,
        };

        fn init(slice: []StoredDefinition, options: Options) Iterator {
            return .{
                .slice = slice,
                .options = options,
                .index = 0,
                .counter = 1,
            };
        }

        /// Returns a tuple of (footnote number, footnote definition) or null
        /// if the iterator is exhausted.
        pub fn next(self: *Iterator) ?struct { u32, *ast.Node } {
            const stored = while (self.index < self.slice.len) {
                if (!self.options.skip_unreferenced or
                    self.slice[self.index].has_been_referenced)
                {
                    break self.slice[self.index];
                }

                self.index += 1;
            } else return null;

            const number = blk: {
                const n = std.fmt.parseInt(
                    u32,
                    stored.node.footnote_definition.identifier,
                    10,
                ) catch 0;
                if (n > 0) { // need positive number even if parse successful
                    break :blk n;
                } else {
                    defer self.counter += 1;
                    break :blk self.counter;
                }
            };

            self.index += 1;
            return .{ number, stored.node };
        }
    };
};

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
    var it = def_map.iterator(.{}); // Default behavior

    var number, var def_node = try util.testing.expectNonNull(it.next());
    try testing.expectEqual(1, number);
    try testing.expectEqualStrings(
        "my-footnote",
        def_node.footnote_definition.identifier,
    );
    try testing.expectEqualStrings(
        "This is my first footnote.",
        def_node.footnote_definition.label,
    );

    number, def_node = try util.testing.expectNonNull(it.next());
    try testing.expectEqual(2, number);
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

test "iterate skip unreferenced" {
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

    // Reference one footnote
    _ = try def_map.get("my-other-footnote");

    // Iterate
    var it = def_map.iterator(.{
        .skip_unreferenced = true,
    });

    const number, const def_node = try util.testing.expectNonNull(it.next());
    try testing.expectEqual(1, number);
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

test "iterate with integer identifier" {
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
            .identifier = "7",
            .label = "This is my second footnote.",
        },
    };

    var def_node_3: ast.Node = .{
        .footnote_definition = .{
            .children = &.{},
            .identifier = "my-other-footnote",
            .label = "This is my third footnote.",
        },
    };

    var def_node_4: ast.Node = .{
        .footnote_definition = .{
            .children = &.{},
            .identifier = "0",
            .label = "This is my fourth footnote.",
        },
    };

    try def_map.add(testing.allocator, &def_node_1);
    try def_map.add(testing.allocator, &def_node_2);
    try def_map.add(testing.allocator, &def_node_3);
    try def_map.add(testing.allocator, &def_node_4);

    // Reference all footnotes
    _ = try util.testing.expectNonNull(
        try def_map.get("my-footnote"),
    );
    _ = try util.testing.expectNonNull(
        try def_map.get("7"),
    );
    _ = try util.testing.expectNonNull(
        try def_map.get("my-other-footnote"),
    );
    _ = try util.testing.expectNonNull(
        try def_map.get("0"),
    );

    // Iterate
    var it = def_map.iterator(.{
        .skip_unreferenced = true,
    });

    var number, var def_node = try util.testing.expectNonNull(it.next());
    try testing.expectEqual(1, number);
    try testing.expectEqualStrings(
        "my-footnote",
        def_node.footnote_definition.identifier,
    );
    try testing.expectEqualStrings(
        "This is my first footnote.",
        def_node.footnote_definition.label,
    );

    number, def_node = try util.testing.expectNonNull(it.next());
    try testing.expectEqual(7, number);
    try testing.expectEqualStrings(
        "7",
        def_node.footnote_definition.identifier,
    );
    try testing.expectEqualStrings(
        "This is my second footnote.",
        def_node.footnote_definition.label,
    );

    number, def_node = try util.testing.expectNonNull(it.next());
    try testing.expectEqual(2, number);
    try testing.expectEqualStrings(
        "my-other-footnote",
        def_node.footnote_definition.identifier,
    );
    try testing.expectEqualStrings(
        "This is my third footnote.",
        def_node.footnote_definition.label,
    );

    number, def_node = try util.testing.expectNonNull(it.next());
    try testing.expectEqual(3, number); // Integer identifier must be positive
    try testing.expectEqualStrings(
        "0",
        def_node.footnote_definition.identifier,
    );
    try testing.expectEqualStrings(
        "This is my fourth footnote.",
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

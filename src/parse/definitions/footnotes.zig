//! Stores footnote definitions parsed during block parsing for later
//! retrieval.
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

const util = @import("../../util/util.zig");

pub const Error = error{InvalidIdentifier} ||
    Allocator.Error ||
    util.unicode.CaseFoldError;

const max_identifier_chars = 999; // bytes
const normalization_buf_size = util.unicode.utf8.caseFoldLenWorstCase(
    max_identifier_chars,
);

pub const Definition = struct {
    identifier: []const u8,
    label: []const u8,
};

const StoredDefinition = struct {
    identifier: []const u8,
    label: []const u8,
    /// This is set to true if the footnote has been retrieved from the map at
    /// least once.
    has_been_referenced: bool,

    fn init(alloc: Allocator, def: Definition) !StoredDefinition {
        return .{
            .identifier = try alloc.dupe(u8, def.identifier),
            .label = try alloc.dupe(u8, def.label),
            .has_been_referenced = false,
        };
    }

    fn deinit(self: StoredDefinition, alloc: Allocator) void {
        alloc.free(self.identifier);
        alloc.free(self.label);
    }
};

/// A hash map that associates footnote identifiers with footnote definitions.
///
/// Entries can only ever be added to the map, never removed.
///
/// Makes a copy of added definitions and takes ownership. We do this instead
/// of keeping pointers to definition nodes in the AST to ensure that later AST
/// modifications don't invalidate this map.
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
            entry.value_ptr.deinit(alloc);
        }

        self.backing_map.deinit(alloc);
    }

    pub fn add(self: *Self, alloc: Allocator, def: Definition) Error!void {
        var buf: [normalization_buf_size]u8 = undefined;
        const key = try normalizeIdentifier(def.identifier, &buf);

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
        result.value_ptr.* = try StoredDefinition.init(alloc, def);
    }

    pub fn get(self: Self, identifier: []const u8) Error!?Definition {
        var buf: [normalization_buf_size]u8 = undefined;
        const key = try normalizeIdentifier(identifier, &buf);

        const stored = self.backing_map.getPtr(key) orelse return null;
        stored.has_been_referenced = true;
        return .{
            .identifier = stored.identifier,
            .label = stored.label,
        };
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
        pub fn next(self: *Iterator) ?struct { u32, Definition } {
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
                    stored.identifier,
                    10,
                ) catch 0;
                if (n > 0) { // need positive number even if parse successful
                    break :blk n;
                } else {
                    defer self.counter += 1;
                    break :blk self.counter;
                }
            };
            const def: Definition = .{
                .identifier = stored.identifier,
                .label = stored.label,
            };

            self.index += 1;
            return .{ number, def };
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

    const label = "This is my footnote.";

    try def_map.add(
        testing.allocator,
        .{
            .identifier = "my-footnote",
            .label = label,
        },
    );

    const retrieved = try util.testing.expectNonNull(
        try def_map.get("my-footnote"),
    );
    try testing.expectEqualStrings(label, retrieved.label);
}

test "iterate" {
    var def_map: DefMap = .empty;
    defer def_map.deinit(testing.allocator);

    const footnote_1: Definition = .{
        .identifier = "my-footnote",
        .label = "This is my first footnote.",
    };

    const footnote_2: Definition = .{
        .identifier = "my-other-footnote",
        .label = "This is my second footnote.",
    };

    try def_map.add(testing.allocator, footnote_1);
    try def_map.add(testing.allocator, footnote_2);

    // Iterate
    var it = def_map.iterator(.{}); // Default behavior

    var number, var def = try util.testing.expectNonNull(it.next());
    try testing.expectEqual(1, number);
    try testing.expectEqualStrings("my-footnote", def.identifier);
    try testing.expectEqualStrings("This is my first footnote.", def.label);

    number, def = try util.testing.expectNonNull(it.next());
    try testing.expectEqual(2, number);
    try testing.expectEqualStrings("my-other-footnote", def.identifier);
    try testing.expectEqualStrings("This is my second footnote.", def.label);

    try testing.expectEqual(null, it.next());
}

test "iterate skip unreferenced" {
    var def_map: DefMap = .empty;
    defer def_map.deinit(testing.allocator);

    const footnote_1: Definition = .{
        .identifier = "my-footnote",
        .label = "This is my first footnote.",
    };

    const footnote_2: Definition = .{
        .identifier = "my-other-footnote",
        .label = "This is my second footnote.",
    };

    try def_map.add(testing.allocator, footnote_1);
    try def_map.add(testing.allocator, footnote_2);

    // Reference one footnote
    _ = try def_map.get("my-other-footnote");

    // Iterate
    var it = def_map.iterator(.{
        .skip_unreferenced = true,
    });

    const number, const def = try util.testing.expectNonNull(it.next());
    try testing.expectEqual(1, number);
    try testing.expectEqualStrings("my-other-footnote", def.identifier);
    try testing.expectEqualStrings("This is my second footnote.", def.label);

    try testing.expectEqual(null, it.next());
}

test "iterate with integer identifier" {
    var def_map: DefMap = .empty;
    defer def_map.deinit(testing.allocator);

    const footnote_1: Definition = .{
        .identifier = "my-footnote",
        .label = "This is my first footnote.",
    };

    const footnote_2: Definition = .{
        .identifier = "7",
        .label = "This is my second footnote.",
    };

    const footnote_3: Definition = .{
        .identifier = "my-other-footnote",
        .label = "This is my third footnote.",
    };

    const footnote_4: Definition = .{
        .identifier = "0",
        .label = "This is my fourth footnote.",
    };

    try def_map.add(testing.allocator, footnote_1);
    try def_map.add(testing.allocator, footnote_2);
    try def_map.add(testing.allocator, footnote_3);
    try def_map.add(testing.allocator, footnote_4);

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

    var number, var def = try util.testing.expectNonNull(it.next());
    try testing.expectEqual(1, number);
    try testing.expectEqualStrings("my-footnote", def.identifier);
    try testing.expectEqualStrings("This is my first footnote.", def.label);

    number, def = try util.testing.expectNonNull(it.next());
    try testing.expectEqual(7, number);
    try testing.expectEqualStrings("7", def.identifier);
    try testing.expectEqualStrings("This is my second footnote.", def.label);

    number, def = try util.testing.expectNonNull(it.next());
    try testing.expectEqual(2, number);
    try testing.expectEqualStrings("my-other-footnote", def.identifier);
    try testing.expectEqualStrings("This is my third footnote.", def.label);

    number, def = try util.testing.expectNonNull(it.next());
    try testing.expectEqual(3, number); // Integer identifier must be positive
    try testing.expectEqualStrings("0", def.identifier);
    try testing.expectEqualStrings("This is my fourth footnote.", def.label);

    try testing.expectEqual(null, it.next());
}

test "case fold footnote" {
    var def_map: DefMap = .empty;
    defer def_map.deinit(testing.allocator);

    const footnote: Definition = .{
        .identifier = "ΌΣΟΣ",
        .label = "This is my first footnote.",
    };

    try def_map.add(testing.allocator, footnote);

    const retrieved = try util.testing.expectNonNull(
        try def_map.get("όσος"),
    );
    try testing.expectEqualStrings(footnote.label, retrieved.label);
}

//! Handle named character references (AKA HTML entities) and numeric character
//! references.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const mem = std.mem;
const unicode = std.unicode;

const logger = @import("../logging.zig").logger(.character_refs);

const named_entities = @import("data").named_entities;
const EntityEntry = @import("data").EntityEntry;

pub const CharacterReferenceError = error{
    UnicodeError,
} || Allocator.Error;

/// Handles numeric character references like `&#42;` (decimal) or `&xaf;`
/// (hexadecimal).
pub fn resolveNumeric(
    alloc: Allocator,
    digits: []const u8,
    base: u8,
) CharacterReferenceError![]const u8 {
    const value = fmt.parseInt(u21, digits, base) catch 0;
    if (value > 0) {
        var buf: [4]u8 = undefined;
        const bytes_written = unicode.utf8Encode(value, &buf) catch {
            return error.UnicodeError;
        };
        return try alloc.dupe(u8, buf[0..bytes_written]);
    } else {
        return try alloc.dupe(u8, &unicode.replacement_character_utf8);
    }
}

/// Handles named entity references like `&amp;` and `&quot;`.
pub fn resolveNamed(name: []const u8) ?[]const u8 {
    const index = std.sort.binarySearch(
        EntityEntry,
        named_entities,
        name,
        struct {
            fn inner(context: []const u8, entry: EntityEntry) std.math.Order {
                return std.mem.order(u8, context, entry.name);
            }
        }.inner,
    ) orelse {
        logger.warn(
            "No named character reference found for name \"{s}\" (\"&{s};\").",
            .{ name, name },
        );
        return null;
    };

    const entry = named_entities[index];
    return entry.characters;
}

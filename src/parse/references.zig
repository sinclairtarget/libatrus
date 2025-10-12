//! Handle entity and numeric character references.
const std = @import("std");
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const mem = std.mem;
const unicode = std.unicode;

pub fn resolveCharacter(
    alloc: Allocator,
    digits: []const u8,
    base: u8,
) ![]const u8 {
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

pub fn resolveEntity(name: []const u8) ?[]const u8 {
    // TODO: Support all named entities
    if (mem.eql(u8, name, "amp")) {
        return "&";
    } else if (mem.eql(u8, name,"quot")) {
        return "\"";
    } else if (mem.eql(u8, name,"nbsp")) {
        return " ";
    } else if (mem.eql(u8, name,"copy")) {
        return "©";
    } else if (mem.eql(u8, name,"AElig")) {
        return "Æ";
    } else if (mem.eql(u8, name,"Dcaron")) {
        return "Ď";
    } else if (mem.eql(u8, name,"frac34")) {
        return "¾";
    } else if (mem.eql(u8, name,"HilbertSpace")) {
        return "ℋ";
    } else if (mem.eql(u8, name,"DifferentialD")) {
        return "ⅆ";
    } else if (mem.eql(u8, name,"ClockwiseContourIntegral")) {
        return "∲";
    } else if (mem.eql(u8, name,"ngE")) {
        return "≧̸";
    } else {
        return null;
    }
}

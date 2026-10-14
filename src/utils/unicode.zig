const std = @import("std");
const Allocator = std.mem.Allocator;

const case_fold_mappings = @import("data").case_fold_mappings;
const CaseFoldMapping = @import("data").CaseFoldMapping;

pub const CaseFoldError = error{
    InvalidUtf8,
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
};

pub const utf8 = struct {
    /// Takes a UTF-8 string and returns the full case-folded version of that
    /// string re-encoded into UTF-8.
    ///
    /// Caller owns the memory for the returned string.
    pub fn allocCaseFoldFull(
        alloc: Allocator,
        s: []const u8,
    ) (CaseFoldError || Allocator.Error)![]const u8 {
        const buf = try alloc.alloc(u8, caseFoldLenWorstCase(s.len));
        errdefer alloc.free(buf);

        const foldedS = try caseFoldFull(s, buf);
        return try alloc.realloc(buf, foldedS.len);
    }

    /// Takes a UTF-8 string and returns the full case-folded version of that
    /// string re-encoded into UTF-8.
    ///
    /// Asserts that the given buffer is large enough to hold the case-folded
    /// string.
    pub fn caseFoldFull(s: []const u8, buf: []u8) CaseFoldError![]u8 {
        std.debug.assert(buf.len >= caseFoldLenWorstCase(s.len));

        var num_chars: usize = 0;
        var view = (try std.unicode.Utf8View.init(s)).iterator();
        while (view.nextCodepoint()) |codepoint| {
            const codepoints_to_write: []const u21 =
                if (mapCodepoint(codepoint)) |mapped|
                    mapped
                else
                    &.{codepoint};
            const chars_written = try writeCodepoints(
                codepoints_to_write,
                buf[num_chars..],
            );
            num_chars += chars_written;
        }

        return buf[0..num_chars];
    }

    /// Max len of the case-folded string given len of the input string.
    ///
    /// TODO: This is a bit of a fudge. In the worst case, one codepoint can
    /// map to three codepoints, but that's not the same thing as one byte
    /// mapping to three bytes.
    pub fn caseFoldLenWorstCase(num_chars: usize) usize {
        return num_chars * 3;
    }
};

fn mapCodepoint(codepoint: u21) ?[]const u21 {
    const index = std.sort.binarySearch(
        CaseFoldMapping,
        case_fold_mappings,
        codepoint,
        struct {
            fn inner(context: u21, mapping: CaseFoldMapping) std.math.Order {
                return std.math.order(context, mapping.codepoint);
            }
        }.inner,
    ) orelse return null;

    const mapping = case_fold_mappings[index];
    return mapping.mapped_codepoints;
}

fn writeCodepoints(codepoints: []const u21, out: []u8) !usize {
    var num_chars: usize = 0;
    for (codepoints) |codepoint| {
        const chars_written = try std.unicode.utf8Encode(
            codepoint,
            out[num_chars..],
        );
        num_chars += chars_written;
    }

    return num_chars;
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

fn expectEqualCaseFolded(a: []const u8, b: []const u8) !void {
    const case_folded_a = try utf8.allocCaseFoldFull(testing.allocator, a);
    defer testing.allocator.free(case_folded_a);
    const case_folded_b = try utf8.allocCaseFoldFull(testing.allocator, b);
    defer testing.allocator.free(case_folded_b);

    try testing.expectEqualStrings(case_folded_a, case_folded_b);
}

test "case fold simple characters" {
    try expectEqualCaseFolded("aaa", "AAA");
}

test "case fold greek" {
    try expectEqualCaseFolded("όσος", "ΌΣΟΣ");
}

test "case fold german" {
    try expectEqualCaseFolded("Straße", "strasse");
    try expectEqualCaseFolded("strasse", "StraSSe");
    try expectEqualCaseFolded("StraSSe", "Straße");
}

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Duplicates the given string, but skips all backslashes (unless they are
/// themselves escaped).
pub fn copyEscape(alloc: Allocator, s: []const u8) ![]const u8 {
    const copy = try alloc.alloc(u8, s.len);

    var state: enum { normal, escape } = .normal;
    var source_index: usize = 0;
    var dest_index: usize = 0;
    while (source_index < s.len) {
        switch (state) {
            .normal => {
                switch (s[source_index]) {
                    '\\' => {
                        source_index += 1;
                        state = .escape;
                    },
                    else => {
                        copy[dest_index] = s[source_index];
                        source_index += 1;
                        dest_index += 1;
                    },
                }
            },
            .escape => {
                switch (s[source_index]) {
                    '\\' => {
                        // literal backslash
                        copy[dest_index] = s[source_index];
                        source_index += 1;
                        dest_index += 1;
                    },
                    else => {},
                }
                state = .normal;
            },
        }
    }

    return copy[0..dest_index];
}

const std = @import("std");

pub const EntityEntry = struct {
    name: []const u8,
    characters: []const u8, // UTF-8 bytes
};

pub const named_entities: []const EntityEntry = @import("entities.zon");

pub const CaseFoldMapping = struct {
    codepoint: u21,
    mapped_codepoints: []const u21,
};

pub const case_fold_mappings: []const CaseFoldMapping = @import(
    "case_fold.zon",
);

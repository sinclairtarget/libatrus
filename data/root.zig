const std = @import("std");

pub const EntityEntry = struct {
    name: []const u8,
    characters: []const u8,
};

pub const named_entities: []const EntityEntry = @import("entities.zon");

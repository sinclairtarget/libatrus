pub const named_entities: []const struct {
    name: []const u8,
    characters: []const u8,
} = @import("entities.zon");

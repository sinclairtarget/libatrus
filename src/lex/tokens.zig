const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TokenType = enum {
    text,
    pound,
    newline,
    eof,
};

pub const Token = struct {
    token_type: TokenType,
    lexeme: ?[]const u8 = null,

    const Self = @This();

    pub fn format(self: Self, alloc: Allocator) ![]const u8 {
        const name = try std.ascii.allocUpperString(
            alloc,
            @tagName(self.token_type),
        );

        if (self.lexeme) |lexeme| {
            return std.fmt.allocPrint(
                alloc,
                "{s} \"{s}\"",
                .{
                    name,
                    lexeme,
                },
            );
        }

        return name;
    }
};

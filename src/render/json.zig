const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const MystAst = @import("../parse/ast.zig").MystAst;

pub fn render(alloc: Allocator, ast: MystAst, out: *Io.Writer) !void {
    _ = alloc;
    try std.json.fmt(ast, .{}).format(out);
}

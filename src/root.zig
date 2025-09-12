const std = @import("std");
const Allocator = std.mem.Allocator;

pub const version = "0.0.1";

pub fn parse(myst: []u8) []u8 {
    return myst;
}

pub fn tokenize(alloc: Allocator, myst: []u8) []const []const u8 {
    _ = alloc;
    _ = myst;
    return &[_][]const u8{ "FEE", "FI", "FO", "FUM" };
}

pub fn renderYAML(ast: []u8) []u8 {
    return ast;
}

pub fn renderHTML(ast: []u8) []u8 {
    return ast;
}

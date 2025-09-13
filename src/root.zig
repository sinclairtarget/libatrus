const std = @import("std");
const Allocator = std.mem.Allocator;

pub const version = "0.0.1";

pub fn parse(myst: []const u8) []const u8 {
    return myst;
}

pub fn tokenize(alloc: Allocator, myst: []const u8) []const []const u8 {
    _ = alloc;
    _ = myst;
    return &[_][]const u8{ "FEE", "FI", "FO", "FUM" };
}

pub fn renderYAML(ast: []const u8) []const u8 {
    return ast;
}

pub fn renderHTML(ast: []const u8) []const u8 {
    return ast;
}

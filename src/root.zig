const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;

const Tokenizer = @import("lex/tokenizer.zig");
const Token = @import("lex/tokens.zig").Token;

pub const version = "0.0.1";

pub fn parse(myst: []const u8) []const u8 {
    return myst;
}

pub fn tokenize(alloc: Allocator, in: *Io.Reader) ![]const Token {
    comptime if (builtin.mode != .Debug) {
        @compileError("tokenize() is only supported in the debug release mode");
    };

    var tokens: ArrayList(Token) = .empty;
    errdefer tokens.deinit(alloc);

    var tokenizer = Tokenizer.init(alloc, in);
    defer tokenizer.deinit();
    while (tokenizer.next()) |token| {
        try tokens.append(alloc, token);
        if (token.token_type == .eof) {
            break;
        }
    } else |err| {
        return err;
    }

    return try tokens.toOwnedSlice(alloc);
}

pub fn renderYAML(ast: []const u8) []const u8 {
    return ast;
}

pub fn renderHTML(ast: []const u8) []const u8 {
    return ast;
}

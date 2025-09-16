const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;

const Tokenizer = @import("lex/Tokenizer.zig");
const Token = @import("lex/tokens.zig").Token;
const ast = @import("parse/ast.zig");
const Parser = @import("parse/Parser.zig");
const json = @import("render/json.zig");

pub const version = "0.0.1";

pub fn tokenize(alloc: Allocator, in: *Io.Reader) ![]const Token {
    comptime if (builtin.mode != .Debug) {
        @compileError("tokenize() is only supported in the debug release mode");
    };

    var tokens: ArrayList(Token) = .empty;
    errdefer tokens.deinit(alloc);

    var tokenizer = Tokenizer.init(in);
    var token = try tokenizer.next(alloc);
    while (token.token_type != .eof) : (token = try tokenizer.next(alloc)) {
        try tokens.append(alloc, token);
    }
    try tokens.append(alloc, token); // append eof
    return try tokens.toOwnedSlice(alloc);
}

pub fn parse(alloc: Allocator, in: *Io.Reader) !ast.Node {
    var tokenizer = Tokenizer.init(in);
    var parser = Parser.init(&tokenizer);
    return try parser.parse(alloc);
}

pub fn renderJSON(root: ast.Node, out: *Io.Writer) !void {
    try json.render(root, out);
}

pub fn renderYAML(root: []const u8) []const u8 {
    return root;
}

pub fn renderHTML(root: []const u8) []const u8 {
    return root;
}

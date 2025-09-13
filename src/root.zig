const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;

const Tokenizer = @import("lex/Tokenizer.zig");
const Token = @import("lex/tokens.zig").Token;
const MystAst = @import("parse/ast.zig").MystAst;
const json = @import("render/json.zig");

pub const version = "0.0.1";

pub fn tokenize(alloc: Allocator, in: *Io.Reader) ![]const Token {
    comptime if (builtin.mode != .Debug) {
        @compileError("tokenize() is only supported in the debug release mode");
    };

    var tokens: ArrayList(Token) = .empty;
    errdefer tokens.deinit(alloc);

    var tokenizer = Tokenizer.init(in);
    while (tokenizer.next(alloc)) |token| { // TODO: use `try` ?
        try tokens.append(alloc, token);
        if (token.token_type == .eof) {
            break;
        }
    } else |err| {
        return err;
    }

    return try tokens.toOwnedSlice(alloc);
}

pub fn parse() MystAst {
    return .{
        .root = .{
            .node_type = .root,
        },
    };
}

pub fn renderJSON(alloc: Allocator, ast: MystAst, out: *Io.Writer) !void {
    try json.render(alloc, ast, out);
}

pub fn renderYAML(ast: []const u8) []const u8 {
    return ast;
}

pub fn renderHTML(ast: []const u8) []const u8 {
    return ast;
}

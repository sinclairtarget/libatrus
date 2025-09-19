const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;

const Tokenizer = @import("lex/Tokenizer.zig");
const Parser = @import("parse/Parser.zig");
const json = @import("render/json.zig");
pub const Token = @import("lex/tokens.zig").Token;
pub const TokenType = @import("lex/tokens.zig").TokenType;
pub const ast = @import("parse/ast.zig");

pub const version = config.version;

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

pub fn renderJSON(
    root: ast.Node, 
    out: *Io.Writer,
    options: struct { json_options: std.json.Stringify.Options = .{} },
) !void {
    try json.render(root, out, .{ .json_options = options.json_options });
}

pub fn renderYAML(root: []const u8) []const u8 {
    return root;
}

pub fn renderHTML(root: []const u8) []const u8 {
    return root;
}

test tokenize {
    const md =
        \\# I am a heading
        \\I am a paragraph.
    ;
    var reader: Io.Reader = .fixed(md);

    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const expected = [_]TokenType{
        .pound,
        .text,
        .newline,
        .text,
        .eof,
    };

    const tokens = try tokenize(arena, &reader);
    var results = try ArrayList(TokenType).initCapacity(arena, tokens.len);
    for (tokens) |t| {
        try results.append(arena, t.token_type);
    }

    try std.testing.expectEqualSlices(TokenType, &expected, results.items);
}

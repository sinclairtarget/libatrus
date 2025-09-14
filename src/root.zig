const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;

const Tokenizer = @import("lex/Tokenizer.zig");
const Token = @import("lex/tokens.zig").Token;
const AstNode = @import("parse/ast.zig").AstNode;
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

pub fn parse() AstNode {
    return .{
        .root = .{
            .children = &.{
                .{
                    .heading = .{
                        .depth = 1,
                        .children = &.{
                            .{
                                .text = .{
                                    .value = "Heading",
                                },
                            },
                        },
                    },
                },
                .{
                    .paragraph = .{
                        .children = &.{
                            .{
                                .text = .{
                                    .value = "This is a paragraph.",
                                },
                            },
                        },
                    },
                },
            },
        },
    };
}

pub fn renderJSON(ast: AstNode, out: *Io.Writer) !void {
    try json.render(ast, out);
}

pub fn renderYAML(ast: []const u8) []const u8 {
    return ast;
}

pub fn renderHTML(ast: []const u8) []const u8 {
    return ast;
}

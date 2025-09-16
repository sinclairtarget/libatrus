const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;

const ast = @import("ast.zig");
const Tokenizer = @import("../lex/Tokenizer.zig");
const tokens = @import("../lex/tokens.zig");
const Token = tokens.Token;
const TokenType = tokens.TokenType;

const Error = error{
    SyntaxError,
};

// root => (heading* paragraph*)*
// heading => POUND+ text NEWLINE
// paragraph => (text NEWLINE)+ NEWLINE
// text => TEXT
tokenizer: *Tokenizer,
current: ?Token,

const Self = @This();

pub fn init(tokenizer: *Tokenizer) Self {
    return .{
        .tokenizer = tokenizer,
        .current = null,
    };
}

pub fn parse(self: *Self, alloc: Allocator) !ast.Node {
    _ = try self.advance(alloc); // Load first token

    const paragraph = try self.parseParagraph(alloc);
    if (paragraph == null) {
        return Error.SyntaxError;
    }

    var children: ArrayList(ast.Node) = .empty;
    try children.append(alloc, paragraph.?);

    const root = ast.Node{
        .root = .{
            .children = try children.toOwnedSlice(alloc),
        },
    };

    return root;
}

fn parseParagraph(self: *Self, alloc: Allocator) !?ast.Node {
    var children: ArrayList(ast.Node) = .empty;

    while (true) {
        const text = try self.parseText(alloc);
        if (text == null) {
            break;
        }

        try children.append(alloc, text.?);
        _ = try self.match(alloc, .newline);
    }

    _ = try self.match(alloc, .newline);

    return .{
        .paragraph = .{
            .children = try children.toOwnedSlice(alloc),
        },
    };
}

fn parseText(self: *Self, alloc: Allocator) !?ast.Node {
    const token = try self.match(alloc, .text);
    if (token == null) {
        return null;
    }

    return .{
        .text = .{
            .value = token.?.value orelse "",
        },
    };
}

fn match(self: *Self, alloc: Allocator, token_type: TokenType) !?Token {
    if (self.current == null) {
        return null;
    }

    if (self.current.?.token_type != token_type) {
        return null;
    }

    return try self.advance(alloc);
}

fn advance(self: *Self, alloc: Allocator) !?Token {
    const prev = self.current;
    self.current = try self.tokenizer.next(alloc);
    return prev;
}

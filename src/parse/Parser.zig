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

pub fn parse(self: *Self, alloc: Allocator) !*ast.Node {
    _ = try self.advance(alloc); // Load first token

    var children: ArrayList(*ast.Node) = .empty;

    while (self.current.?.token_type != .eof) {
        const len_start = children.items.len;

        var heading = try self.parseHeading(alloc);
        while (heading) |h| : (heading = try self.parseHeading(alloc)) {
            try children.append(alloc, h);
        }

        var paragraph = try self.parseParagraph(alloc);
        while (paragraph) |p| : (paragraph = try self.parseParagraph(alloc)) {
            try children.append(alloc, p);
        }

        if (children.items.len <= len_start) { // Nothing was parsed this loop
            break;
        }
    }

    const node = try alloc.create(ast.Node);
    node.* = .{
        .root = .{
            .children = try children.toOwnedSlice(alloc),
        },
    };
    return node;
}

fn parseHeading(self: *Self, alloc: Allocator) !?*ast.Node {
    var depth: u8 = 0;
    var token = try self.consume(alloc, .pound);
    if (token == null) {
        return null;
    }

    while (token) |_| : (token = try self.consume(alloc, .pound)) {
        depth += 1;
    }

    var children: ArrayList(*ast.Node) = .empty;
    while (true) {
        const text = try self.parseText(alloc);
        if (text) |t| {
            try children.append(alloc, t);
        } else {
            break;
        }
    }

    _ = try self.consume(alloc, .newline);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .heading = .{
            .depth = depth,
            .children = try children.toOwnedSlice(alloc),
        },
    };
    return node;
}

fn parseParagraph(self: *Self, alloc: Allocator) !?*ast.Node {
    var children: ArrayList(*ast.Node) = .empty;

    while (try self.parseText(alloc)) |t| {
        try children.append(alloc, t);
        _ = try self.consume(alloc, .newline);
    }

    if (children.items.len == 0) {
        return null;
    }

    _ = try self.consume(alloc, .newline);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .paragraph = .{
            .children = try children.toOwnedSlice(alloc),
        },
    };
    return node;
}

fn parseText(self: *Self, alloc: Allocator) !?*ast.Node {
    const token = try self.consume(alloc, .text);
    if (token == null) {
        return null;
    }

    const node = try alloc.create(ast.Node);
    node.* = .{
        .text = .{
            .value = token.?.value orelse "",
        },
    };
    return node;
}

fn consume(self: *Self, alloc: Allocator, token_type: TokenType) !?Token {
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

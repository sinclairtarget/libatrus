const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
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

// grammar:
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

pub fn parse(self: *Self, gpa: Allocator) !*ast.Node {
    // Arena used for tokenization
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    _ = try self.advance(arena); // Load first token

    var children: ArrayList(*ast.Node) = .empty;

    while (self.current.?.token_type != .eof) {
        const len_start = children.items.len;

        var heading = try self.parseHeading(gpa, arena);
        while (heading) |h| : (heading = try self.parseHeading(gpa, arena)) {
            try children.append(gpa, h);
        }

        var paragraph = try self.parseParagraph(gpa, arena);
        while (paragraph) |p| : (paragraph = try self.parseParagraph(gpa, arena)) {
            try children.append(gpa, p);
        }

        if (children.items.len <= len_start) { // Nothing was parsed this loop
            break;
        }
    }

    const node = try gpa.create(ast.Node);
    node.* = .{
        .root = .{
            .children = try children.toOwnedSlice(gpa),
        },
    };
    return node;
}

fn parseHeading(self: *Self, gpa: Allocator, arena: Allocator) !?*ast.Node {
    var depth: u8 = 0;
    var token = try self.consume(arena, .pound);
    if (token == null) {
        return null;
    }

    while (token) |_| : (token = try self.consume(arena, .pound)) {
        depth += 1;
    }

    var children: ArrayList(*ast.Node) = .empty;
    while (true) {
        const text = try self.parseText(gpa, arena);
        if (text) |t| {
            try children.append(gpa, t);
        } else {
            break;
        }
    }

    _ = try self.consume(arena, .newline);

    const node = try gpa.create(ast.Node);
    node.* = .{
        .heading = .{
            .depth = depth,
            .children = try children.toOwnedSlice(gpa),
        },
    };
    return node;
}

fn parseParagraph(self: *Self, gpa: Allocator, arena: Allocator) !?*ast.Node {
    var texts: ArrayList(*ast.Node) = .empty;

    while (try self.parseText(gpa, arena)) |t| {
        try texts.append(arena, t);
        _ = try self.consume(arena, .newline);
    }

    if (texts.items.len == 0) {
        return null;
    }

    var buf = Io.Writer.Allocating.init(gpa);
    for (texts.items, 0..) |t, i| {
        if (i < texts.items.len - 1) {
            try buf.writer.print("{s}\n", .{t.text.value});
        } else {
            try buf.writer.print("{s}", .{t.text.value});
        }

        t.deinit(gpa);
    }

    const text_node = try gpa.create(ast.Node);
    text_node.* = .{
        .text = .{
            .value = try buf.toOwnedSlice(),
        },
    };

    const node = try gpa.create(ast.Node);
    var children = try gpa.alloc(*ast.Node, 1);
    children[0] = text_node;

    node.* = .{
        .paragraph = .{
            .children = children,
        },
    };
    return node;
}

fn parseText(self: *Self, gpa: Allocator, arena: Allocator) !?*ast.Node {
    const token = try self.consume(arena, .text);
    if (token == null) {
        return null;
    }

    const node = try gpa.create(ast.Node);
    node.* = .{
        .text = .{
            .value = if (token.?.value) |v|
                try gpa.dupe(u8, v)
            else
                "",
        },
    };
    return node;
}

fn consume(self: *Self, arena: Allocator, token_type: TokenType) !?Token {
    if (self.current == null) {
        return null;
    }

    if (self.current.?.token_type != token_type) {
        return null;
    }

    return try self.advance(arena);
}

fn advance(self: *Self, arena: Allocator) !?Token {
    const prev = self.current;
    self.current = try self.tokenizer.next(arena);
    return prev;
}

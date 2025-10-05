//! Parser pulls tokens from the tokenizer as needed. The tokens are stored in
//! an array list. The array list is cleared as each line is successfully
//! parsed.
//!
//! intended grammar:
//! root          => (atx-heading | paragraph | blank)*
//! atx-heading   => POUND text? POUND? NEWLINE
//! paragraph     => (text-start text* NEWLINE)+
//! text-start    => TEXT | BACKSLASH | POUND(>6)
//! text          => TEXT | BACKSLASH | POUND

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
    UnrecognizedSyntax,
};

tokenizer: *Tokenizer,
line: ArrayList(Token),
i: usize,

const Self = @This();

pub fn init(tokenizer: *Tokenizer) Self {
    return .{
        .tokenizer = tokenizer,
        .line = .empty,
        .i = 0,
    };
}

pub fn parse(self: *Self, gpa: Allocator) !*ast.Node {
    // Arena used for tokenization
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var children: ArrayList(*ast.Node) = .empty;
    errdefer {
        for (children.items) |child| {
            child.deinit(gpa);
        }
        children.deinit(gpa);
    }

    while (try self.peek(arena) != null) {
        const len_start = children.items.len;

        var heading = try self.parseATXHeading(gpa, arena);
        while (heading) |h| {
            try children.append(gpa, h);
            try self.clear_line(arena);
            heading = try self.parseATXHeading(gpa, arena);
        }

        var paragraph = try self.parseParagraph(gpa, arena);
        while (paragraph) |p| : (paragraph = try self.parseParagraph(gpa, arena)) {
            try children.append(gpa, p);
            try self.clear_line(arena);
        }

        // blank lines
        var lines_skipped: u32 = 0;
        while (try self.consume(arena, .newline) != null) {
            lines_skipped += 1;
        }

        if (children.items.len <= len_start and lines_skipped == 0) {
            // Nothing parsed this loop
            return Error.UnrecognizedSyntax;
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

fn parseATXHeading(self: *Self, gpa: Allocator, arena: Allocator) !?*ast.Node {
    const token = try self.consume(arena, .pound);
    if (token == null) {
        return null;
    }

    const depth = token.?.lexeme.?.len;
    if (depth > 6) { // https://spec.commonmark.org/0.31.2/#example-63
        self.i -= 1; // backtrack
        return null;
    }

    var children: ArrayList(*ast.Node) = .empty;

    var buf = Io.Writer.Allocating.init(arena);
    while (true) {
        const current = try self.peek(arena);
        if (current == null) {
            break;
        }

        const pound = try self.consume(arena, .pound);
        if (pound != null) {
            if (try self.peek(arena)) |t| {
                if (t.token_type == .newline) {
                    break;
                }
            }

            self.i -= 1; // backtrack
        }

        const text = try self.parseText(gpa, arena);
        if (text) |t| {
            try buf.writer.print("{s}", .{t.text.value});
            t.deinit(gpa);
        } else {
            break;
        }
    }

    _ = try self.consume(arena, .newline);

    const text_value = std.mem.trim(u8, buf.written(), " \t");
    const text_node = try createTextNode(gpa, text_value);
    try children.append(gpa, text_node);

    const node = try gpa.create(ast.Node);
    node.* = .{
        .heading = .{
            .depth = @truncate(token.?.lexeme.?.len),
            .children = try children.toOwnedSlice(gpa),
        },
    };
    return node;
}

fn parseParagraph(self: *Self, gpa: Allocator, arena: Allocator) !?*ast.Node {
    var lines: ArrayList([]const u8) = .empty;
    while (true) {
        const start = try self.parseTextStart(gpa, arena);
        if (start == null) {
            break;
        }

        var line = Io.Writer.Allocating.init(arena);

        try line.writer.print("{s}", .{start.?.text.value});
        start.?.deinit(gpa);

        while (try self.parseText(gpa, arena)) |t| {
            try line.writer.print("{s}", .{t.text.value});
            t.deinit(gpa);
        }

        try lines.append(arena, line.written());
        _ = try self.consume(arena, .newline);
    }

    if (lines.items.len == 0) {
        return null;
    }

    // Join lines by putting a space between them
    var buf = Io.Writer.Allocating.init(arena);
    for (lines.items, 0..) |line, i| {
        try buf.writer.print("{s}", .{line});
        if (i < lines.items.len - 1) {
            try buf.writer.print(" ", .{});
        }
    }

    const text_node = try createTextNode(gpa, buf.written());

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
    const token = try self.peek(arena);
    if (token == null) {
        return null;
    }

    switch (token.?.token_type) {
        .text, .pound => {
            const value = if (token.?.lexeme) |v| v else "";
            self.advance();
            return createTextNode(gpa, value);
        },
        else => {
            return null;
        },
    }
}

fn parseTextStart(self: *Self, gpa: Allocator, arena: Allocator) !?*ast.Node {
    const token = try self.peek(arena);
    if (token == null) {
        return null;
    }

    fsm: switch (token.?.token_type) {
        .pound => {
            if (token.?.lexeme != null and token.?.lexeme.?.len > 6) {
                continue :fsm .text;
            } else {
                return null;
            }
        },
        .text => {
            const value = if (token.?.lexeme) |v| v else "";
            self.advance();
            return createTextNode(gpa, value);
        },
        else => {
            return null;
        },
    }
}

fn createTextNode(gpa: Allocator, value: []const u8) !*ast.Node {
    const node = try gpa.create(ast.Node);
    node.* = .{
        .text = .{
            .value = try gpa.dupe(u8, value),
        },
    };
    return node;
}

fn peek(self: *Self, arena: Allocator) !?Token {
    if (self.i >= self.line.items.len) {
        const next = try self.tokenizer.next(arena);
        if (next == null) {
            return null; // end of input
        }

        try self.line.append(arena, next.?);
    }

    return self.line.items[self.i];
}

fn consume(self: *Self, arena: Allocator, token_type: TokenType) !?Token {
    const current = try self.peek(arena);

    if (current == null) {
        return null;
    }

    if (current.?.token_type != token_type) {
        return null;
    }

    self.advance();
    return current;
}

fn advance(self: *Self) void {
    self.i += 1;
}

fn clear_line(self: *Self, arena: Allocator) !void {
    std.debug.assert(self.line.items.len > 0);

    const current = try self.peek(arena);
    self.i = 0;
    self.line.clearRetainingCapacity();

    if (current) |c| {
        try self.line.append(arena, c);
    }
}

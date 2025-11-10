const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const ast = @import("ast.zig");
const tokens = @import("../lex/tokens.zig");
const InlineToken = tokens.InlineToken;
const InlineTokenType = tokens.InlineTokenType;
const InlineTokenizer = @import("../lex/InlineTokenizer.zig");
const references = @import("references.zig");

const Error = error{
    UnrecognizedInlineToken,
};

tokenizer: *InlineTokenizer,
line: ArrayList(InlineToken),
token_index: usize,

const Self = @This();

pub fn init(tokenizer: *InlineTokenizer) Self {
    return .{
        .tokenizer = tokenizer,
        .line = .empty,
        .token_index = 0,
    };
}

pub fn parse(self: *Self, gpa: Allocator, arena: Allocator) ![]*ast.Node {
    var nodes: ArrayList(*ast.Node) = .empty;
    errdefer {
        for (nodes.items) |node| {
            node.deinit(gpa);
        }
    }

    while (try self.peek(arena) != null) {
        if (try self.parseEmphasis(gpa, arena)) |emphasis| {
            try nodes.append(arena, emphasis);
        } else if (try self.parseText(gpa, arena)) |text| {
            try nodes.append(arena, text);
        } else if (try self.parseFallbackText(gpa, arena)) |text| {
            try nodes.append(arena, text);
        } else {
            // Nothing parsed this loop
            const t = try self.peek(arena);
            std.debug.print("unsure how to parse: {f}\n", .{t.?});
            for (self.line.items) |prev_t| {
                std.debug.print("{f}\n", .{prev_t});
            }
            return error.UnrecognizedInlineToken;
        }
    }

    return nodes.toOwnedSlice(arena);
}

fn parseEmphasis(
    self: *Self,
    gpa: Allocator,
    arena: Allocator,
) !?*ast.Node {
    const begin = try self.peek(arena);
    if (begin == null) {
        return null;
    }

    var emphasis_node: ?*ast.Node = null;
    var children: ArrayList(*ast.Node) = .empty;
    const checkpoint_index = self.checkpoint();
    defer {
        if (emphasis_node == null) {
            self.backtrack(checkpoint_index);

            for (children.items) |child| {
                child.deinit(gpa);
            }
            children.deinit(gpa);
        }
    }

    switch (begin.?.token_type) {
        .l_delim_star => {
            _ = try self.consume(arena, .l_delim_star);
        },
        else => return null,
    }

    while (true) {
        if (try self.parseEmphasis(gpa, arena)) |emphasis| {
            try children.append(gpa, emphasis);
            continue;
        }

        if (try self.parseText(gpa, arena)) |text| {
            try children.append(gpa, text);
            continue;
        }

        break;
    }

    const end = try self.peek(arena);
    if (end == null) {
        return null;
    }

    switch (end.?.token_type) {
        .r_delim_star => {
            _ = try self.consume(arena, .r_delim_star);
        },
        else => {
            return null;
        },
    }

    emphasis_node = try gpa.create(ast.Node);
    emphasis_node.?.* = .{
        .emphasis = .{
            .children = try children.toOwnedSlice(gpa),
        },
    };
    return emphasis_node;
}

fn parseText(self: *Self, gpa: Allocator, arena: Allocator) !?*ast.Node {
    var values: ArrayList([]const u8) = .empty;

    loop: while (try self.peek(arena)) |token| {
        switch (token.token_type) {
            .decimal_character_reference => {
                const lexeme = token.lexeme.?;
                const value = try references.resolveCharacter(
                    arena,
                    lexeme[2..lexeme.len - 1],
                    10, // base
                );
                try values.append(arena, value);
                _ = try self.consume(arena, .decimal_character_reference);
            },
            .hexadecimal_character_reference => {
                const lexeme = token.lexeme.?;
                const value = try references.resolveCharacter(
                    arena,
                    lexeme[3..lexeme.len - 1],
                    16, // base
                );
                try values.append(arena, value);
                _ = try self.consume(arena, .hexadecimal_character_reference);
            },
            .entity_reference => {
                const lexeme = token.lexeme.?;
                const value = references.resolveEntity(lexeme[1..lexeme.len - 1]);
                if (value) |v| {
                    try values.append(arena, v);
                } else {
                    // Unknown entity
                    try values.append(arena, lexeme);
                }
                _ = try self.consume(arena, .entity_reference);
            },
            .newline => {
                try values.append(arena, "\n");
                _ = try self.consume(arena, .newline);
            },
            .text => {
                const value = token.lexeme orelse "";
                try values.append(arena, value);
                _ = try self.consume(arena, .text);
            },
            else => break :loop,
        }
    }

    if (values.items.len == 0) {
        return null;
    }

    return try createTextNode(gpa, values.items);
}

fn parseFallbackText(self: *Self, gpa: Allocator, arena: Allocator) !?*ast.Node {
    var values: ArrayList([]const u8) = .empty;

    while (try self.peek(arena)) |token| {
        switch (token.token_type) {
            .decimal_character_reference => {
                const lexeme = token.lexeme.?;
                const value = try references.resolveCharacter(
                    arena,
                    lexeme[2..lexeme.len - 1],
                    10, // base
                );
                try values.append(arena, value);
                _ = try self.consume(arena, .decimal_character_reference);
            },
            .hexadecimal_character_reference => {
                const lexeme = token.lexeme.?;
                const value = try references.resolveCharacter(
                    arena,
                    lexeme[3..lexeme.len - 1],
                    16, // base
                );
                try values.append(arena, value);
                _ = try self.consume(arena, .hexadecimal_character_reference);
            },
            .entity_reference => {
                const lexeme = token.lexeme.?;
                const value = references.resolveEntity(lexeme[1..lexeme.len - 1]);
                if (value) |v| {
                    try values.append(arena, v);
                } else {
                    // Unknown entity
                    try values.append(arena, lexeme);
                }
                _ = try self.consume(arena, .entity_reference);
            },
            .newline => {
                try values.append(arena, "\n");
                _ = try self.consume(arena, .newline);
            },
            .text, .l_delim_star, .r_delim_star, .lr_delim_star => |t| {
                const value = token.lexeme orelse "";
                try values.append(arena, value);
                _ = try self.consume(arena, t);
            },
        }
    }

    if (values.items.len == 0) {
        return null;
    }

    return try createTextNode(gpa, values.items);
}

fn createTextNode(gpa: Allocator, values: [][]const u8) !*ast.Node {
    std.debug.assert(values.len > 0);

    const node = try gpa.create(ast.Node);
    node.* = .{
        .text = .{
            .value = try std.mem.join(gpa, "", values),
        },
    };
    return node;
}

fn peek(self: *Self, arena: Allocator) !?InlineToken {
    if (self.token_index >= self.line.items.len) {
        const next = try self.tokenizer.next(arena);
        if (next == null) {
            return null; // end of input
        }

        try self.line.append(arena, next.?);
    }

    return self.line.items[self.token_index];
}

fn consume(
    self: *Self,
    arena: Allocator,
    token_type: InlineTokenType,
) !?InlineToken {
    const current = try self.peek(arena);

    if (current == null) {
        return null;
    }

    if (current.?.token_type != token_type) {
        return null;
    }

    self.token_index += 1;
    return current;
}

fn checkpoint(self: *Self) usize {
    return self.token_index;
}

fn backtrack(self: *Self, checkpoint_index: usize) void {
    self.token_index = checkpoint_index;
}

pub fn transform(gpa: Allocator, original_node: *ast.Node) !*ast.Node {
    switch (original_node.*) {
        .root => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(gpa, n.children[i]);
            }
            return original_node;
        },
        .block => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(gpa, n.children[i]);
            }
            return original_node;
        },
        .paragraph => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(gpa, n.children[i]);
            }

            const children = try parseInlineNodes(gpa, n.children);
            if (children.ptr == n.children.ptr) {
                return original_node; // nothing was changed
            }
            defer original_node.deinit(gpa);

            const node = try gpa.create(ast.Node);
            node.* = .{
                .paragraph = .{
                    .children = children,
                },
            };
            return node;
        },
        .heading => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(gpa, n.children[i]);
            }

            const children = try parseInlineNodes(gpa, n.children);
            if (children.ptr == n.children.ptr) {
                return original_node; // nothing was changed
            }
            defer original_node.deinit(gpa);

            const node = try gpa.create(ast.Node);
            node.* = .{
                .heading = .{
                    .children = children,
                    .depth = n.depth,
                },
            };
            return node;
        },
        .text, .code, .thematic_break, .emphasis => return original_node,
    }
}

fn parseInlineNodes(gpa: Allocator, original_nodes: []*ast.Node) ![]*ast.Node {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var nodes: ArrayList(*ast.Node) = .empty;

    var did_replace_something = false;
    for (original_nodes) |node| {
        switch (node.*) {
            .text => |n| {
                var tokenizer = InlineTokenizer.init(n.value);
                var parser = Self.init(&tokenizer);
                const replacement_nodes = try parser.parse(gpa, arena);
                for (replacement_nodes) |replacement| {
                    try nodes.append(gpa, replacement);
                }

                did_replace_something = true;
            },
            else => {
                try nodes.append(gpa, node);
            },
        }

        // Clear memory used for scratch and tokenization
        _ = arena_impl.reset(.retain_capacity);
    }

    if (!did_replace_something) {
        nodes.deinit(gpa);
        return original_nodes;
    }

    return nodes.toOwnedSlice(gpa);
}

test "inline unmatched open emphasis" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const value = "This *is unmatched.";

    var tokenizer = InlineTokenizer.init(value);
    var parser = Self.init(&tokenizer);
    const nodes = try parser.parse(std.testing.allocator, arena);
    defer {
        for (nodes) |n| {
            n.deinit(std.testing.allocator);
        }
    }

    try std.testing.expectEqual(1, nodes.len);
    try std.testing.expectEqualStrings(value, nodes[0].text.value);
}

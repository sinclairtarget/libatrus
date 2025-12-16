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

/// Parse inline tokens from the token stream.
///
/// Returns a list of AST nodes, to be made the children of some block-level
/// node.
pub fn parse(self: *Self, gpa: Allocator, arena: Allocator) ![]*ast.Node {
    var nodes: ArrayList(*ast.Node) = .empty;
    defer nodes.deinit(gpa);
    errdefer {
        for (nodes.items) |node| {
            node.deinit(gpa);
        }
    }

    while (try self.peek(arena) != null) {
        if (try self.parseStarEmphasis(gpa, arena)) |emphasis| {
            try nodes.append(gpa, emphasis);
        } else if (try self.parseText(gpa, arena)) |text| {
            try nodes.append(gpa, text);
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

    const joined_nodes = try joinSiblingNodes(gpa, nodes.items);
    return joined_nodes;
}

// inner => text | star_emph
// star_emph => *l inner *r
fn parseStarEmphasis(
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

    if (try self.parseStarEmphasis(gpa, arena)) |emphasis| {
        try children.append(gpa, emphasis);
    } else if (try self.parseText(gpa, arena)) |text| {
        try children.append(gpa, text);
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

// head => ref10 | ref16 | ref& | \n | text | *l | *lr | *r
// tail => ref10 | ref16 | ref& | \n | text
// text => head tail*
fn parseText(self: *Self, gpa: Allocator, arena: Allocator) !?*ast.Node {
    var values: ArrayList([]const u8) = .empty;

    // head
    const maybe_head_token = try self.peek(arena);
    if (maybe_head_token == null) {
        return null;
    }

    const head_token = maybe_head_token.?;
    switch (head_token.token_type) {
        .decimal_character_reference, .hexadecimal_character_reference,
        .entity_reference => |t| {
            const value = try resolveReference(arena, head_token);
            try values.append(arena, value);
            _ = try self.consume(arena, t);
        },
        .newline => {
            try values.append(arena, "\n");
            _ = try self.consume(arena, .newline);
        },
        .l_delim_star, .lr_delim_star, .r_delim_star => |t| {
            try values.append(arena, "*");
            _ = try self.consume(arena, t);
        },
        .text => |t| {
            const value = head_token.lexeme orelse "";
            try values.append(arena, value);
            _ = try self.consume(arena, t);
        },
    }

    // tail
    loop: while (try self.peek(arena)) |token| {
        switch (token.token_type) {
            .decimal_character_reference, .hexadecimal_character_reference,
            .entity_reference => |t| {
                const value = try resolveReference(arena, token);
                try values.append(arena, value);
                _ = try self.consume(arena, t);
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

    return try createTextNode(gpa, values.items);
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

fn resolveReference(arena: Allocator, token: InlineToken) ![]const u8 {
    switch (token.token_type) {
        .decimal_character_reference => {
            const lexeme = token.lexeme.?;
            const value = try references.resolveCharacter(
                arena,
                lexeme[2..lexeme.len - 1],
                10, // base
            );
            return value;
        },
        .hexadecimal_character_reference => {
            const lexeme = token.lexeme.?;
            const value = try references.resolveCharacter(
                arena,
                lexeme[3..lexeme.len - 1],
                16, // base
            );
            return value;
        },
        .entity_reference => {
            const lexeme = token.lexeme.?;
            const value = references.resolveEntity(lexeme[1..lexeme.len - 1]);
            if (value) |v| {
                return v;
            } else {
                return lexeme;
            }
        },
        else => unreachable,
    }
}

/// Merge adjacent text siblings.
fn joinSiblingNodes(gpa: Allocator, nodes: []*ast.Node) ![]*ast.Node {
    var joined: ArrayList(*ast.Node) = .empty;

    var siblings: ArrayList(*ast.Node) = .empty;
    defer siblings.deinit(gpa);
    for (nodes) |node| {
        if (node.* == ast.NodeType.text) {
            try siblings.append(gpa, node);
            continue;
        }

        if (siblings.items.len > 0) {
            var values: ArrayList([]const u8) = .empty;
            defer values.deinit(gpa);
            for (siblings.items) |sibling| {
                try values.append(gpa, sibling.text.value);
            }
            const text_node = try createTextNode(gpa, values.items);
            try joined.append(gpa, text_node);

            for (siblings.items) |sibling| {
                sibling.deinit(gpa);
            }
            siblings.clearRetainingCapacity();
        }

        try joined.append(gpa, node);
    }

    if (siblings.items.len > 0) {
        var values: ArrayList([]const u8) = .empty;
        defer values.deinit(gpa);
        for (siblings.items) |sibling| {
            try values.append(gpa, sibling.text.value);
        }
        const text_node = try createTextNode(gpa, values.items);
        try joined.append(gpa, text_node);

        for (siblings.items) |sibling| {
            sibling.deinit(gpa);
        }
        siblings.clearRetainingCapacity();
    }

    return joined.toOwnedSlice(gpa);
}

fn createTextNode(gpa: Allocator, values: [][]const u8) !*ast.Node {
    const node = try gpa.create(ast.Node);
    node.* = .{
        .text = .{
            .value = try std.mem.join(gpa, "", values),
        },
    };
    return node;
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
fn parseNodes(value: []const u8) ![]*ast.Node {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var tokenizer = InlineTokenizer.init(value);
    var parser = Self.init(&tokenizer);
    return try parser.parse(std.testing.allocator, arena);
}

fn freeNodes(nodes: []*ast.Node) void {
    for (nodes) |n| {
        n.deinit(std.testing.allocator);
    }
    std.testing.allocator.free(nodes);
}

test "star emphasis" {
    const value = "This *is emphasized.*";
    const nodes = try parseNodes(value);
    defer freeNodes(nodes);

    try std.testing.expectEqual(2, nodes.len);
    try std.testing.expectEqual(
        ast.NodeType.text,
        @as(ast.NodeType, nodes[0].*),
    );
    try std.testing.expectEqual(
        ast.NodeType.emphasis,
        @as(ast.NodeType, nodes[1].*),
    );
    try std.testing.expectEqualStrings(
        "is emphasized.",
        nodes[1].emphasis.children[0].text.value,
    );
}

test "unmatched open star emphasis" {
    const value = "This *is unmatched.";
    const nodes = try parseNodes(value);
    defer freeNodes(nodes);

    try std.testing.expectEqual(1, nodes.len);
    try std.testing.expectEqual(
        ast.NodeType.text,
        @as(ast.NodeType, nodes[0].*),
    );
    try std.testing.expectEqualStrings(value, nodes[0].text.value);
}

test "unmatched close star emphasis" {
    const value = "This is unmatched.*";
    const nodes = try parseNodes(value);
    defer freeNodes(nodes);

    try std.testing.expectEqual(1, nodes.len);
    try std.testing.expectEqual(
        ast.NodeType.text,
        @as(ast.NodeType, nodes[0].*),
    );
    try std.testing.expectEqualStrings(value, nodes[0].text.value);
}

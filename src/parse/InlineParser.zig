//! Parser for the second parsing stage that handles inline elements.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const ast = @import("ast.zig");
const tokens = @import("../lex/tokens.zig");
const InlineToken = tokens.InlineToken;
const InlineTokenType = tokens.InlineTokenType;
const InlineTokenizer = @import("../lex/InlineTokenizer.zig");
const references = @import("references.zig");
const safety = @import("../util/safety.zig");

pub const Error = (
    references.CharacterReferenceError || Allocator.Error
);

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
/// Returns a slice of AST nodes that the caller is responsible for freeing.
pub fn parse(self: *Self, gpa: Allocator, arena: Allocator) Error![]*ast.Node {
    var nodes: ArrayList(*ast.Node) = .empty;
    defer nodes.deinit(gpa);
    errdefer {
        for (nodes.items) |node| {
            node.deinit(gpa);
        }
    }

    for (0..safety.loop_bound) |_| { // could hit if we forget to consume tokens
        _ = try self.peek(arena) orelse break;

        if (try self.parseStarEmphasis(gpa, arena)) |emphasis| {
            try nodes.append(gpa, emphasis);
            continue;
        }

        if (try self.parseStarStrong(gpa, arena)) |strong| {
            try nodes.append(gpa, strong);
            continue;
        }

        if (try self.parseText(gpa, arena)) |text| {
            try nodes.append(gpa, text);
            continue;
        }

        if (try self.parseTextFallback(gpa, arena)) |text| {
            try nodes.append(gpa, text);
            continue;
        }

        @panic("unable to parse inline token");
    } else @panic(safety.loop_bound_panic_msg);

    const joined_nodes = try joinSiblingTextNodes(gpa, nodes.items);
    return joined_nodes;
}

// strong => open inner close
// open   => l_star l_star | lr_star lr_star
// close  => r_star r_star | lr_star lr_star
// inner  => (emph | strong | text)+
fn parseStarStrong(
    self: *Self,
    gpa: Allocator,
    arena: Allocator,
) Error!?*ast.Node {
    var strong_node: ?*ast.Node = null;
    var children: ArrayList(*ast.Node) = .empty;
    const checkpoint_index = self.checkpoint();
    defer {
        if (strong_node == null) {
            self.backtrack(checkpoint_index);
            for (children.items) |child| {
                child.deinit(gpa);
            }
            children.deinit(gpa);
        }
    }

    const open_token = try self.peek(arena) orelse return null;
    switch (open_token.token_type) {
        .l_delim_star, .lr_delim_star => |t| {
            _ = try self.consume(arena, t) orelse return null;
            _ = try self.consume(arena, t) orelse return null;
        },
        else => return null,
    }

    for (0..safety.loop_bound) |_| {
        if (try self.parseStarEmphasis(gpa, arena)) |emph| {
            try children.append(gpa, emph);
            continue;
        }

        if (try self.parseStarStrong(gpa, arena)) |strong| {
            try children.append(gpa, strong);
            continue;
        }

        if (try self.parseText(gpa, arena)) |text| {
            try children.append(gpa, text);
            continue;
        }

        break;
    } else @panic(safety.loop_bound_panic_msg);

    if (children.items.len == 0) {
        return null;
    }

    const close_token = try self.peek(arena) orelse return null;
    switch (close_token.token_type) {
        .r_delim_star, .lr_delim_star => |t| {
            _ = try self.consume(arena, t) orelse return null;
            _ = try self.consume(arena, t) orelse return null;
        },
        else => return null,
    }

    strong_node = try gpa.create(ast.Node);
    strong_node.?.* = .{
        .strong = .{
            .children = try children.toOwnedSlice(gpa),
        },
    };
    return strong_node;
}

// emph  => open inner close
// open  => l_star | lr_star
// close => r_star | lr_star
// inner => (strong (text | emph)? | emph? (strong | text) emph?)+
fn parseStarEmphasis(
    self: *Self,
    gpa: Allocator,
    arena: Allocator,
) Error!?*ast.Node {
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

    const open_token = try self.peek(arena) orelse return null;
    switch (open_token.token_type) {
        .l_delim_star, .lr_delim_star => |t| _ = try self.consume(arena, t),
        else => return null,
    }

    for (0..safety.loop_bound) |_| {
        if (try self.parseStarStrong(gpa, arena)) |strong| {
            try children.append(gpa, strong);

            if (try self.parseStarEmphasis(gpa, arena)) |emph| {
                try children.append(gpa, emph);
            } else if (try self.parseText(gpa, arena)) |text| {
                try children.append(gpa, text);
            }

            continue;
        }

        const maybe_leading_emph = try self.parseStarEmphasis(gpa, arena);

        if (try self.parseStarStrong(gpa, arena)) |strong| {
            if (maybe_leading_emph) |emph| {
                try children.append(gpa, emph);
            }
            try children.append(gpa, strong);
        } else if (try self.parseText(gpa, arena)) |text| {
            if (maybe_leading_emph) |emph| {
                try children.append(gpa, emph);
            }
            try children.append(gpa, text);
        } else {
            // Inner nodes did not successfully parse
            if (maybe_leading_emph) |emph| {
                emph.deinit(gpa);
            }
            break;
        }

        if (try self.parseStarEmphasis(gpa, arena)) |emph| {
            try children.append(gpa, emph);
        }
    } else @panic(safety.loop_bound_panic_msg);

    if (children.items.len == 0) {
        return null;
    }

    const close_token = try self.peek(arena) orelse return null;
    switch (close_token.token_type) {
        .r_delim_star, .lr_delim_star => |t| _ = try self.consume(arena, t),
        else => return null,
    }

    emphasis_node = try gpa.create(ast.Node);
    emphasis_node.?.* = .{
        .emphasis = .{
            .children = try children.toOwnedSlice(gpa),
        },
    };
    return emphasis_node;
}

// @       => allowed*
// allowed => ref10 | ref16 | ref& | \n | text
fn parseText(self: *Self, gpa: Allocator, arena: Allocator) Error!?*ast.Node {
    var values: ArrayList([]const u8) = .empty;

    const allowed = .{
        .decimal_character_reference,
        .hexadecimal_character_reference,
        .entity_reference,
        .newline,
        .text,
    };
    outer: for (0..safety.loop_bound) |_| {
        const value = inline for (allowed) |token_type| {
            if (try self.consume(arena, token_type)) |token| {
                break try inlineTextValue(arena, token);
            }
        } else break :outer;
        try values.append(arena, value);
    } else @panic(safety.loop_bound_panic_msg);

    if (values.items.len == 0) {
        return null;
    }

    return try createTextNode(gpa, values.items);
}

// @ => .
fn parseTextFallback(
    self: *Self,
    gpa: Allocator,
    arena: Allocator,
) Error!?*ast.Node {
    const token = try self.peek(arena) orelse return null;
    _ = try self.consume(arena, token.token_type);

    const text_value = try inlineTextValue(arena, token);
    return try createTextNode(gpa, &.{ text_value });
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
    const current = try self.peek(arena) orelse return null;
    if (current.token_type != token_type) {
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

fn inlineTextValue(arena: Allocator, token: InlineToken) ![]const u8 {
    const value = switch (token.token_type) {
        .decimal_character_reference, .hexadecimal_character_reference,
        .entity_reference => blk: {
            break :blk try resolveCharacterEntityRef(arena, token);
        },
        .newline => "\n",
        .text => token.lexeme,
        .l_delim_star, .r_delim_star, .lr_delim_star => "*",
    };
    return value;
}

fn resolveCharacterEntityRef(arena: Allocator, token: InlineToken) ![]const u8 {
    switch (token.token_type) {
        .decimal_character_reference => {
            const value = try references.resolveCharacter(
                arena,
                token.lexeme[2..token.lexeme.len - 1],
                10, // base
            );
            return value;
        },
        .hexadecimal_character_reference => {
            const value = try references.resolveCharacter(
                arena,
                token.lexeme[3..token.lexeme.len - 1],
                16, // base
            );
            return value;
        },
        .entity_reference => {
            const lexeme = token.lexeme;
            const value = references.resolveEntity(lexeme[1..lexeme.len - 1]);
            return value orelse lexeme;
        },
        else => unreachable,
    }
}

/// Merge adjacent text siblings.
fn joinSiblingTextNodes(gpa: Allocator, nodes: []*ast.Node) ![]*ast.Node {
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

fn createTextNode(gpa: Allocator, values: []const []const u8) !*ast.Node {
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
const testing = std.testing;

fn parseIntoNodes(value: []const u8) ![]*ast.Node {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var tokenizer = InlineTokenizer.init(value);
    var parser = Self.init(&tokenizer);
    return try parser.parse(testing.allocator, arena);
}

fn freeNodes(nodes: []*ast.Node) void {
    for (nodes) |n| {
        n.deinit(testing.allocator);
    }
    testing.allocator.free(nodes);
}

test "star emphasis" {
    const value = "This *is emphasized.*";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(2, nodes.len);
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[0].*));
    try testing.expectEqual(
        ast.NodeType.emphasis,
        @as(ast.NodeType, nodes[1].*),
    );
    try testing.expectEqualStrings(
        "is emphasized.",
        nodes[1].emphasis.children[0].text.value,
    );
}

test "intraword star emphasis" {
    const value = "em*pha*sis";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[0].*));
    try testing.expectEqual(
        ast.NodeType.emphasis,
        @as(ast.NodeType, nodes[1].*),
    );
    try testing.expectEqualStrings(
        "pha",
        nodes[1].emphasis.children[0].text.value,
    );
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[2].*));
}

test "nested star emphasis" {
    const value = "This **is* emphasized.*";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(2, nodes.len);
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[0].*));

    try testing.expectEqual(
        ast.NodeType.emphasis,
        @as(ast.NodeType, nodes[1].*),
    );
    try testing.expectEqual(2, nodes[1].emphasis.children.len);

    const nested_emph = nodes[1].emphasis.children[0];
    try testing.expectEqual(
        ast.NodeType.emphasis,
        @as(ast.NodeType, nested_emph.*),
    );
    try testing.expectEqualStrings(
        "is",
        nested_emph.emphasis.children[0].text.value,
    );
    try testing.expectEqualStrings(
        " emphasized.",
        nodes[1].emphasis.children[1].text.value,
    );
}

test "unmatched open star emphasis" {
    const value = "This *is unmatched.";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[0].*));
    try testing.expectEqualStrings(value, nodes[0].text.value);
}

test "unmatched close star emphasis" {
    const value = "This is unmatched.*";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[0].*));
    try testing.expectEqualStrings(value, nodes[0].text.value);
}

test "same delimiter run star emphasis" {
    const value = "This is not ** emphasis.";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[0].*));
    try testing.expectEqualStrings(value, nodes[0].text.value);
}

test "same delimiter run star strong" {
    const value = "This is not **** strong.";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[0].*));
    try testing.expectEqualStrings(value, nodes[0].text.value);
}

test "star strong" {
    const value = "This is **strongly emphasized**.";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[0].*));

    try testing.expectEqual(ast.NodeType.strong, @as(ast.NodeType, nodes[1].*));
    try testing.expectEqualStrings(
        "strongly emphasized",
        nodes[1].strong.children[0].text.value,
    );

    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[2].*));
}

test "triple star strong nested" {
    const value = "This is ***a strong in an emphasis***.";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[0].*));
    try testing.expectEqualStrings("This is ", nodes[0].text.value);

    try testing.expectEqual(
        ast.NodeType.emphasis,
        @as(ast.NodeType, nodes[1].*),
    );
    try testing.expectEqual(
        ast.NodeType.strong,
        @as(ast.NodeType, nodes[1].emphasis.children[0].*),
    );
    try testing.expectEqualStrings(
        "a strong in an emphasis",
        nodes[1].emphasis.children[0].strong.children[0].text.value,
    );

    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[2].*));
    try testing.expectEqualStrings(".", nodes[2].text.value);
}

test "star strong nested inside star emphasis" {
    const value = "This ***is strong** that is also emphasized*.";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[0].*));

    const emphasis_node = nodes[1];
    try testing.expectEqual(
        ast.NodeType.emphasis,
        @as(ast.NodeType, emphasis_node.*),
    );
    try testing.expectEqual(2, emphasis_node.emphasis.children.len);
    try testing.expectEqual(
        ast.NodeType.strong,
        @as(ast.NodeType, emphasis_node.emphasis.children[0].*),
    );
    try testing.expectEqualStrings(
        "is strong",
        emphasis_node.emphasis.children[0].strong.children[0].text.value,
    );
    try testing.expectEqual(
        ast.NodeType.text,
        @as(ast.NodeType, emphasis_node.emphasis.children[1].*),
    );
    try testing.expectEqualStrings(
        " that is also emphasized",
        emphasis_node.emphasis.children[1].text.value,
    );

    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[2].*));
}

test "star emphasis nested inside star strong" {
    const value = "This ***is emphasis* that is also strong**.";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[0].*));

    const strong_node = nodes[1];
    try testing.expectEqual(
        ast.NodeType.strong,
        @as(ast.NodeType, strong_node.*),
    );
    try testing.expectEqual(2, strong_node.strong.children.len);
    try testing.expectEqual(
        ast.NodeType.emphasis,
        @as(ast.NodeType, strong_node.strong.children[0].*),
    );
    try testing.expectEqualStrings(
        "is emphasis",
        strong_node.strong.children[0].emphasis.children[0].text.value,
    );
    try testing.expectEqual(
        ast.NodeType.text,
        @as(ast.NodeType, strong_node.strong.children[1].*),
    );
    try testing.expectEqualStrings(
        " that is also strong",
        strong_node.strong.children[1].text.value,
    );

    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[2].*));
}

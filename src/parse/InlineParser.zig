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
i: usize,

const Self = @This();

pub fn init(tokenizer: *InlineTokenizer) Self {
    return .{
        .tokenizer = tokenizer,
        .line = .empty,
        .i = 0,
    };
}

fn parse(self: *Self, gpa: Allocator, arena: Allocator) ![]*ast.Node {
    var nodes: ArrayList(*ast.Node) = .empty;
    errdefer {
        for (nodes.items) |node| {
            node.deinit(gpa);
        }
    }

    while (try self.peek(arena) != null) {
        const len_start = nodes.items.len;

        if (try self.parseEmphasis(gpa, arena)) |emphasis| {
            try nodes.append(arena, emphasis);
        }

        if (try self.parseText(gpa, arena)) |text| {
            try nodes.append(arena, text);
        }

        if (nodes.items.len <= len_start) {
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

fn parseEmphasis(self: *Self, gpa: Allocator, arena: Allocator) !?*ast.Node {
    const begin = try self.peek(arena);
    if (begin == null) {
        return null;
    }

    switch (begin.?.token_type) {
        .l_delim_star => {
            self.advance();
        },
        else => return null,
    }

    var children: ArrayList(*ast.Node) = .empty;
    while (try self.parseText(gpa, arena)) |text| {
        try children.append(gpa, text);
    }

    const end = try self.peek(arena);
    if (end == null) {
        return null;
    }

    switch (end.?.token_type) {
        .r_delim_star => {
            self.advance();
        },
        else => {
            return null;
        },
    }

    const node = try gpa.create(ast.Node);
    node.* = .{
        .emphasis = .{
            .children = try children.toOwnedSlice(gpa),
        },
    };
    return node;
}

fn parseText(self: *Self, gpa: Allocator, arena: Allocator) !?*ast.Node {
    var values: ArrayList([]const u8) = .empty;

    loop: while (try self.peek(arena)) |token| {
        switch (token.token_type) {
            .text => {
                const value = token.lexeme orelse "";
                try values.append(arena, value);
                self.advance();
            },
            .decimal_character_reference => {
                const lexeme = token.lexeme.?;
                const value = try references.resolveCharacter(
                    arena,
                    lexeme[2..lexeme.len - 1],
                    10, // base
                );
                try values.append(arena, value);
                self.advance();
            },
            .hexadecimal_character_reference => {
                const lexeme = token.lexeme.?;
                const value = try references.resolveCharacter(
                    arena,
                    lexeme[3..lexeme.len - 1],
                    16, // base
                );
                try values.append(arena, value);
                self.advance();
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
                self.advance();
            },
            .newline => {
                try values.append(arena, "\n");
                self.advance();
            },
            else => break :loop,
        }
    }

    if (values.items.len == 0) {
        return null;
    }

    const node = try gpa.create(ast.Node);
    node.* = .{
        .text = .{
            .value = try std.mem.join(gpa, "", values.items),
        },
    };
    return node;
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

fn peek(self: *Self, arena: Allocator) !?InlineToken {
    if (self.i >= self.line.items.len) {
        const next = try self.tokenizer.next(arena);
        if (next == null) {
            return null; // end of input
        }

        try self.line.append(arena, next.?);
    }

    return self.line.items[self.i];
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

    self.advance();
    return current;
}

fn advance(self: *Self) void {
    self.i += 1;
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

//! Parser for the first parsing stage that handles block-level parsing.
//!
//! Parser pulls tokens from the tokenizer as needed. The tokens are stored in
//! an array list. The array list is cleared as each line is successfully
//! parsed.

const std = @import("std");
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const ArrayList = std.ArrayList;

const ast = @import("ast.zig");
const BlockTokenizer = @import("../lex/BlockTokenizer.zig");
const tokens = @import("../lex/tokens.zig");
const BlockToken = tokens.BlockToken;
const BlockTokenType = tokens.BlockTokenType;
const safety = @import("../util/safety.zig");
const strings = @import("../util/strings.zig");

const Error = error{
    UnrecognizedBlockToken, // TODO: Remove
};

tokenizer: *BlockTokenizer,
line: ArrayList(BlockToken),
token_index: usize,

const Self = @This();

pub fn init(tokenizer: *BlockTokenizer) Self {
    return .{
        .tokenizer = tokenizer,
        .line = .empty,
        .token_index = 0,
    };
}

/// Parse block tokens from the token stream.
///
/// Returns the root node of the resulting AST. The AST may contain blocks of
/// unparsed inline text.
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

    for (0..safety.loop_bound) |_| { // could hit if we forget to consume tokens
        _ = try self.peek(arena) orelse break;

        const maybe_next = blk: {
            if (try self.parseIndentedCode(gpa, arena)) |indent_code| {
                break :blk indent_code;
            }

            if (try self.parseATXHeading(gpa, arena)) |heading| {
                break :blk heading;
            }

            if (try self.parseThematicBreak(gpa, arena)) |thematic_break| {
                break :blk thematic_break;
            }

            if (try self.parseParagraph(gpa, arena)) |paragraph| {
                break :blk paragraph;
            }

            break :blk null;
        };
        if (maybe_next) |next| {
            try children.append(gpa, next);
            try self.clear_line(arena);
            continue;
        }

        // blank lines
        if (try self.consume(arena, .newline) != null) {
            continue;
        }

        @panic("unable to parse block token");
    } else @panic(safety.loop_bound_panic_msg);

    const node = try gpa.create(ast.Node);
    node.* = .{
        .root = .{
            .children = try children.toOwnedSlice(gpa),
        },
    };
    return node;
}

fn parseATXHeading(self: *Self, gpa: Allocator, arena: Allocator) !?*ast.Node {
    const start_token = try self.peek(arena) orelse return null;
    if (start_token.token_type != .pound) {
        return null;
    }

    const depth = start_token.lexeme.len;
    if (depth > 6) { // https://spec.commonmark.org/0.31.2/#example-63
        return null;
    }

    _ = try self.consume(arena, .pound);

    var buf = Io.Writer.Allocating.init(arena);
    for (0..safety.loop_bound) |_| {
        const current = try self.peek(arena) orelse break;
        if (current.token_type == .pound) {
            // Look ahead for a newline. If there is one, this is a closing
            // sequence of #.
            const checkpoint_index = self.checkpoint();
            _ = try self.consume(arena, .pound);
            if (try self.peek(arena)) |t| {
                if (t.token_type == .newline) {
                    break;
                }
            }

            // Okay, not a closing sequence.
            self.backtrack(checkpoint_index);
        }

        const node = try self.parseText(gpa, arena) orelse break;
        try buf.writer.print("{s}", .{node.text.value});
        node.deinit(gpa);
    } else @panic(safety.loop_bound_panic_msg);

    _ = try self.consume(arena, .newline);

    var children: []const *ast.Node = &.{};
    const inner_value = std.mem.trim(u8, buf.written(), " \t");
    if (inner_value.len > 0) {
        const text_node = try createTextNode(gpa, inner_value);
        children = &.{ text_node };
    }

    const node = try gpa.create(ast.Node);
    node.* = .{
        .heading = .{
            .depth = @truncate(depth),
            .children = try gpa.dupe(*ast.Node, children),
        },
    };
    return node;
}

fn parseThematicBreak(
    self: *Self,
    gpa: Allocator,
    arena: Allocator,
) !?*ast.Node {
    const token = try self.peek(arena) orelse return null;
    switch (token.token_type) {
        .rule_star, .rule_underline, .rule_dash_with_whitespace => |t| {
            _ = try self.consume(arena, t);
        },
        .rule_dash => |t| {
            if (token.lexeme.len < 3) {
                return null;
            }

            _ = try self.consume(arena, t);
        },
        else => return null,
    }

    _ = try self.consume(arena, .newline);

    const node = try gpa.create(ast.Node);
    node.* = .{ .thematic_break = .{} };
    return node;
}

fn parseIndentedCode(
    self: *Self,
    gpa: Allocator,
    arena: Allocator,
) !?*ast.Node {
    // Has to start with an indent
    const initial = try self.peek(arena) orelse return null;
    if (initial.token_type != .indent) {
        return null;
    }

    // Parse one or more indented lines
    var lines: ArrayList([]const u8) = .empty;
    for (0..safety.loop_bound) |_| {
        const line_start = try self.peek(arena) orelse break;

        var line = Io.Writer.Allocating.init(arena);
        switch (line_start.token_type) {
            .indent => {
                // Parse a single indented line
                _ = try self.consume(arena, .indent);
                while (try self.peek(arena)) |next| {
                    if (next.token_type == .newline) {
                        break;
                    }

                    _ = try self.consume(arena, next.token_type);
                    try line.writer.print("{s}", .{next.lexeme});
                } else @panic(safety.loop_bound_panic_msg);

                _ = try self.consume(arena, .newline);
            },
            .newline => { // newline doesn't end indented block
                _ = try self.consume(arena, .newline);
                try line.writer.print("", .{});
            },
            .text => { // blank line doesn't end indented block
                if (strings.isBlankLine(line_start.lexeme)) {
                    // https://spec.commonmark.org/0.30/#example-111
                    _ = try self.consume(arena, .text);
                    try line.writer.print("", .{});
                    _ = try self.consume(arena, .newline);
                } else {
                    break;
                }
            },
            else => break,
        }

        try lines.append(arena, line.written());
    } else @panic(safety.loop_bound_panic_msg);

    if (lines.items.len == 0) {
        return null;
    }

    // Skip leading and trailing blank lines
    const start_index = blk: {
        for (lines.items, 0..) |line, i| {
            if (line.len > 0 and !strings.containsOnly(line, "\n")) {
                break :blk i;
            }
        }
        break :blk lines.items.len;
    };
    const end_index = blk: {
        var i = lines.items.len;
        while (i > 0) {
            i -= 1;
            const line = lines.items[i];
            if (line.len > 0 and !strings.containsOnly(line, "\n")) {
                break :blk i + 1;
            }
        }
        break :blk 0;
    };

    const buf = try std.mem.join(
        arena,
        "\n",
        lines.items[start_index..end_index],
    );
    const node = try gpa.create(ast.Node);
    node.* = .{
        .code = .{
            .value = try gpa.dupe(u8, buf),
            .lang = "",
        },
    };
    return node;
}

fn parseParagraph(self: *Self, gpa: Allocator, arena: Allocator) !?*ast.Node {
    var lines: ArrayList([]const u8) = .empty;

    for (0..safety.loop_bound) |_| {
        var line = Io.Writer.Allocating.init(arena);

        {
            const start = try self.parseTextStart(gpa, arena) orelse break;
            defer start.deinit(gpa);
            try line.writer.print("{s}", .{start.text.value});
        }

        for (0..safety.loop_bound) |_| {
            const next = try self.parseText(gpa, arena) orelse break;
            defer next.deinit(gpa);
            try line.writer.print("{s}", .{next.text.value});
        } else @panic(safety.loop_bound_panic_msg);

        try lines.append(arena, line.written());
        _ = try self.consume(arena, .newline);
    } else @panic(safety.loop_bound_panic_msg);

    if (lines.items.len == 0) {
        return null;
    }

    // Join lines by putting a newline between them
    const buf = try std.mem.join(arena, "\n", lines.items);
    const text_node = try createTextNode(gpa, buf);

    const node = try gpa.create(ast.Node);
    node.* = .{
        .paragraph = .{
            .children = try gpa.dupe(*ast.Node, &.{ text_node }),
        },
    };
    return node;
}

/// Parse text potentially starting later in a line.
fn parseText(self: *Self, gpa: Allocator, arena: Allocator) !?*ast.Node {
    const token = try self.peek(arena) orelse return null;
    switch (token.token_type) {
        .text, .pound, .rule_equals, .rule_dash => |t| {
            _ = try self.consume(arena, t);
            return createTextNode(gpa, token.lexeme);
        },
        else => return null,
    }
}

/// Parse text starting from the beginning of a line.
fn parseTextStart(self: *Self, gpa: Allocator, arena: Allocator) !?*ast.Node {
    const token = try self.peek(arena) orelse return null;
    switch (token.token_type) {
        .pound => {
            if (token.lexeme.len > 6) {
                return try self.parseText(gpa, arena);
            } else {
                return null;
            }
        },
        .indent => {
            // If we're already parsing a paragraph, leading indents are okay.
            // https://spec.commonmark.org/0.30/#example-113
            _ = try self.consume(arena, .indent);
            return try self.parseText(gpa, arena);
        },
        .text, .rule_equals, .rule_dash => {
            return try self.parseText(gpa, arena);
        },
        else => return null,
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

fn peek(self: *Self, arena: Allocator) !?BlockToken {
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
    token_type: BlockTokenType,
) !?BlockToken {
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

fn clear_line(self: *Self, arena: Allocator) !void {
    std.debug.assert(self.line.items.len > 0);

    const current = try self.peek(arena);
    self.token_index = 0;
    self.line.clearRetainingCapacity();

    if (current) |c| {
        try self.line.append(arena, c);
    }
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;
const LineReader = @import("../lex/LineReader.zig");

test "ATX heading and paragraphs" {
    const md =
        \\# This is a heading
        \\This is paragraph one. It goes on for
        \\multiple lines.
        \\
        \\This is paragraph two.
        \\
        \\
        \\This is paragraph three.
        \\
    ;

    var reader: Io.Reader = .fixed(md);
    var line_buf: [512]u8 = undefined;
    const line_reader: LineReader = .{ .in = &reader, .buf = &line_buf };
    var tokenizer = BlockTokenizer.init(line_reader);
    var parser = Self.init(&tokenizer);

    const root = try parser.parse(std.testing.allocator);
    defer root.deinit(std.testing.allocator);

    try std.testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try std.testing.expectEqual(4, root.root.children.len);

    const heading = root.root.children[0];
    try std.testing.expectEqual(.heading, @as(ast.NodeType, heading.*));

    const p1 = root.root.children[1];
    try std.testing.expectEqual(.paragraph, @as(ast.NodeType, p1.*));

    const p2 = root.root.children[2];
    try std.testing.expectEqual(.paragraph, @as(ast.NodeType, p2.*));

    const p3 = root.root.children[3];
    try std.testing.expectEqual(.paragraph, @as(ast.NodeType, p3.*));
}

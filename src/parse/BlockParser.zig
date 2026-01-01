//! Parser for the first parsing stage that handles block-level parsing.
//!
//! Parser pulls tokens from the tokenizer as needed. The tokens are stored in
//! an array list. The array list is cleared as each block is successfully
//! parsed.

const std = @import("std");
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const ArrayList = std.ArrayList;

const ast = @import("ast.zig");
const BlockTokenizer = @import("../lex/BlockTokenizer.zig");
const BlockToken = @import("../lex/tokens.zig").BlockToken;
const BlockTokenType = @import("../lex/tokens.zig").BlockTokenType;
const safety = @import("../util/safety.zig");
const strings = @import("../util/strings.zig");

const Error = error{
    UnrecognizedBlockToken, // TODO: Remove
};

tokenizer: *BlockTokenizer,
tokens: ArrayList(BlockToken),
token_index: usize,

const Self = @This();

pub fn init(tokenizer: *BlockTokenizer) Self {
    return .{
        .tokenizer = tokenizer,
        .tokens = .empty,
        .token_index = 0,
    };
}

/// Parse block nodes from the token stream.
///
/// Returns the root node of the resulting AST. The AST may contain blocks of
/// unparsed inline text.
///
/// Caller owns the returned AST.
pub fn parse(self: *Self, perm: Allocator) !*ast.Node {
    // Arena used for tokenization / scratch
    var arena = std.heap.ArenaAllocator.init(perm);
    defer arena.deinit();
    const scratch = arena.allocator();

    var children: ArrayList(*ast.Node) = .empty;
    errdefer {
        for (children.items) |child| {
            child.deinit(perm);
        }
        children.deinit(perm);
    }

    for (0..safety.loop_bound) |_| { // could hit if we forget to consume tokens
        _ = try self.peek(scratch) orelse break;

        const maybe_next = blk: {
            if (try self.parseIndentedCode(perm, scratch)) |indent_code| {
                break :blk indent_code;
            }

            if (try self.parseATXHeading(perm, scratch)) |heading| {
                break :blk heading;
            }

            if (try self.parseThematicBreak(perm, scratch)) |thematic_break| {
                break :blk thematic_break;
            }

            if (try self.parseParagraph(perm, scratch)) |paragraph| {
                break :blk paragraph;
            }

            break :blk null;
        };
        if (maybe_next) |next| {
            try children.append(perm, next);
            try self.clear_parsed_tokens();
            continue;
        }

        // blank lines
        if (try self.consume(scratch, .newline) != null) {
            continue;
        }

        @panic("unable to parse block token");
    } else @panic(safety.loop_bound_panic_msg);

    const node = try perm.create(ast.Node);
    node.* = .{
        .root = .{
            .children = try children.toOwnedSlice(perm),
        },
    };
    return node;
}

fn parseATXHeading(self: *Self, perm: Allocator, scratch: Allocator) !?*ast.Node {
    const start_token = try self.peek(scratch) orelse return null;
    if (start_token.token_type != .pound) {
        return null;
    }

    const depth = start_token.lexeme.len;
    if (depth > 6) { // https://spec.commonmark.org/0.31.2/#example-63
        return null;
    }

    _ = try self.consume(scratch, .pound);

    var buf = Io.Writer.Allocating.init(scratch);
    for (0..safety.loop_bound) |_| {
        const current = try self.peek(scratch) orelse break;
        if (current.token_type == .pound) {
            // Look ahead for a newline. If there is one, this is a closing
            // sequence of #.
            const checkpoint_index = self.checkpoint();
            _ = try self.consume(scratch, .pound);
            if (try self.peek(scratch)) |t| {
                if (t.token_type == .newline) {
                    break;
                }
            }

            // Okay, not a closing sequence.
            self.backtrack(checkpoint_index);
        }

        const node = try self.parseText(perm, scratch) orelse break;
        try buf.writer.print("{s}", .{node.text.value});
        node.deinit(perm);
    } else @panic(safety.loop_bound_panic_msg);

    _ = try self.consume(scratch, .newline);

    var children: []const *ast.Node = &.{};
    const inner_value = std.mem.trim(u8, buf.written(), " \t");
    if (inner_value.len > 0) {
        const text_node = try createTextNode(perm, inner_value);
        children = &.{ text_node };
    }

    const node = try perm.create(ast.Node);
    node.* = .{
        .heading = .{
            .depth = @truncate(depth),
            .children = try perm.dupe(*ast.Node, children),
        },
    };
    return node;
}

fn parseThematicBreak(
    self: *Self,
    perm: Allocator,
    scratch: Allocator,
) !?*ast.Node {
    const token = try self.peek(scratch) orelse return null;
    switch (token.token_type) {
        .rule_star, .rule_underline, .rule_dash_with_whitespace => |t| {
            _ = try self.consume(scratch, t);
        },
        .rule_dash => |t| {
            if (token.lexeme.len < 3) {
                return null;
            }

            _ = try self.consume(scratch, t);
        },
        else => return null,
    }

    _ = try self.consume(scratch, .newline);

    const node = try perm.create(ast.Node);
    node.* = .{ .thematic_break = .{} };
    return node;
}

fn parseIndentedCode(
    self: *Self,
    perm: Allocator,
    scratch: Allocator,
) !?*ast.Node {
    // Has to start with an indent
    const initial = try self.peek(scratch) orelse return null;
    if (initial.token_type != .indent) {
        return null;
    }

    // Parse one or more indented lines
    var lines: ArrayList([]const u8) = .empty;
    for (0..safety.loop_bound) |_| {
        const line_start = try self.peek(scratch) orelse break;

        var line = Io.Writer.Allocating.init(scratch);
        switch (line_start.token_type) {
            .indent => {
                // Parse a single indented line
                _ = try self.consume(scratch, .indent);
                while (try self.peek(scratch)) |next| {
                    if (next.token_type == .newline) {
                        break;
                    }

                    _ = try self.consume(scratch, next.token_type);
                    try line.writer.print("{s}", .{next.lexeme});
                } else @panic(safety.loop_bound_panic_msg);

                _ = try self.consume(scratch, .newline);
            },
            .newline => { // newline doesn't end indented block
                _ = try self.consume(scratch, .newline);
                try line.writer.print("", .{});
            },
            .text => { // blank line doesn't end indented block
                if (strings.isBlankLine(line_start.lexeme)) {
                    // https://spec.commonmark.org/0.30/#example-111
                    _ = try self.consume(scratch, .text);
                    try line.writer.print("", .{});
                    _ = try self.consume(scratch, .newline);
                } else {
                    break;
                }
            },
            else => break,
        }

        try lines.append(scratch, line.written());
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
        scratch,
        "\n",
        lines.items[start_index..end_index],
    );
    const node = try perm.create(ast.Node);
    node.* = .{
        .code = .{
            .value = try perm.dupe(u8, buf),
            .lang = "",
        },
    };
    return node;
}

fn parseParagraph(self: *Self, perm: Allocator, scratch: Allocator) !?*ast.Node {
    var lines: ArrayList([]const u8) = .empty;

    for (0..safety.loop_bound) |_| {
        var line = Io.Writer.Allocating.init(scratch);

        {
            const start = try self.parseTextStart(perm, scratch) orelse break;
            defer start.deinit(perm);
            try line.writer.print("{s}", .{start.text.value});
        }

        for (0..safety.loop_bound) |_| {
            const next = try self.parseText(perm, scratch) orelse break;
            defer next.deinit(perm);
            try line.writer.print("{s}", .{next.text.value});
        } else @panic(safety.loop_bound_panic_msg);

        try lines.append(scratch, line.written());
        _ = try self.consume(scratch, .newline);
    } else @panic(safety.loop_bound_panic_msg);

    if (lines.items.len == 0) {
        return null;
    }

    // Join lines by putting a newline between them
    const buf = try std.mem.join(scratch, "\n", lines.items);
    const text_node = try createTextNode(perm, buf);

    const node = try perm.create(ast.Node);
    node.* = .{
        .paragraph = .{
            .children = try perm.dupe(*ast.Node, &.{ text_node }),
        },
    };
    return node;
}

/// Parse text potentially starting later in a line.
fn parseText(self: *Self, perm: Allocator, scratch: Allocator) !?*ast.Node {
    const token = try self.peek(scratch) orelse return null;
    switch (token.token_type) {
        .text, .pound, .rule_equals, .rule_dash => |t| {
            _ = try self.consume(scratch, t);
            return createTextNode(perm, token.lexeme);
        },
        else => return null,
    }
}

/// Parse text starting from the beginning of a line.
fn parseTextStart(self: *Self, perm: Allocator, scratch: Allocator) !?*ast.Node {
    const token = try self.peek(scratch) orelse return null;
    switch (token.token_type) {
        .pound => {
            if (token.lexeme.len > 6) {
                return try self.parseText(perm, scratch);
            } else {
                return null;
            }
        },
        .indent => {
            // If we're already parsing a paragraph, leading indents are okay.
            // https://spec.commonmark.org/0.30/#example-113
            _ = try self.consume(scratch, .indent);
            return try self.parseText(perm, scratch);
        },
        .text, .rule_equals, .rule_dash => {
            return try self.parseText(perm, scratch);
        },
        else => return null,
    }
}

fn createTextNode(perm: Allocator, value: []const u8) !*ast.Node {
    const node = try perm.create(ast.Node);
    node.* = .{
        .text = .{
            .value = try perm.dupe(u8, value),
        },
    };
    return node;
}

fn peek(self: *Self, scratch: Allocator) !?BlockToken {
    if (self.token_index >= self.tokens.items.len) {
        const next = try self.tokenizer.next(scratch);
        if (next == null) {
            return null; // end of input
        }

        try self.tokens.append(scratch, next.?);
    }

    return self.tokens.items[self.token_index];
}

fn consume(
    self: *Self,
    scratch: Allocator,
    token_type: BlockTokenType,
) !?BlockToken {
    const current = try self.peek(scratch) orelse return null;
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

fn clear_parsed_tokens(self: *Self) !void {
    std.debug.assert(self.tokens.items.len > 0);

    // Copy unparsed tokens to beginning of list
    const unparsed = self.tokens.items[self.token_index..];
    self.tokens.replaceRangeAssumeCapacity(0, self.tokens.items.len, unparsed);
    self.token_index = 0;
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

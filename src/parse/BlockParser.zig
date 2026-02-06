//! Parser for the first parsing stage that handles block-level parsing.
//!
//! Parser pulls tokens from the tokenizer as needed. The tokens are stored in
//! an array list. The array list is cleared of consumed tokens as each block is
//! successfully parsed.
//!
//! This is a recursive-descent parser with backtracking.

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
const cmark = @import("../cmark/cmark.zig");
const escape = @import("escape.zig");
const LinkDefMap = @import("link_defs.zig").LinkDefMap;
const link_label_max_chars = @import("link_defs.zig").label_max_chars;
const util = @import("../util/util.zig");

const Error = error{
    LineTooLong,
    ReadFailed,
    WriteFailed,
} || Allocator.Error;

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
pub fn parse(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!struct { *ast.Node, LinkDefMap } {
    var children: ArrayList(*ast.Node) = .empty;
    errdefer {
        for (children.items) |child| {
            child.deinit(alloc);
        }
        children.deinit(alloc);
    }

    var link_defs: LinkDefMap = .empty;
    errdefer link_defs.deinit(alloc);

    for (0..util.safety.loop_bound) |_| { // could hit if we forget to consume tokens
        _ = try self.peek(scratch) orelse break;

        if (blk: {
            if (try self.parseIndentedCode(alloc, scratch)) |indent_code| {
                break :blk indent_code;
            }

            if (try self.parseATXHeading(alloc, scratch)) |heading| {
                break :blk heading;
            }

            if (try self.parseThematicBreak(alloc, scratch)) |thematic_break| {
                break :blk thematic_break;
            }

            if (
                try self.parseLinkReferenceDefinition(alloc, scratch)
            ) |link_def| {
                try link_defs.add(alloc, &link_def.definition);
                break :blk link_def;
            }

            if (try self.parseParagraph(alloc, scratch)) |paragraph| {
                break :blk paragraph;
            }

            break :blk null;
        }) |next| {
            try children.append(alloc, next);
            self.clear_consumed_tokens();
            continue;
        }

        // blank lines
        if (try self.consume(scratch, &.{.newline}) != null) {
            continue;
        }

        @panic("unable to parse block token");
    } else @panic(util.safety.loop_bound_panic_msg);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .root = .{
            .children = try children.toOwnedSlice(alloc),
        },
    };
    return .{ node, link_defs };
}

// @     => pound inner? end?
// inner => text*
// end   => pound newline | newline
fn parseATXHeading(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    // Handle allowed leading whitespace
    _ = try self.consume(scratch, &.{.whitespace});

    // Just peek, don't consume until we know the depth is valid
    const start_token = try self.peek(scratch) orelse return null;
    if (start_token.token_type != .pound) {
        return null;
    }

    const depth = start_token.lexeme.len;
    if (depth > 6) { // https://spec.commonmark.org/0.31.2/#example-63
        return null;
    }

    // Okay, now consume
    _ = try self.consume(scratch, &.{.pound});

    var inner = Io.Writer.Allocating.init(scratch);
    for (0..util.safety.loop_bound) |_| {
        const current = try self.peek(scratch) orelse break;
        switch (current.token_type) {
            .pound => {
                _ = try self.consume(scratch, &.{.pound});

                // Look ahead for a newline. If there is one, this is a closing
                // sequence of # and we've reached the end of the line.
                // Otherwise, parse the pound token as inner text.
                const lookahead_checkpoint_index = self.checkpoint();
                while (try self.consume(scratch, &.{.whitespace})) |_| {}
                if (try self.peek(scratch)) |last| {
                    if (last.token_type != .newline) {
                        // Was not trailing pound, write it
                        try inner.writer.print("{s}", .{current.lexeme});
                        self.backtrack(lookahead_checkpoint_index);
                    }
                }
            },
            .newline => break,
            else => {
                const text = try self.scanText(scratch) orelse break;
                try inner.writer.print("{s}", .{text});
            }
        }
    } else @panic(util.safety.loop_bound_panic_msg);

    _ = try self.consume(scratch, &.{.newline}) orelse return null;

    const children: []*ast.Node = blk: {
        const trimmed_inner = std.mem.trim(u8, inner.written(), " \t");
        if (trimmed_inner.len == 0) {
            break :blk &.{};
        }
        const text_node = try createTextNode(alloc, trimmed_inner);
        break :blk try alloc.dupe(*ast.Node, &.{ text_node });
    };
    errdefer alloc.free(children);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .heading = .{
            .depth = @truncate(depth),
            .children = children,
        },
    };
    did_parse = true;
    return node;
}

fn parseThematicBreak(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !?*ast.Node {
    const token = try self.peek(scratch) orelse return null;
    switch (token.token_type) {
        .rule_star, .rule_underline, .rule_dash_with_whitespace => |t| {
            _ = try self.consume(scratch, &.{t});
        },
        .rule_dash => |t| {
            if (token.lexeme.len < 3) {
                return null;
            }

            _ = try self.consume(scratch, &.{t});
        },
        else => return null,
    }

    _ = try self.consume(scratch, &.{.newline});

    const node = try alloc.create(ast.Node);
    node.* = .{ .thematic_break = .{} };
    return node;
}

fn parseIndentedCode(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !?*ast.Node {
    // Block has to start with an indent.
    // Consume token later; this is just a check for an easy bail condition.
    const block_start = try self.peek(scratch) orelse return null;
    if (block_start.token_type != .indent) {
        return null;
    }

    // Parse one or more indented lines
    var lines: ArrayList([]const u8) = .empty;
    block_loop: for (0..util.safety.loop_bound) |_| {
        var line = Io.Writer.Allocating.init(scratch);

        const line_start = try self.peek(scratch) orelse break :block_loop;
        switch (line_start.token_type) {
            .indent => {
                // Parse a single indented line
                _ = try self.consume(scratch, &.{.indent});
                line_loop: while (try self.peek(scratch)) |next| {
                    if (next.token_type == .newline) {
                        break :line_loop;
                    }

                    _ = try self.consume(scratch, &.{next.token_type});
                    try line.writer.print("{s}", .{next.lexeme});
                }

                _ = try self.consume(scratch, &.{.newline});
            },
            .newline => { // newline doesn't end indented block
                _ = try self.consume(scratch, &.{.newline});
                try line.writer.print("", .{});
            },
            .whitespace => {
                const lookahead_checkpoint_index = self.checkpoint();
                while (try self.consume(scratch, &.{.whitespace})) |_| {}
                if (try self.peek(scratch)) |token| {
                    if (token.token_type == .newline) {
                        _ = try self.consume(scratch, &.{.newline});
                        try line.writer.print("", .{});
                    } else {
                        // Unindented, non-blank line does end block
                        self.backtrack(lookahead_checkpoint_index);
                        break :block_loop;
                    }
                }
            },
            else => break :block_loop,
        }

        try lines.append(scratch, line.written());
    } else @panic(util.safety.loop_bound_panic_msg);

    if (lines.items.len == 0) {
        return null;
    }

    // Skip leading and trailing blank lines
    const start_index = for (lines.items, 0..) |line, i| {
        if (line.len > 0 and !util.strings.containsOnly(line, "\n")) {
            break i;
        }
    } else lines.items.len;
    const end_index = blk: {
        var i = lines.items.len;
        while (i > 0) {
            i -= 1;
            const line = lines.items[i];
            if (line.len > 0 and !util.strings.containsOnly(line, "\n")) {
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
    const node = try alloc.create(ast.Node);
    node.* = .{
        .code = .{
            .value = try alloc.dupe(u8, buf),
            .lang = "",
        },
    };
    return node;
}

/// https://spec.commonmark.org/0.30/#link-reference-definition
fn parseLinkReferenceDefinition(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    // consume allowed leading whitespace
    _ = try self.consume(scratch, &.{.whitespace});

    const scanned_label = try self.scanLinkDefLabel(scratch) orelse return null;
    _ = try self.consume(scratch, &.{.colon}) orelse return null;

    // whitespace allowed and up to one newline
    var seen_newline = false;
    while (try self.consume(scratch, &.{
        .newline,
        .whitespace,
        .indent,
    })) |token| {
        if (token.token_type == .newline) {
            if (seen_newline) {
                return null;
            }
            seen_newline = true;
        }
    }

    const scanned_url = try self.scanLinkDefDestination(
        scratch,
    ) orelse return null;
    const url = try cmark.uri.normalize(alloc, scratch, scanned_url);
    errdefer alloc.free(url);

    // whitespace allowed and up to one newline
    var seen_any_separating_whitespace = false;
    seen_newline = false;
    while (try self.peek(scratch)) |token| {
        switch (token.token_type) {
            .indent, .whitespace => |t| {
                seen_any_separating_whitespace = true;
                _ = try self.consume(scratch, &.{t});
            },
            .newline => {
                seen_any_separating_whitespace = true;
                if (seen_newline) {
                    break;
                } else {
                    seen_newline = true;
                    _ = try self.consume(scratch, &.{.newline});
                }
            },
            else => break,
        }
    }

    const scanned_title = blk: {
        // link title, if present, must be separated from destination by
        // whitespace
        if (seen_any_separating_whitespace) {
            break :blk try self.scanLinkDefTitle(scratch) orelse "";
        }
        break :blk "";
    };

    // "no further character can occur" says the spec, but then there's an example
    // of spaces following the title, so we optionally consume whitespace here
    _ = try self.consume(scratch, &.{.whitespace});
    _ = try self.consume(scratch, &.{.newline}) orelse return null;

    const label = try alloc.dupe(u8, scanned_label);
    errdefer alloc.free(label);
    const title = try alloc.dupe(u8, scanned_title);
    errdefer alloc.free(title);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .definition = .{
            .url = url,
            .label = label,
            .title = title,
        },
    };
    did_parse = true;
    return node;
}

/// https://spec.commonmark.org/0.30/#link-label
fn scanLinkDefLabel(self: *Self, scratch: Allocator) !?[]const u8 {
    var did_parse = false;
    var running_text = Io.Writer.Allocating.init(scratch);
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    _ = try self.consume(
        scratch,
        &.{.l_square_bracket},
    ) orelse return null;

    var saw_non_blank = false;
    while (try self.peek(scratch)) |token| {
        switch (token.token_type) {
            .whitespace => {
                _ = try self.consume(scratch, &.{.whitespace});
                _ = try running_text.writer.write(token.lexeme);
            },
            .newline => {
                _ = try self.consume(scratch, &.{.newline});
                _ = try running_text.writer.write(" ");
            },
            .l_square_bracket => return null,
            .r_square_bracket => break,
            .text => {
                saw_non_blank = true;
                _ = try self.consume(scratch, &.{.text});
                const value = try escape.copyEscape(scratch, token.lexeme);
                _ = try running_text.writer.write(value);
            },
            else => |t| {
                saw_non_blank = true;
                _ = try self.consume(scratch, &.{t});
                _ = try running_text.writer.write(token.lexeme);
            },
        }
    }

    _ = try self.consume(
        scratch,
        &.{.r_square_bracket},
    ) orelse return null;

    // TODO: Technically this should be the length in unicode code points, not
    // bytes.
    if (running_text.written().len > link_label_max_chars) {
        return null;
    }
    did_parse = true;
    return try running_text.toOwnedSlice();
}

fn scanLinkDefDestination(self: *Self, scratch: Allocator) !?[]const u8 {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    var running_text = Io.Writer.Allocating.init(scratch);
    if (try self.consume(scratch, &.{.l_angle_bracket})) |_| {
        // Option one, angle bracket delimited, empty string allowed
        while (try self.peek(scratch)) |token| {
            switch (token.token_type) {
                .l_angle_bracket, .newline => return null,
                .r_angle_bracket => break,
                // None of these tokens should really be possible here, since
                // they can only be matched at the beginning of a line.
                .indent, .rule_star, .rule_underline, .rule_dash_with_whitespace,
                .rule_dash, .rule_equals => return null,
                .text, .pound, .whitespace, .colon, .l_square_bracket,
                .r_square_bracket, .l_paren, .r_paren, .double_quote,
                .single_quote => |t| {
                    _ = try self.consume(scratch, &.{t});
                    _ = try running_text.writer.write(token.lexeme);
                },
            }
        }
        _ = try self.consume(scratch, &.{.r_angle_bracket});
    } else {
        // Option two
        // - non-zero length
        // - no ascii control chars
        // - no spaces
        // - balanced parens
        var paren_depth: u32 = 0;
        while (try self.peek(scratch)) |token| {
            switch (token.token_type) {
                .l_paren => {
                    paren_depth += 1;
                    _ = try self.consume(scratch, &.{.l_paren});
                    _ = try running_text.writer.write(token.lexeme);
                },
                .r_paren => {
                    if (paren_depth == 0) {
                        break;
                    }

                    paren_depth -= 1;
                    _ = try self.consume(scratch, &.{.r_paren});
                    _ = try running_text.writer.write(token.lexeme);
                },
                .newline, .whitespace => break,
                .indent, .rule_star, .rule_underline, .rule_dash_with_whitespace,
                .rule_dash, .rule_equals => return null,
                .text, .pound, .colon, .l_square_bracket, .r_square_bracket,
                .l_angle_bracket, .r_angle_bracket, .double_quote,
                .single_quote => |t| {
                    _ = try self.consume(scratch, &.{t});
                    const value = token.lexeme;
                    if (util.strings.containsAsciiControl(value)) {
                        return null;
                    }
                    _ = try running_text.writer.write(value);
                },
            }
        }

        if (paren_depth > 0) {
            return null;
        }

        if (running_text.written().len == 0) {
            return null;
        }
    }

    did_parse = true;
    return try running_text.toOwnedSlice();
}

/// Title part of a link reference definition.
///
/// Should be enclosed in () or "" or ''. Can span multiple lines but cannot
/// contain a blank line.
fn scanLinkDefTitle(self: *Self, scratch: Allocator) !?[]const u8 {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    var running_text = Io.Writer.Allocating.init(scratch);

    const open = try self.consume(
        scratch,
        &.{.l_paren, .single_quote, .double_quote},
    ) orelse return "";

    const open_t = open.token_type;
    const close_t = if (open_t == .l_paren) .r_paren else open_t;

    var blank_line_so_far = false;
    while (try self.peek(scratch)) |token| {
        switch (token.token_type) {
            .newline => {
                if (blank_line_so_far) {
                    return null; // link title cannot contain blank line
                }
                _ = try self.consume(scratch, &.{.newline});
                _ = try running_text.writer.write("\n");

                blank_line_so_far = true;
            },
            .whitespace => {
                _ = try self.consume(scratch, &.{.whitespace});
                _ = try running_text.writer.write(token.lexeme);
            },
            else => |t| {
                if (t == close_t) {
                    break;
                }

                _ = try self.consume(scratch, &.{t});
                _ = try running_text.writer.write(token.lexeme);
                blank_line_so_far = false;
            },
        }
    }
    _ = try self.consume(scratch, &.{close_t}) orelse return null;

    did_parse = true;
    return try running_text.toOwnedSlice();
}

fn parseParagraph(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !?*ast.Node {
    var lines: ArrayList([]const u8) = .empty;

    for (0..util.safety.loop_bound) |_| {
        var line = Io.Writer.Allocating.init(scratch);

        const start_text = try self.scanTextStart(scratch) orelse break;
        try line.writer.print("{s}", .{start_text});

        for (0..util.safety.loop_bound) |_| {
            const next_text = try self.scanText(scratch) orelse break;
            try line.writer.print("{s}", .{next_text});
        } else @panic(util.safety.loop_bound_panic_msg);

        try lines.append(scratch, line.written());
        _ = try self.consume(scratch, &.{.newline});
    } else @panic(util.safety.loop_bound_panic_msg);

    if (lines.items.len == 0) {
        return null;
    }

    // Join lines by putting a newline between them
    const buf = try std.mem.join(scratch, "\n", lines.items);
    const text_node = try createTextNode(alloc, buf);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .paragraph = .{
            .children = try alloc.dupe(*ast.Node, &.{ text_node }),
        },
    };
    return node;
}

/// Consume text potentially starting later in a line.
fn scanText(self: *Self, scratch: Allocator) !?[]const u8 {
    const token = try self.consume(scratch, &.{
        .text,
        .whitespace,
        .pound,
        .rule_equals,
        .rule_dash,
        .single_quote,
        .double_quote,
        .colon,
        .l_square_bracket,
        .r_square_bracket,
        .l_angle_bracket,
        .r_angle_bracket,
        .l_paren,
        .r_paren,
    }) orelse return null;
    return token.lexeme;
}

/// Consume text starting from the beginning of a line.
fn scanTextStart(self: *Self, scratch: Allocator) !?[]const u8 {
    const token = try self.peek(scratch) orelse return null;
    switch (token.token_type) {
        .pound => {
            if (token.lexeme.len > 6) {
                return self.scanText(scratch);
            } else {
                return null;
            }
        },
        .indent => {
            // If we're already parsing a paragraph, leading indents are okay.
            // https://spec.commonmark.org/0.30/#example-113
            _ = try self.consume(scratch, &.{.indent});
            return try self.scanText(scratch);
        },
        .text, .rule_equals, .rule_dash, .single_quote, .double_quote, .colon,
        .l_square_bracket, .r_square_bracket, .l_angle_bracket,
        .r_angle_bracket, .l_paren, .r_paren, .whitespace => {
            return try self.scanText(scratch);
        },
        .newline, .rule_star, .rule_underline, .rule_dash_with_whitespace => {
            return null;
        },
    }
}

fn createTextNode(alloc: Allocator, value: []const u8) !*ast.Node {
    const node = try alloc.create(ast.Node);
    node.* = .{
        .text = .{
            .value = try alloc.dupe(u8, value),
        },
    };
    return node;
}

fn peek(self: *Self, scratch: Allocator) !?BlockToken {
    return self.peekAhead(scratch, 1);
}

/// Should be used for looking ahead a fixed amount only.
fn peekAhead(
    self: *Self,
    scratch: Allocator,
    comptime count: u16,
) !?BlockToken {
    const index = self.token_index + (count - 1);
    while (index >= self.tokens.items.len) {
        // Returning null here means end of token stream
        const next = try self.tokenizer.next(scratch) orelse return null;
        try self.tokens.append(scratch, next);
    }

    return self.tokens.items[index];
}

fn consume(
    self: *Self,
    scratch: Allocator,
    token_types: []const BlockTokenType,
) !?BlockToken {
    const current = try self.peek(scratch) orelse return null;
    for (token_types) |token_type| {
        if (current.token_type == token_type) {
            self.token_index += 1;
            return current;
        }
    }

    return null;
}

fn clear_consumed_tokens(self: *Self) void {
    std.debug.assert(self.tokens.items.len > 0);

    // Copy unconsumed tokens to beginning of list
    const unparsed = self.tokens.items[self.token_index..];
    self.tokens.replaceRangeAssumeCapacity(0, self.tokens.items.len, unparsed);
    self.token_index = 0;
}

fn checkpoint(self: *Self) usize {
    return self.token_index;
}

fn backtrack(self: *Self, checkpoint_index: usize) void {
    self.token_index = checkpoint_index;
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;
const LineReader = @import("../lex/LineReader.zig");

fn parseBlocks(md: []const u8) !struct{*ast.Node, LinkDefMap} {
    var reader: Io.Reader = .fixed(md);
    var line_buf: [512]u8 = undefined;
    const line_reader: LineReader = .{ .in = &reader, .buf = &line_buf };
    var tokenizer = BlockTokenizer.init(line_reader);
    var parser = Self.init(&tokenizer);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const root, const link_defs = try parser.parse(testing.allocator, scratch);
    return .{ root, link_defs };
}

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

    const root, var link_defs = try parseBlocks(md);
    defer root.deinit(testing.allocator);
    defer link_defs.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try testing.expectEqual(4, root.root.children.len);

    const heading = root.root.children[0];
    try testing.expectEqual(.heading, @as(ast.NodeType, heading.*));

    const p1 = root.root.children[1];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p1.*));

    const p2 = root.root.children[2];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p2.*));

    const p3 = root.root.children[3];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p3.*));
}

test "ATX heading with leading whitespace" {
    const md =
        \\ ### foo
        \\   # foo
        \\
    ;

    const root, var link_defs = try parseBlocks(md);
    defer root.deinit(testing.allocator);
    defer link_defs.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try testing.expectEqual(2, root.root.children.len);

    const h1 = root.root.children[0];
    try testing.expectEqual(.heading, @as(ast.NodeType, h1.*));

    const h2 = root.root.children[0];
    try testing.expectEqual(.heading, @as(ast.NodeType, h2.*));
}

test "ATX heading with trailing pounds" {
    const md = "## foo ##    \n";

    const root, var link_defs = try parseBlocks(md);
    defer root.deinit(testing.allocator);
    defer link_defs.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try testing.expectEqual(1, root.root.children.len);

    const h1 = root.root.children[0];
    try testing.expectEqual(.heading, @as(ast.NodeType, h1.*));
}

test "paragraph can contain punctuation" {
    const md =
        \\# Heading containing "symbols" ([]<>)
        \\This is a "paragraph" that contains punctuation! (We don't want any
        \\of these symbols, like [, ], <, or >, to break the paragraph.)
        \\
    ;

    const root, var link_defs = try parseBlocks(md);
    defer root.deinit(testing.allocator);
    defer link_defs.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try testing.expectEqual(2, root.root.children.len);

    const h = root.root.children[0];
    try testing.expectEqual(.heading, @as(ast.NodeType, h.*));
    try testing.expectEqual(1, h.heading.children.len);

    const p = root.root.children[1];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));
}

test "link reference definition" {
    const md =
        \\[checkout this cool link][foo]
        \\
        \\[foo]: /bar "baz bot"
        \\
    ;

    const root, var link_defs = try parseBlocks(md);
    defer root.deinit(testing.allocator);
    defer link_defs.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));

    // The link definition is added to the AST (even though it isn't rendered),
    // which is why we have two nodes.
    try testing.expectEqual(2, root.root.children.len);

    // Link should get parsed as a paragraph by the block parser; the inline
    // parser will later turn it into a link.
    const p = root.root.children[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));

    try testing.expectEqual(1, link_defs.count());

    const maybe_definition = try link_defs.get(testing.allocator, "foo");
    const definition = try util.testing.expectNonNull(maybe_definition);
    try testing.expectEqualStrings("foo", definition.label);
    try testing.expectEqualStrings("/bar", definition.url);
    try testing.expectEqualStrings("baz bot", definition.title);
}

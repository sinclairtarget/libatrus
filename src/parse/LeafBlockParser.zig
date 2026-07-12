//! Parser in the first parsing stage that handles leaf blocks.
//!
//! This is a recursive-descent parser with backtracking.
//!
//! Parser pulls tokens from the iterator as needed. The tokens are stored in
//! an array list. The array list is cleared of consumed tokens as each block
//! is successfully parsed.
//!
//! Ideally, this parser wouldn't have to be aware of container blocks in any
//! way. But until we find a better factorization we include some functionality
//! here required only by the container block parser.
//!
//! In addition to the regular block tokens, this parser can also handle
//! special "CLOSE" tokens. A CLOSE token indicates that the parser should not
//! parse any more blocks. This is similar to but different from the actual end
//! of the token stream: whereas the end of the stream obviously means that the
//! parser can't parse anything more, the CLOSE token allows the parser to keep
//! parsing an open paragraph but nothing else. (CLOSE tokens are used to
//! implement lazy continuation lines for blockquotes.)
//!
//! This parser also sets a flag when it is parsing something that cannot be
//! interrupted by the start of a new container. This flag lets the container
//! block parser know that ">" tokens, for example, cannot begin a blockquote
//! in the current context.

const std = @import("std");
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const ArrayList = std.ArrayList;

const ast = @import("../ast.zig");
const BlockToken = @import("../lex/tokens.zig").BlockToken;
const BlockTokenType = @import("../lex/tokens.zig").BlockTokenType;
const whitespaceLen = @import("../lex/tokens.zig").whitespaceLen;
const cmark = @import("../cmark/cmark.zig");
const escape = @import("escape.zig");
const LinkDefMap = @import("link_defs.zig").LinkDefMap;
const link_label_max_chars = @import("link_defs.zig").label_max_chars;
const NodeList = @import("NodeList.zig");
const myst = @import("../myst/myst.zig");
const TokenIterator = @import("../lex/iterator.zig").TokenIterator;
const util = @import("../util/util.zig");

const Error = error{
    LineTooLong,
    ReadFailed,
    WriteFailed,
} || Allocator.Error;

const close_token_panic_msg = "encountered unexpected CLOSE token";

it: *TokenIterator(BlockTokenType),
/// Whether a new container block can open now.
///
/// Set this to false when parsing something (like a code block) where all
/// tokens must be consumed by the current leaf block parser.
interruptible: bool = true,

const Self = @This();

/// Parse block nodes from the token stream.
///
/// Returns a list of block nodes. The list may contain blocks containing
/// unparsed inline text.
///
/// Caller owns the returned nodes.
pub fn parse(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
    link_defs: *LinkDefMap,
) Error![]*ast.Node {
    var children = NodeList.init(alloc, scratch, createParagraphNode);
    errdefer {
        for (children.items()) |child| {
            child.deinit(alloc);
        }
        children.deinit();
    }

    for (0..util.safety.loop_bound) |_| {
        self.it.clearConsumed();

        const next = try self.it.peek(scratch) orelse break;
        if (next.token_type == .close) {
            _ = try self.it.consume(scratch, &.{.close});
            break; // end of parsing in response to CLOSE token
        }

        {
            const result = try self.parseIndentedCode(alloc, scratch);
            if (result.maybe_node) |code| {
                try children.append(code);
                if (result.should_end) {
                    break;
                } else {
                    continue;
                }
            }
        }

        {
            const result = try self.parseMySTDirective(alloc, scratch);
            if (result.maybe_node) |directive| {
                try children.append(directive);
                if (result.should_end) {
                    break;
                } else {
                    continue;
                }
            }
        }

        {
            const result = try self.parseFencedCode(alloc, scratch);
            if (result.maybe_node) |code| {
                try children.append(code);
                if (result.should_end) {
                    break;
                } else {
                    continue;
                }
            }
        }

        {
            const result = try self.parseHTML(alloc, scratch);
            if (result.maybe_node) |html| {
                try children.append(html);
                if (result.should_end) {
                    break;
                } else {
                    continue;
                }
            }
        }

        if (try self.parseATXHeading(alloc, scratch)) |heading| {
            try children.append(heading);
            continue;
        }

        if (try self.parseThematicBreak(alloc, scratch)) |thematic_break| {
            try children.append(thematic_break);
            continue;
        }

        if (try self.parseLinkReferenceDefinition(alloc, scratch)) |def| {
            try link_defs.add(alloc, &def.definition);
            try children.append(def);
            continue;
        }

        // blank lines
        if (try self.it.consume(scratch, &.{.newline}) != null) {
            try children.flush(); // Blank lines close paragraphs
            continue;
        }

        if (try self.parseSetextHeading(alloc, scratch)) |heading| {
            try children.append(heading);
            continue;
        }

        // Parse paragraph text
        const result = try self.scanParagraphText(scratch);
        if (result.maybe_text_value) |val| {
            try children.appendText(val);
            if (result.should_end) {
                break; // End parsing after lazy continuation lines
            } else {
                continue;
            }
        }

        // Parse paragraph text (last resort)
        const val = try self.scanTextFallback(scratch);
        if (val.len > 0) {
            try children.appendText(val);
            continue;
        }

        @panic("unable to parse block token");
    } else @panic(util.safety.loop_bound_panic_msg);

    return try children.toOwnedSlice();
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
    const checkpoint_index = self.it.checkpoint();
    defer {
        if (!did_parse) {
            self.it.backtrack(checkpoint_index);
        }
    }

    // Handle allowed leading whitespace
    _ = try self.it.consumeWhitespaceUpTo(scratch, 3);

    // Just peek, don't consume until we know the depth is valid
    const start_token = try self.it.peek(scratch) orelse return null;
    if (start_token.token_type != .pound) {
        return null;
    }

    const depth = start_token.lexeme.len;
    if (depth > 6) { // https://spec.commonmark.org/0.31.2/#example-63
        return null;
    }

    // Okay, now consume
    _ = try self.it.consume(scratch, &.{.pound});

    var inner = Io.Writer.Allocating.init(scratch);
    for (0..util.safety.loop_bound) |_| {
        const current = try self.it.peek(scratch) orelse break;
        switch (current.token_type) {
            .pound => {
                _ = try self.it.consume(scratch, &.{.pound});

                // Look ahead for a newline. If there is one, this is a closing
                // sequence of # and we've reached the end of the line.
                // Otherwise, parse the pound token as inner text.
                const lookahead_checkpoint_index = self.it.checkpoint();
                _ = try self.it.consumeWhitespace(scratch);
                if (try self.it.peek(scratch)) |last| {
                    if (last.token_type != .newline) {
                        // Was not trailing pound, write it
                        _ = try inner.writer.write(current.lexeme);
                        self.it.backtrack(lookahead_checkpoint_index);
                    }
                }
            },
            .newline => break,
            .close => @panic(close_token_panic_msg),
            else => {
                _ = try inner.writer.write(current.lexeme);
                _ = try self.it.consume(scratch, &.{current.token_type});
            },
        }
    } else @panic(util.safety.loop_bound_panic_msg);

    _ = try self.it.consume(scratch, &.{.newline}) orelse return null;

    const children: []*ast.Node = blk: {
        const trimmed_inner = std.mem.trim(u8, inner.written(), " \t");
        if (trimmed_inner.len == 0) {
            break :blk &.{};
        }
        const text_node = try util.nodes.createTextNode(alloc, trimmed_inner);
        break :blk try alloc.dupe(*ast.Node, &.{text_node});
    };
    errdefer alloc.free(children);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .heading = .{
            .children = children,
            .depth = @intCast(depth),
        },
    };
    did_parse = true;
    return node;
}

/// Parses a setext heading.
///
/// Will parse more than a setext heading if you let it... best to call this
/// last, with low precedence.
///
/// https://spec.commonmark.org/0.30/#setext-headings
fn parseSetextHeading(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.it.checkpoint();
    defer {
        if (!did_parse) {
            self.it.backtrack(checkpoint_index);
        }
    }

    var inner = Io.Writer.Allocating.init(scratch);

    const State = enum { open, maybe_close };
    fsm: switch (State.open) {
        .open => {
            const token = try self.it.peek(scratch) orelse break :fsm;
            switch (token.token_type) {
                .newline => {
                    _ = try self.it.consume(scratch, &.{.newline});
                    _ = try inner.writer.write("\n");
                    continue :fsm .maybe_close;
                },
                .close => return null,
                else => |t| {
                    _ = try self.it.consume(scratch, &.{t});
                    _ = try inner.writer.write(token.lexeme);
                    continue :fsm .open;
                },
            }
        },
        .maybe_close => {
            const token = try self.it.peek(scratch) orelse break :fsm;
            switch (token.token_type) {
                .newline,
                .pound,
                .rule_star,
                .rule_underline,
                .rule_dash_with_whitespace,
                .rule_dash,
                .rule_equals,
                .backtick_fence,
                .tilde_fence,
                => {
                    // These tokens can interrupt a paragraph. The text before
                    // the underline in a setext heading would otherwise be
                    // parsed as a paragraph.
                    break :fsm;
                },
                .close => return null,
                else => continue :fsm .open,
            }
        },
    }

    const depth: u8 = blk: {
        if (try self.it.consume(scratch, &.{.rule_equals})) |_| {
            break :blk 1;
        } else if (try self.it.consume(scratch, &.{.rule_dash})) |_| {
            break :blk 2;
        } else {
            return null;
        }
    };

    const children: []*ast.Node = blk: {
        const trimmed_inner = std.mem.trim(u8, inner.written(), " \t\n");
        if (trimmed_inner.len == 0) {
            break :blk &.{};
        }
        const text_node = try util.nodes.createTextNode(alloc, trimmed_inner);
        break :blk try alloc.dupe(*ast.Node, &.{text_node});
    };
    errdefer alloc.free(children);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .heading = .{
            .children = children,
            .depth = depth,
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
    var did_parse = false;

    const token = try self.it.peek(scratch) orelse return null;
    switch (token.token_type) {
        .rule_star, .rule_underline, .rule_dash_with_whitespace => |t| {
            _ = try self.it.consume(scratch, &.{t});
        },
        .rule_dash => |t| {
            if (token.lexeme.len < 3) {
                return null;
            }

            _ = try self.it.consume(scratch, &.{t});
        },
        else => return null,
    }

    _ = try self.it.consume(scratch, &.{.newline});

    const node = try alloc.create(ast.Node);
    node.* = .{ .thematic_break = {} };
    did_parse = true;
    return node;
}

/// Represents the result of parsing a node that can be ended by a CLOSE token.
/// E.g.: a fenced code block ends when its container closes and the leaf block
/// parser should end parsing since the container is now closed.
///
/// This should only ever be used by constructs that extend over more than one
/// line.
const EndingParseResult = struct {
    maybe_node: ?*ast.Node = null,
    should_end: bool = false,
};

fn parseIndentedCode(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !EndingParseResult {
    var did_parse = false;
    const checkpoint_index = self.it.checkpoint();
    defer if (!did_parse) {
        self.it.backtrack(checkpoint_index);
    };

    const fail: EndingParseResult = .{ .maybe_node = null };

    // Parse one or more indented lines
    var lines: ArrayList([]const u8) = .empty;
    block_loop: for (0..util.safety.loop_bound) |line_num| {
        var line = Io.Writer.Allocating.init(scratch);

        const indent_ws_tokens = try self.it.consumeWhitespaceUpTo(scratch, 4);
        const indent = whitespaceLen(indent_ws_tokens);
        if (indent >= 4) {
            line_loop: while (try self.it.peek(scratch)) |next| {
                if (next.token_type == .newline) {
                    break :line_loop;
                }

                _ = try self.it.consume(scratch, &.{next.token_type});
                try line.writer.print("{s}", .{next.lexeme});
            }

            _ = try self.it.consume(scratch, &.{.newline});
        } else if (line_num > 0 and indent > 0) {
            // Try to accept a blank line
            const lookahead_checkpoint_index = self.it.checkpoint();
            _ = try self.it.consumeWhitespace(scratch);
            _ = try self.it.consume(scratch, &.{.newline}) orelse {
                // Unindented, non-blank line does end block
                self.it.backtrack(lookahead_checkpoint_index);
                break :block_loop;
            };
        } else if (line_num > 0) {
            // Only valid thing is a newline
            _ = try self.it.consume(scratch, &.{.newline}) orelse {
                break :block_loop;
            };
        } else {
            // Invalid first line
            return fail;
        }

        try lines.append(scratch, line.written());
    } else @panic(util.safety.loop_bound_panic_msg);

    if (lines.items.len == 0) {
        return fail;
    }

    // Skip leading and trailing blank lines
    const start_index = for (lines.items, 0..) |line, i| {
        if (line.len > 0 and !util.strings.containsOnly(line, "\n")) {
            break i;
        }
    } else lines.items.len;
    const end_index = blk: {
        var i = lines.items.len;
        while (i > start_index) {
            i -= 1;
            const line = lines.items[i];
            if (line.len > 0 and !util.strings.containsOnly(line, "\n")) {
                break :blk i + 1;
            }
        }
        break :blk start_index;
    };

    const buf = try std.mem.join(
        scratch,
        "\n",
        lines.items[start_index..end_index],
    );
    const value = try alloc.dupeZ(u8, buf); // move to heap, sentinel-terminate
    errdefer alloc.free(value);

    const lang = try alloc.dupeZ(u8, "");
    errdefer alloc.free(lang);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .code = .{
            .value = value,
            .lang = lang,
        },
    };
    did_parse = true;
    return .{
        .maybe_node = node,
    };
}

/// https://spec.commonmark.org/0.30/#fenced-code-blocks
fn parseFencedCode(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !EndingParseResult {
    var did_parse = false;
    const checkpoint_index = self.it.checkpoint();
    defer if (!did_parse) {
        self.it.backtrack(checkpoint_index);
    };

    const fail: EndingParseResult = .{ .maybe_node = null };
    var saw_close_token = false;

    // Opening code fence line
    const ws_tokens = try self.it.consumeWhitespaceUpTo(scratch, 3);
    const indentation = whitespaceLen(ws_tokens);
    const open_fence = try self.it.consume(
        scratch,
        &.{ .backtick_fence, .tilde_fence },
    ) orelse return fail;

    const info_lang = blk: {
        // Whitespace allowed between fence and info string
        _ = try self.it.consumeWhitespace(scratch);

        // First text token is treated as language
        const text = try self.it.consume(
            scratch,
            &.{.text},
        ) orelse break :blk "";
        if (open_fence.token_type == .backtick_fence and
            std.mem.count(u8, text.lexeme, "`") > 0)
        {
            return fail;
        }

        // Following tokens are allowed, but ignored
        while (try self.it.peek(scratch)) |next| {
            switch (next.token_type) {
                .text => {
                    if (open_fence.token_type == .backtick_fence and
                        std.mem.count(u8, next.lexeme, "`") > 0)
                    {
                        return fail;
                    }
                    _ = try self.it.consume(scratch, &.{.text});
                },
                .newline => break,
                .backtick_fence => {
                    if (open_fence.token_type == .backtick_fence) {
                        return fail;
                    }
                    _ = try self.it.consume(scratch, &.{.backtick_fence});
                },
                else => |t| {
                    _ = try self.it.consume(scratch, &.{t});
                },
            }
        }

        break :blk text.lexeme;
    };
    _ = try self.it.consume(scratch, &.{.newline}) orelse return fail;

    // Block content
    var content = Io.Writer.Allocating.init(scratch);
    self.interruptible = false;
    defer self.interruptible = true;
    loop: while (try self.it.peek(scratch)) |line_start_token| {
        // First token in line
        switch (line_start_token.token_type) {
            .backtick_fence, .tilde_fence => |t| {
                if (try self.peekClosingFence(scratch, open_fence)) {
                    break :loop;
                }

                _ = try self.it.consume(scratch, &.{t});
                _ = try content.writer.write(line_start_token.lexeme);
            },
            .space, .tab => {
                if (try self.peekClosingFence(scratch, open_fence)) {
                    // found closing fence
                    break :loop;
                }

                _ = try self.it.consumeWhitespaceUpTo(scratch, indentation);
            },
            .newline => {
                // TODO: all tokens should have lexemes
                _ = try self.it.consume(scratch, &.{.newline});
                _ = try content.writer.write("\n");
            },
            .close => {
                // Container is closing, can't keep parsing fenced code
                _ = try self.it.consume(scratch, &.{.close});
                saw_close_token = true;
                break :loop;
            },
            else => |t| {
                _ = try self.it.consume(scratch, &.{t});
                _ = try content.writer.write(line_start_token.lexeme);
            },
        }

        // Trailing tokens in line
        while (try self.it.peek(scratch)) |token| {
            switch (token.token_type) {
                .newline => {
                    // TODO: all tokens should have lexemes
                    _ = try self.it.consume(scratch, &.{.newline});
                    _ = try content.writer.write("\n");
                    break;
                },
                else => {
                    _ = try self.it.consume(scratch, &.{token.token_type});
                    _ = try content.writer.write(token.lexeme);
                },
            }
        }
    }

    if (!saw_close_token) {
        // Closing code fence line
        // Not needed if file ends
        _ = try self.it.consumeWhitespaceUpTo(scratch, 3);
        if (try self.it.consume(scratch, &.{open_fence.token_type})) |_| {
            _ = try self.it.consumeWhitespace(scratch);
            _ = try self.it.consume(scratch, &.{.newline}) orelse return fail;
        }
    }

    // MyST tests require trailing newline to be trimmed for AST, even though
    // it should be added back when rendered as HTML.
    // https://spec.commonmark.org/0.30/#example-119
    const trimmed = std.mem.trimEnd(u8, content.written(), "\n");

    const value = try alloc.dupeZ(u8, trimmed);
    errdefer alloc.free(value);
    const lang = try alloc.dupeZ(u8, info_lang);
    errdefer alloc.free(lang);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .code = .{
            .value = value,
            .lang = lang,
        },
    };
    did_parse = true;
    return .{
        .maybe_node = node,
        .should_end = saw_close_token,
    };
}

/// Returns true if the next tokens can be parsed as the closing fence of a
/// fenced code block or MyST directive.
fn peekClosingFence(
    self: *Self,
    scratch: Allocator,
    open_fence: BlockToken,
) !bool {
    const checkpoint_index = self.it.checkpoint();
    defer self.it.backtrack(checkpoint_index);

    _ = try self.it.consumeWhitespaceUpTo(scratch, 3);

    const close_fence = try self.it.consume(
        scratch,
        &.{open_fence.token_type},
    ) orelse return false;
    if (close_fence.lexeme.len < open_fence.lexeme.len) {
        return false;
    }

    _ = try self.it.consumeWhitespace(scratch);
    _ = try self.it.consume(scratch, &.{.newline}) orelse return false;

    return true;
}

/// https://spec.commonmark.org/0.30/#link-reference-definition
fn parseLinkReferenceDefinition(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.it.checkpoint();
    defer {
        if (!did_parse) {
            self.it.backtrack(checkpoint_index);
        }
    }

    // consume allowed leading whitespace
    _ = try self.it.consumeWhitespaceUpTo(scratch, 3);

    const scanned_label = try self.scanLinkDefLabel(scratch) orelse
        return null;
    _ = try self.it.consume(scratch, &.{.colon}) orelse return null;

    // whitespace allowed and up to one newline
    var seen_newline = false;
    while (try self.it.consume(scratch, &.{
        .newline,
        .space,
        .tab,
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
    const escaped_url = try escape.strip(scratch, scanned_url);
    const url = try cmark.uri.normalize(scratch, scratch, escaped_url);

    // whitespace allowed and up to one newline
    var seen_any_separating_whitespace = false;
    seen_newline = false;
    while (try self.it.peek(scratch)) |token| {
        switch (token.token_type) {
            .space, .tab => |t| {
                seen_any_separating_whitespace = true;
                _ = try self.it.consume(scratch, &.{t});
            },
            .newline => {
                seen_any_separating_whitespace = true;
                if (seen_newline) {
                    break;
                } else {
                    seen_newline = true;
                    _ = try self.it.consume(scratch, &.{.newline});
                }
            },
            else => break,
        }
    }

    const scanned_title = blk: {
        // link title, if present, must be separated from destination by
        // whitespace
        if (!seen_any_separating_whitespace) {
            break :blk "";
        }

        const title_checkpoint_index = self.it.checkpoint();
        const t = try self.scanLinkDefTitle(scratch) orelse break :blk "";

        // "no further character can occur" says the spec, but then there's an
        // example of spaces following the title, so we optionally consume
        // whitespace here.
        _ = try self.it.consumeWhitespace(scratch);

        if (seen_newline) {
            _ = try self.it.consume(scratch, &.{.newline}) orelse {
                // There was something after the title, but the title was
                // already on a separate line, so just fail to parse the title.
                self.it.backtrack(title_checkpoint_index);
                break :blk "";
            };
        }

        break :blk t;
    };

    if (!seen_newline) {
        // We didn't see a newline before the title (or there was no title). We
        // must see a newline now for this to be a valid link def.
        _ = try self.it.consume(scratch, &.{.newline}) orelse return null;
    }

    const label = try alloc.dupeZ(u8, scanned_label);
    errdefer alloc.free(label);
    const title = try alloc.dupeZ(u8, scanned_title);
    errdefer alloc.free(title);
    const ownedUrl = try alloc.dupeZ(u8, url);
    errdefer alloc.free(ownedUrl);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .definition = .{
            .url = ownedUrl,
            .label = label,
            .title = title,
        },
    };
    did_parse = true;
    return node;
}

/// Scans the link label part of a link reference definition.
///
/// https://spec.commonmark.org/0.30/#link-label
///
/// Also see: link label scanning in the inline parser.
fn scanLinkDefLabel(self: *Self, scratch: Allocator) !?[]const u8 {
    var did_parse = false;
    var running_text = Io.Writer.Allocating.init(scratch);
    const checkpoint_index = self.it.checkpoint();
    defer if (!did_parse) {
        self.it.backtrack(checkpoint_index);
    };

    _ = try self.it.consume(
        scratch,
        &.{.l_square_bracket},
    ) orelse return null;

    var saw_non_blank = false;
    while (try self.it.peek(scratch)) |token| {
        switch (token.token_type) {
            .space, .tab => |t| {
                _ = try self.it.consume(scratch, &.{t});
                _ = try running_text.writer.write(token.lexeme);
            },
            .newline => {
                _ = try self.it.consume(scratch, &.{.newline});
                _ = try running_text.writer.write("\n");
            },
            .l_square_bracket => return null,
            .r_square_bracket => break,
            else => |t| {
                saw_non_blank = true;
                _ = try self.it.consume(scratch, &.{t});
                _ = try running_text.writer.write(token.lexeme);
            },
        }
    }

    _ = try self.it.consume(
        scratch,
        &.{.r_square_bracket},
    ) orelse return null;

    if (!saw_non_blank) {
        // Label must contain non-whitespace character
        return null;
    }

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
    const checkpoint_index = self.it.checkpoint();
    defer if (!did_parse) {
        self.it.backtrack(checkpoint_index);
    };

    var running_text = Io.Writer.Allocating.init(scratch);
    if (try self.it.consume(scratch, &.{.l_angle_bracket})) |_| {
        // Option one, angle bracket delimited, empty string allowed
        while (try self.it.peek(scratch)) |token| {
            switch (token.token_type) {
                .close => @panic("unimplemented"), // TODO
                .l_angle_bracket, .newline => return null,
                .r_angle_bracket => break,
                // None of these tokens should really be possible here, since
                // they can only be matched at the beginning of a line.
                .rule_star,
                .rule_underline,
                .rule_dash_with_whitespace,
                .rule_dash,
                .rule_equals,
                .backtick_fence,
                .tilde_fence,
                .colon_fence,
                => return null,
                .text,
                .pound,
                .space,
                .tab,
                .colon,
                .l_square_bracket,
                .r_square_bracket,
                .l_paren,
                .r_paren,
                .l_brace,
                .r_brace,
                .double_quote,
                .single_quote,
                .hyphen,
                .star,
                .plus,
                .exclamation_mark,
                .question_mark,
                .slash,
                .period,
                => |t| {
                    _ = try self.it.consume(scratch, &.{t});
                    const value = try resolveText(scratch, token);
                    _ = try running_text.writer.write(value);
                },
            }
        }
        _ = try self.it.consume(scratch, &.{.r_angle_bracket});
    } else {
        // Option two
        // - non-zero length
        // - no ascii control chars
        // - no spaces
        // - balanced parens
        var paren_depth: u32 = 0;
        while (try self.it.peek(scratch)) |token| {
            switch (token.token_type) {
                .close => @panic("unimplemented"), // TODO
                .l_paren => {
                    paren_depth += 1;
                    _ = try self.it.consume(scratch, &.{.l_paren});
                    _ = try running_text.writer.write(token.lexeme);
                },
                .r_paren => {
                    if (paren_depth == 0) {
                        break;
                    }

                    paren_depth -= 1;
                    _ = try self.it.consume(scratch, &.{.r_paren});
                    _ = try running_text.writer.write(token.lexeme);
                },
                .newline, .space, .tab => break,
                .rule_star,
                .rule_underline,
                .rule_dash_with_whitespace,
                .rule_dash,
                .rule_equals,
                .backtick_fence,
                .tilde_fence,
                .colon_fence,
                => return null,
                .text,
                .pound,
                .colon,
                .l_square_bracket,
                .r_square_bracket,
                .l_angle_bracket,
                .r_angle_bracket,
                .l_brace,
                .r_brace,
                .double_quote,
                .single_quote,
                .hyphen,
                .star,
                .plus,
                .exclamation_mark,
                .question_mark,
                .slash,
                .period,
                => |t| {
                    _ = try self.it.consume(scratch, &.{t});
                    if (util.strings.containsAsciiControl(token.lexeme)) {
                        return null;
                    }
                    const value = try resolveText(scratch, token);
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
    const checkpoint_index = self.it.checkpoint();
    defer if (!did_parse) {
        self.it.backtrack(checkpoint_index);
    };

    var running_text = Io.Writer.Allocating.init(scratch);

    const open = try self.it.consume(
        scratch,
        &.{ .l_paren, .single_quote, .double_quote },
    ) orelse return "";

    const open_t = open.token_type;
    const close_t = if (open_t == .l_paren) .r_paren else open_t;

    var blank_line_so_far = false;
    while (try self.it.peek(scratch)) |token| {
        switch (token.token_type) {
            .newline => {
                if (blank_line_so_far) {
                    return null; // link title cannot contain blank line
                }
                _ = try self.it.consume(scratch, &.{.newline});
                _ = try running_text.writer.write("\n");

                blank_line_so_far = true;
            },
            .space, .tab => |t| {
                _ = try self.it.consume(scratch, &.{t});
                _ = try running_text.writer.write(token.lexeme);
            },
            else => |t| {
                if (t == close_t) {
                    break;
                }

                _ = try self.it.consume(scratch, &.{t});
                const value = try resolveText(scratch, token);
                _ = try running_text.writer.write(value);
                blank_line_so_far = false;
            },
        }
    }
    _ = try self.it.consume(scratch, &.{close_t}) orelse return null;

    did_parse = true;
    return try running_text.toOwnedSlice();
}

/// Parses an HTML block.
///
/// https://spec.commonmark.org/0.30/#html-block
///
/// An HTML block begins with a start condition and ends with a matching end
/// condition. There are seven different start and end conditions.
///
/// The Commonmark spec supports basically any kind of HTML, even with
/// arbitrary tag names.
fn parseHTML(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !EndingParseResult {
    var result = try self.parseHTMLLiteralContent(alloc, scratch);
    if (result.maybe_node) |_| {
        return result;
    }

    result = try self.parseHTMLComment(alloc, scratch);
    if (result.maybe_node) |_| {
        return result;
    }

    result = try self.parseHTMLProcessingInstruction(alloc, scratch);
    if (result.maybe_node) |_| {
        return result;
    }

    result = try self.parseHTMLDeclaration(alloc, scratch);
    if (result.maybe_node) |_| {
        return result;
    }

    result = try self.parseHTMLCDATA(alloc, scratch);
    if (result.maybe_node) |_| {
        return result;
    }

    result = try self.parseHTMLKnownTag(alloc, scratch);
    if (result.maybe_node) |_| {
        return result;
    }

    result = try self.parseHTMLUnknownTag(alloc, scratch);
    if (result.maybe_node) |_| {
        return result;
    }

    return .{
        .maybe_node = null,
    };
}

fn isLiteralContentHTMLTagName(s: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(s, "pre") or
        std.ascii.eqlIgnoreCase(s, "script") or
        std.ascii.eqlIgnoreCase(s, "style") or
        std.ascii.eqlIgnoreCase(s, "textarea"))
    {
        return true;
    }

    return false;
}

/// Parse a pre, script, style, or textarea HTML element. These can contain
/// blank lines.
fn parseHTMLLiteralContent(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !EndingParseResult {
    var did_parse = false;
    const checkpoint_index = self.it.checkpoint();
    defer if (!did_parse) {
        self.it.backtrack(checkpoint_index);
    };

    const fail: EndingParseResult = .{ .maybe_node = null };
    var saw_close_token = false;
    var content = Io.Writer.Allocating.init(scratch);

    // Handle allowed leading whitespace
    const ws_tokens = try self.it.consumeWhitespaceUpTo(scratch, 3);
    for (ws_tokens) |t| {
        _ = try content.writer.write(t.lexeme);
    }

    // start condition
    _ = try self.it.consume(scratch, &.{.l_angle_bracket}) orelse return fail;
    const open_tag_token = try self.it.consume(scratch, &.{.text}) orelse
        return fail;
    if (!isLiteralContentHTMLTagName(open_tag_token.lexeme)) {
        return fail;
    }
    const following_token = try self.it.consume(
        scratch,
        &.{ .space, .tab, .r_angle_bracket, .newline },
    ) orelse return fail;
    if (following_token.token_type == .newline) { // TODO: newline lexeme?
        _ = try content.writer.print("<{s}\n", .{open_tag_token.lexeme});
    } else {
        _ = try content.writer.print(
            "<{s}{s}",
            .{ open_tag_token.lexeme, following_token.lexeme },
        );
    }

    // Cannot start a new container in an HTML block.
    self.interruptible = false;
    defer self.interruptible = true;

    // Handle content within block
    while (try self.it.peek(scratch)) |token| {
        switch (token.token_type) {
            .l_angle_bracket => {
                const have_end_condition: bool = blk: {
                    if (try self.it.peekAhead(scratch, 2)) |t| {
                        if (t.token_type != .slash) {
                            break :blk false;
                        }
                    }

                    if (try self.it.peekAhead(scratch, 3)) |t| {
                        if (t.token_type != .text or
                            !isLiteralContentHTMLTagName(t.lexeme))
                        {
                            break :blk false;
                        }
                    }

                    if (try self.it.peekAhead(scratch, 4)) |t| {
                        if (t.token_type != .r_angle_bracket) {
                            break :blk false;
                        }
                    }

                    break :blk true;
                };

                if (have_end_condition) {
                    _ = try self.it.consume(scratch, &.{.l_angle_bracket});
                    _ = try self.it.consume(scratch, &.{.slash});
                    const close_tag_token = try self.it.consume(
                        scratch,
                        &.{.text},
                    ) orelse unreachable;
                    _ = try self.it.consume(scratch, &.{.r_angle_bracket});
                    _ = try content.writer.print(
                        "</{s}>",
                        .{close_tag_token.lexeme},
                    );
                    break;
                } else {
                    _ = try self.it.consume(scratch, &.{.l_angle_bracket});
                    _ = try content.writer.write(token.lexeme);
                }
            },
            .close => {
                _ = try self.it.consume(scratch, &.{.close});
                saw_close_token = true;
                break;
            },
            .newline => {
                _ = try self.it.consume(scratch, &.{.newline});
                _ = try content.writer.write("\n");
            },
            else => |t| {
                _ = try self.it.consume(scratch, &.{t});
                _ = try content.writer.write(token.lexeme);
            },
        }
    }

    // Handle content trailing comment block end
    if (!saw_close_token) {
        while (try self.it.peek(scratch)) |token| {
            switch (token.token_type) {
                .newline => {
                    _ = try self.it.consume(scratch, &.{.newline});
                    break;
                },
                else => |t| {
                    _ = try self.it.consume(scratch, &.{t});
                    _ = try content.writer.write(token.lexeme);
                },
            }
        }
    }

    const owned_value = try alloc.dupeZ(u8, content.written());
    errdefer alloc.free(owned_value);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .html = .{
            .value = owned_value,
        },
    };

    did_parse = true;
    return .{
        .maybe_node = node,
        .should_end = saw_close_token,
    };
}

/// Parse HTML comment.
///
/// Start condition is "<!--" (at the beginning of a line). End condition is
/// "-->" somewhere in a line. Any trailing content in the last line is
/// included in the HTML block.
fn parseHTMLComment(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !EndingParseResult {
    var did_parse = false;
    const checkpoint_index = self.it.checkpoint();
    defer if (!did_parse) {
        self.it.backtrack(checkpoint_index);
    };

    const fail: EndingParseResult = .{ .maybe_node = null };
    var saw_close_token = false;
    var content = Io.Writer.Allocating.init(scratch);

    // Handle allowed leading whitespace
    const ws_tokens = try self.it.consumeWhitespaceUpTo(scratch, 3);
    for (ws_tokens) |t| {
        _ = try content.writer.write(t.lexeme);
    }

    // start condition
    _ = try self.it.consume(scratch, &.{.l_angle_bracket}) orelse return fail;
    _ = try self.it.consume(scratch, &.{.exclamation_mark}) orelse return fail;
    _ = try self.it.consume(scratch, &.{.hyphen}) orelse return fail;
    _ = try self.it.consume(scratch, &.{.hyphen}) orelse return fail;
    _ = try content.writer.write("<!--");

    // Cannot start a new container in an HTML block.
    self.interruptible = false;
    defer self.interruptible = true;

    // Handle content within comment block
    while (try self.it.peek(scratch)) |token| {
        switch (token.token_type) {
            .hyphen => {
                const have_end_condition: bool = blk: {
                    if (try self.it.peekAhead(scratch, 2)) |t| {
                        if (t.token_type != .hyphen) {
                            break :blk false;
                        }
                    }

                    if (try self.it.peekAhead(scratch, 3)) |t| {
                        if (t.token_type != .r_angle_bracket) {
                            break :blk false;
                        }
                    }

                    break :blk true;
                };

                if (have_end_condition) {
                    _ = try self.it.consume(scratch, &.{.hyphen});
                    _ = try self.it.consume(scratch, &.{.hyphen});
                    _ = try self.it.consume(scratch, &.{.r_angle_bracket});
                    _ = try content.writer.write("-->");
                    break;
                } else {
                    _ = try self.it.consume(scratch, &.{.hyphen});
                    _ = try content.writer.write(token.lexeme);
                }
            },
            .close => {
                _ = try self.it.consume(scratch, &.{.close});
                saw_close_token = true;
                break;
            },
            .newline => {
                _ = try self.it.consume(scratch, &.{.newline});
                _ = try content.writer.write("\n");
            },
            else => |t| {
                _ = try self.it.consume(scratch, &.{t});
                _ = try content.writer.write(token.lexeme);
            },
        }
    }

    // Handle content trailing comment block end
    if (!saw_close_token) {
        while (try self.it.peek(scratch)) |token| {
            switch (token.token_type) {
                .newline => {
                    _ = try self.it.consume(scratch, &.{.newline});
                    break;
                },
                else => |t| {
                    _ = try self.it.consume(scratch, &.{t});
                    _ = try content.writer.write(token.lexeme);
                },
            }
        }
    }

    const owned_value = try alloc.dupeZ(u8, content.written());
    errdefer alloc.free(owned_value);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .html = .{
            .value = owned_value,
        },
    };

    did_parse = true;
    return .{
        .maybe_node = node,
        .should_end = saw_close_token,
    };
}

/// Parses an HTML block that begins with "<?" and ends with "?>".
///
/// Trailing content in the last line is included in the HTML block.
fn parseHTMLProcessingInstruction(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !EndingParseResult {
    var did_parse = false;
    const checkpoint_index = self.it.checkpoint();
    defer if (!did_parse) {
        self.it.backtrack(checkpoint_index);
    };

    const fail: EndingParseResult = .{ .maybe_node = null };
    var saw_close_token = false;
    var content = Io.Writer.Allocating.init(scratch);

    // Handle allowed leading whitespace
    const ws_tokens = try self.it.consumeWhitespaceUpTo(scratch, 3);
    for (ws_tokens) |t| {
        _ = try content.writer.write(t.lexeme);
    }

    // start condition
    _ = try self.it.consume(scratch, &.{.l_angle_bracket}) orelse return fail;
    _ = try self.it.consume(scratch, &.{.question_mark}) orelse return fail;
    _ = try content.writer.write("<?");

    // Cannot start a new container in an HTML block.
    self.interruptible = false;
    defer self.interruptible = true;

    // Handle content within processing instruction block
    while (try self.it.peek(scratch)) |token| {
        switch (token.token_type) {
            .question_mark => {
                const have_end_condition: bool = blk: {
                    if (try self.it.peekAhead(scratch, 2)) |t| {
                        if (t.token_type != .r_angle_bracket) {
                            break :blk false;
                        }
                    }

                    break :blk true;
                };

                if (have_end_condition) {
                    _ = try self.it.consume(scratch, &.{.question_mark});
                    _ = try self.it.consume(scratch, &.{.r_angle_bracket});
                    _ = try content.writer.write("?>");
                    break;
                } else {
                    _ = try self.it.consume(scratch, &.{.question_mark});
                    _ = try content.writer.write(token.lexeme);
                }
            },
            .close => {
                _ = try self.it.consume(scratch, &.{.close});
                saw_close_token = true;
                break;
            },
            .newline => {
                _ = try self.it.consume(scratch, &.{.newline});
                _ = try content.writer.write("\n");
            },
            else => |t| {
                _ = try self.it.consume(scratch, &.{t});
                _ = try content.writer.write(token.lexeme);
            },
        }
    }

    // Handle content trailing content
    if (!saw_close_token) {
        while (try self.it.peek(scratch)) |token| {
            switch (token.token_type) {
                .newline => {
                    _ = try self.it.consume(scratch, &.{.newline});
                    break;
                },
                else => |t| {
                    _ = try self.it.consume(scratch, &.{t});
                    _ = try content.writer.write(token.lexeme);
                },
            }
        }
    }

    const owned_value = try alloc.dupeZ(u8, content.written());
    errdefer alloc.free(owned_value);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .html = .{
            .value = owned_value,
        },
    };

    did_parse = true;
    return .{
        .maybe_node = node,
        .should_end = saw_close_token,
    };
}

/// Parses an HTML declaration, which begins with "<!" followed by an ASCII
/// letter and ends with ">".
fn parseHTMLDeclaration(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !EndingParseResult {
    var did_parse = false;
    const checkpoint_index = self.it.checkpoint();
    defer if (!did_parse) {
        self.it.backtrack(checkpoint_index);
    };

    const fail: EndingParseResult = .{ .maybe_node = null };
    var saw_close_token = false;
    var content = Io.Writer.Allocating.init(scratch);

    // Handle allowed leading whitespace
    const ws_tokens = try self.it.consumeWhitespaceUpTo(scratch, 3);
    for (ws_tokens) |t| {
        _ = try content.writer.write(t.lexeme);
    }

    // start condition
    _ = try self.it.consume(scratch, &.{.l_angle_bracket}) orelse return fail;
    _ = try self.it.consume(scratch, &.{.exclamation_mark}) orelse return fail;
    const first_token = try self.it.peek(scratch) orelse return fail;
    if (first_token.token_type != .text or
        first_token.lexeme.len < 1 or
        !std.ascii.isAlphabetic(first_token.lexeme[0]))
    {
        return fail;
    }
    _ = try content.writer.write("<!");

    // Cannot start a new container in an HTML block.
    self.interruptible = false;
    defer self.interruptible = true;

    // Handle content within declaration block
    while (try self.it.peek(scratch)) |token| {
        switch (token.token_type) {
            .r_angle_bracket => {
                _ = try self.it.consume(scratch, &.{.r_angle_bracket});
                _ = try content.writer.write(">");
                break;
            },
            .close => {
                _ = try self.it.consume(scratch, &.{.close});
                saw_close_token = true;
                break;
            },
            .newline => {
                _ = try self.it.consume(scratch, &.{.newline});
                _ = try content.writer.write("\n");
            },
            else => |t| {
                _ = try self.it.consume(scratch, &.{t});
                _ = try content.writer.write(token.lexeme);
            },
        }
    }

    // Handle content trailing content
    if (!saw_close_token) {
        while (try self.it.peek(scratch)) |token| {
            switch (token.token_type) {
                .newline => {
                    _ = try self.it.consume(scratch, &.{.newline});
                    break;
                },
                else => |t| {
                    _ = try self.it.consume(scratch, &.{t});
                    _ = try content.writer.write(token.lexeme);
                },
            }
        }
    }

    const owned_value = try alloc.dupeZ(u8, content.written());
    errdefer alloc.free(owned_value);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .html = .{
            .value = owned_value,
        },
    };

    did_parse = true;
    return .{
        .maybe_node = node,
        .should_end = saw_close_token,
    };
}

fn parseHTMLCDATA(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !EndingParseResult {
    var did_parse = false;
    const checkpoint_index = self.it.checkpoint();
    defer if (!did_parse) {
        self.it.backtrack(checkpoint_index);
    };

    const fail: EndingParseResult = .{ .maybe_node = null };
    var saw_close_token = false;
    var content = Io.Writer.Allocating.init(scratch);

    // Handle allowed leading whitespace
    const ws_tokens = try self.it.consumeWhitespaceUpTo(scratch, 3);
    for (ws_tokens) |t| {
        _ = try content.writer.write(t.lexeme);
    }

    // start condition
    _ = try self.it.consume(scratch, &.{.l_angle_bracket}) orelse return fail;
    _ = try self.it.consume(scratch, &.{.exclamation_mark}) orelse return fail;
    _ = try self.it.consume(scratch, &.{.l_square_bracket}) orelse return fail;
    {
        const token = try self.it.consume(scratch, &.{.text}) orelse
            return fail;
        if (!std.mem.eql(u8, token.lexeme, "CDATA")) {
            return fail;
        }
    }
    _ = try self.it.consume(scratch, &.{.l_square_bracket}) orelse return fail;
    _ = try content.writer.write("<![CDATA[");

    // Cannot start a new container in an HTML block.
    self.interruptible = false;
    defer self.interruptible = true;

    // Handle content within declaration block
    while (try self.it.peek(scratch)) |token| {
        switch (token.token_type) {
            .r_square_bracket => {
                const have_end_condition: bool = blk: {
                    if (try self.it.peekAhead(scratch, 2)) |t| {
                        if (t.token_type != .r_square_bracket) {
                            break :blk false;
                        }
                    }

                    if (try self.it.peekAhead(scratch, 3)) |t| {
                        if (t.token_type != .r_angle_bracket) {
                            break :blk false;
                        }
                    }

                    break :blk true;
                };

                if (have_end_condition) {
                    _ = try self.it.consume(scratch, &.{.r_square_bracket});
                    _ = try self.it.consume(scratch, &.{.r_square_bracket});
                    _ = try self.it.consume(scratch, &.{.r_angle_bracket});
                    _ = try content.writer.write("]]>");
                    break;
                } else {
                    _ = try self.it.consume(scratch, &.{.r_square_bracket});
                    _ = try content.writer.write(token.lexeme);
                }
            },
            .close => {
                _ = try self.it.consume(scratch, &.{.close});
                saw_close_token = true;
                break;
            },
            .newline => {
                _ = try self.it.consume(scratch, &.{.newline});
                _ = try content.writer.write("\n");
            },
            else => |t| {
                _ = try self.it.consume(scratch, &.{t});
                _ = try content.writer.write(token.lexeme);
            },
        }
    }

    // Handle content trailing content
    if (!saw_close_token) {
        while (try self.it.peek(scratch)) |token| {
            switch (token.token_type) {
                .newline => {
                    _ = try self.it.consume(scratch, &.{.newline});
                    break;
                },
                else => |t| {
                    _ = try self.it.consume(scratch, &.{t});
                    _ = try content.writer.write(token.lexeme);
                },
            }
        }
    }

    const owned_value = try alloc.dupeZ(u8, content.written());
    errdefer alloc.free(owned_value);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .html = .{
            .value = owned_value,
        },
    };

    did_parse = true;
    return .{
        .maybe_node = node,
        .should_end = saw_close_token,
    };
}

fn isKnownHTMLTagName(s: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(s, "address") or
        std.ascii.eqlIgnoreCase(s, "article") or
        std.ascii.eqlIgnoreCase(s, "aside") or
        std.ascii.eqlIgnoreCase(s, "base") or
        std.ascii.eqlIgnoreCase(s, "basefont") or
        std.ascii.eqlIgnoreCase(s, "blockquote") or
        std.ascii.eqlIgnoreCase(s, "body") or
        std.ascii.eqlIgnoreCase(s, "caption") or
        std.ascii.eqlIgnoreCase(s, "center") or
        std.ascii.eqlIgnoreCase(s, "col") or
        std.ascii.eqlIgnoreCase(s, "colgroup") or
        std.ascii.eqlIgnoreCase(s, "dd") or
        std.ascii.eqlIgnoreCase(s, "details") or
        std.ascii.eqlIgnoreCase(s, "dialog") or
        std.ascii.eqlIgnoreCase(s, "dir") or
        std.ascii.eqlIgnoreCase(s, "div") or
        std.ascii.eqlIgnoreCase(s, "dl") or
        std.ascii.eqlIgnoreCase(s, "dt") or
        std.ascii.eqlIgnoreCase(s, "fieldset") or
        std.ascii.eqlIgnoreCase(s, "figcaption") or
        std.ascii.eqlIgnoreCase(s, "figure") or
        std.ascii.eqlIgnoreCase(s, "footer") or
        std.ascii.eqlIgnoreCase(s, "form") or
        std.ascii.eqlIgnoreCase(s, "frame") or
        std.ascii.eqlIgnoreCase(s, "frameset") or
        std.ascii.eqlIgnoreCase(s, "h1") or
        std.ascii.eqlIgnoreCase(s, "h2") or
        std.ascii.eqlIgnoreCase(s, "h3") or
        std.ascii.eqlIgnoreCase(s, "h4") or
        std.ascii.eqlIgnoreCase(s, "h5") or
        std.ascii.eqlIgnoreCase(s, "h6") or
        std.ascii.eqlIgnoreCase(s, "head") or
        std.ascii.eqlIgnoreCase(s, "header") or
        std.ascii.eqlIgnoreCase(s, "hr") or
        std.ascii.eqlIgnoreCase(s, "html") or
        std.ascii.eqlIgnoreCase(s, "iframe") or
        std.ascii.eqlIgnoreCase(s, "legend") or
        std.ascii.eqlIgnoreCase(s, "li") or
        std.ascii.eqlIgnoreCase(s, "link") or
        std.ascii.eqlIgnoreCase(s, "main") or
        std.ascii.eqlIgnoreCase(s, "menu") or
        std.ascii.eqlIgnoreCase(s, "menuitem") or
        std.ascii.eqlIgnoreCase(s, "nav") or
        std.ascii.eqlIgnoreCase(s, "noframes") or
        std.ascii.eqlIgnoreCase(s, "ol") or
        std.ascii.eqlIgnoreCase(s, "optgroup") or
        std.ascii.eqlIgnoreCase(s, "option") or
        std.ascii.eqlIgnoreCase(s, "p") or
        std.ascii.eqlIgnoreCase(s, "param") or
        std.ascii.eqlIgnoreCase(s, "section") or
        std.ascii.eqlIgnoreCase(s, "source") or
        std.ascii.eqlIgnoreCase(s, "summary") or
        std.ascii.eqlIgnoreCase(s, "table") or
        std.ascii.eqlIgnoreCase(s, "tbody") or
        std.ascii.eqlIgnoreCase(s, "td") or
        std.ascii.eqlIgnoreCase(s, "tfoot") or
        std.ascii.eqlIgnoreCase(s, "th") or
        std.ascii.eqlIgnoreCase(s, "thead") or
        std.ascii.eqlIgnoreCase(s, "title") or
        std.ascii.eqlIgnoreCase(s, "tr") or
        std.ascii.eqlIgnoreCase(s, "track") or
        std.ascii.eqlIgnoreCase(s, "ul"))
    {
        return true;
    }

    return false;
}

/// Parse HTML block using recognized HTML tags, e.g. "div", "table", "ul".
///
/// Start condition is a "<" or "</" followed by a recognized tag name, then
/// whitespace, a newline, ">", or "/>". End condition is a blank line.
fn parseHTMLKnownTag(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !EndingParseResult {
    var did_parse = false;
    const checkpoint_index = self.it.checkpoint();
    defer if (!did_parse) {
        self.it.backtrack(checkpoint_index);
    };

    const fail: EndingParseResult = .{ .maybe_node = null };
    var saw_close_token = false;
    var content = Io.Writer.Allocating.init(scratch);

    // Handle allowed leading whitespace
    const ws_tokens = try self.it.consumeWhitespaceUpTo(scratch, 3);
    for (ws_tokens) |t| {
        _ = try content.writer.write(t.lexeme);
    }

    // start condition
    _ = try self.it.consume(scratch, &.{.l_angle_bracket}) orelse return fail;
    _ = try content.writer.write("<");
    if (try self.it.consume(scratch, &.{.slash})) |_| {
        _ = try content.writer.write("/");
    }

    const open_tag_token = try self.it.consume(scratch, &.{.text}) orelse
        return fail;
    if (!isKnownHTMLTagName(open_tag_token.lexeme)) {
        return fail;
    }
    _ = try content.writer.write(open_tag_token.lexeme);

    const following_token = try self.it.consume(
        scratch,
        &.{ .space, .tab, .r_angle_bracket, .newline, .slash },
    ) orelse return fail;
    if (following_token.token_type == .newline) { // TODO: newline lexeme?
        _ = try content.writer.write("\n");
    } else if (following_token.token_type == .slash) {
        _ = try self.it.consume(scratch, &.{.r_angle_bracket}) orelse
            return fail;
        _ = try content.writer.write("/>");
    } else {
        std.debug.assert(following_token.lexeme.len > 0);
        _ = try content.writer.write(following_token.lexeme);
    }

    // Cannot start a new container in an HTML block.
    self.interruptible = false;
    defer self.interruptible = true;

    // Handle content within block
    while (try self.it.peek(scratch)) |token| {
        switch (token.token_type) {
            .close => {
                _ = try self.it.consume(scratch, &.{.close});
                saw_close_token = true;
                break;
            },
            .newline => {
                _ = try self.it.consume(scratch, &.{.newline});
                if (try self.it.consume(scratch, &.{.newline})) |_| {
                    // end condition
                    break;
                } else if (try self.it.peek(scratch)) |_| {
                    // Only write newline if we haven't reached end of document
                    _ = try content.writer.write("\n");
                }
            },
            else => |t| {
                _ = try self.it.consume(scratch, &.{t});
                _ = try content.writer.write(token.lexeme);
            },
        }
    }

    const owned_value = try alloc.dupeZ(u8, content.written());
    errdefer alloc.free(owned_value);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .html = .{
            .value = owned_value,
        },
    };

    did_parse = true;
    return .{
        .maybe_node = node,
        .should_end = saw_close_token,
    };
}

/// Parse HTML block beginning with an unrecognized HTML tag.
///
/// Has to begin with the whole tag alone on its own line. Can be an opening or
/// closing tag. End condition is a blank line.
fn parseHTMLUnknownTag(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !EndingParseResult {
    var did_parse = false;
    const checkpoint_index = self.it.checkpoint();
    defer if (!did_parse) {
        self.it.backtrack(checkpoint_index);
    };

    const fail: EndingParseResult = .{ .maybe_node = null };
    var saw_close_token = false;
    var content = Io.Writer.Allocating.init(scratch);

    // Handle allowed leading whitespace
    var ws_tokens = try self.it.consumeWhitespaceUpTo(scratch, 3);
    for (ws_tokens) |t| {
        _ = try content.writer.write(t.lexeme);
    }

    // start condition
    _ = try self.it.consume(scratch, &.{.l_angle_bracket}) orelse return fail;
    _ = try content.writer.write("<");
    if (try self.it.consume(scratch, &.{.slash})) |_| {
        _ = try content.writer.write("/");
    }

    const open_tag_token = try self.it.consume(scratch, &.{.text}) orelse
        return fail;
    if (isLiteralContentHTMLTagName(open_tag_token.lexeme)) {
        return fail; // Can't be any of these tags
    }
    _ = try content.writer.write(open_tag_token.lexeme);

    if (try self.it.consume(scratch, &.{.slash})) |_| {
        _ = try content.writer.write("/");
    }
    _ = try self.it.consume(scratch, &.{.r_angle_bracket}) orelse return fail;
    _ = try content.writer.write(">");

    ws_tokens = try self.it.consumeWhitespace(scratch);
    for (ws_tokens) |t| {
        _ = try content.writer.write(t.lexeme);
    }
    if (try self.it.peek(scratch)) |next_token| {
        if (next_token.token_type != .newline) {
            return fail;
        }
    } else {
        return fail;
    }

    // Cannot start a new container in an HTML block.
    self.interruptible = false;
    defer self.interruptible = true;

    // Handle content within block
    while (try self.it.peek(scratch)) |token| {
        switch (token.token_type) {
            .close => {
                _ = try self.it.consume(scratch, &.{.close});
                saw_close_token = true;
                break;
            },
            .newline => {
                _ = try self.it.consume(scratch, &.{.newline});
                if (try self.it.consume(scratch, &.{.newline})) |_| {
                    // end condition
                    break;
                } else if (try self.it.peek(scratch)) |_| {
                    // Only write newline if we haven't reached end of document
                    _ = try content.writer.write("\n");
                }
            },
            else => |t| {
                _ = try self.it.consume(scratch, &.{t});
                _ = try content.writer.write(token.lexeme);
            },
        }
    }

    const owned_value = try alloc.dupeZ(u8, content.written());
    errdefer alloc.free(owned_value);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .html = .{
            .value = owned_value,
        },
    };

    did_parse = true;
    return .{
        .maybe_node = node,
        .should_end = saw_close_token,
    };
}

/// Parses a MyST directive.
///
/// MyST directives are delimited by "fences" of three or more colons or
/// backticks. The closing fence must use the same character and be at least
/// as long as the opening fence.
fn parseMySTDirective(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !EndingParseResult {
    var did_parse = false;
    const checkpoint_index = self.it.checkpoint();
    defer if (!did_parse) {
        self.it.backtrack(checkpoint_index);
    };

    const fail: EndingParseResult = .{ .maybe_node = null };
    var saw_close_token = false;

    // Opening code fence line
    const ws_tokens = try self.it.consumeWhitespaceUpTo(scratch, 3);
    const indentation = whitespaceLen(ws_tokens);
    const open_fence = try self.it.consume(
        scratch,
        &.{ .backtick_fence, .colon_fence },
    ) orelse return fail;

    _ = try self.it.consume(scratch, &.{.l_brace}) orelse return fail;

    // Parse directive name
    var running_text = Io.Writer.Allocating.init(scratch);
    while (try self.it.peek(scratch)) |token| {
        switch (token.token_type) {
            .text, .space, .tab => {
                _ = try self.it.consume(scratch, &.{token.token_type});
                const v = try resolveText(scratch, token);
                _ = try running_text.writer.write(v);
            },
            else => break,
        }
    }

    const name = std.mem.trim(u8, try running_text.toOwnedSlice(), " \t");

    _ = try self.it.consume(scratch, &.{.r_brace}) orelse return fail;
    _ = try self.it.consumeWhitespace(scratch);

    // Parse args
    while (try self.it.peek(scratch)) |token| {
        switch (token.token_type) {
            .newline => {
                break;
            },
            .backtick_fence => {
                if (open_fence.token_type == .backtick_fence) {
                    // This can't be a directive. Could eventually parse as an
                    // inline code block.
                    return fail;
                }

                _ = try self.it.consume(scratch, &.{.backtick_fence});
                _ = try running_text.writer.write(token.lexeme);
            },
            else => |t| {
                _ = try self.it.consume(scratch, &.{t});
                _ = try running_text.writer.write(token.lexeme);
            },
        }
    }

    _ = try self.it.consume(scratch, &.{.newline}) orelse return fail;

    const args = std.mem.trim(u8, try running_text.toOwnedSlice(), " \t");

    self.interruptible = false;
    defer self.interruptible = true;

    // Options
    var options: ArrayList(ast.MySTDirective.Option) = .empty;
    defer if (!did_parse) {
        for (options.items) |opt| {
            opt.deinit(alloc);
        }
        options.deinit(alloc);
    };

    while (try self.parseMySTDirectiveOption(alloc, scratch)) |option| {
        try options.append(alloc, option);
    }

    // Block content
    var content = Io.Writer.Allocating.init(scratch);
    loop: while (try self.it.peek(scratch)) |line_start_token| {
        // Handle first token in line
        switch (line_start_token.token_type) {
            .backtick_fence, .colon_fence => |t| {
                if (try self.peekClosingFence(scratch, open_fence)) {
                    break :loop;
                }

                _ = try self.it.consume(scratch, &.{t});
                _ = try content.writer.write(line_start_token.lexeme);
            },
            .space, .tab => {
                if (try self.peekClosingFence(scratch, open_fence)) {
                    break :loop;
                }

                _ = try self.it.consumeWhitespaceUpTo(scratch, indentation);
            },
            .newline => {
                _ = try self.it.consume(scratch, &.{.newline});
                _ = try content.writer.write("\n");
            },
            .close => {
                // Container is closing, can't keep parsing directive
                _ = try self.it.consume(scratch, &.{.close});
                saw_close_token = true;
                break :loop;
            },
            else => |t| {
                _ = try self.it.consume(scratch, &.{t});
                _ = try content.writer.write(line_start_token.lexeme);
            },
        }

        // Handle trailing tokens
        while (try self.it.peek(scratch)) |token| {
            switch (token.token_type) {
                .newline => {
                    _ = try self.it.consume(scratch, &.{.newline});
                    _ = try content.writer.write("\n");
                    break;
                },
                else => {
                    _ = try self.it.consume(scratch, &.{token.token_type});
                    _ = try content.writer.write(token.lexeme);
                },
            }
        }
    }

    const value = std.mem.trim(u8, content.written(), " \t\n");

    // Closing fence
    if (!saw_close_token) {
        // Closing fence line
        // Not needed if file ends
        _ = try self.it.consumeWhitespaceUpTo(scratch, 3);
        if (try self.it.consume(scratch, &.{open_fence.token_type})) |_| {
            _ = try self.it.consumeWhitespace(scratch);
            _ = try self.it.consume(scratch, &.{.newline}) orelse return fail;
        }
    }

    did_parse = true;

    if (!myst.isValidDirectiveName(name)) {
        const owned_message = try alloc.dupeZ(
            u8,
            "Invalid MyST directive name",
        );
        errdefer alloc.free(owned_message);

        const error_node = try alloc.create(ast.Node);
        error_node.* = .{
            .myst_directive_error = .{
                .children = &.{},
                .message = owned_message,
            },
        };
        return .{
            .maybe_node = error_node,
            .should_end = saw_close_token,
        };
    }

    const owned_name = try alloc.dupeZ(u8, name);
    errdefer alloc.free(owned_name);

    const owned_args = try alloc.dupeZ(u8, args);
    errdefer alloc.free(owned_args);

    const owned_options = try options.toOwnedSlice(alloc);
    errdefer alloc.free(owned_options);

    const owned_value = try alloc.dupeZ(u8, value);
    errdefer alloc.free(owned_value);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .myst_directive = .{
            .children = &.{},
            .name = owned_name,
            .args = owned_args,
            .options = owned_options,
            .value = owned_value,
        },
    };
    return .{
        .maybe_node = node,
        .should_end = saw_close_token,
    };
}

/// Parses a single option line for a MyST directive.
///
/// We only support the colon-bookends syntax.
fn parseMySTDirectiveOption(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !?ast.MySTDirective.Option {
    var did_parse = false;
    const checkpoint_index = self.it.checkpoint();
    defer if (!did_parse) {
        self.it.backtrack(checkpoint_index);
    };

    _ = try self.it.consume(scratch, &.{.colon}) orelse return null;
    const name_token = try self.it.consume(scratch, &.{.text}) orelse
        return null;
    _ = try self.it.consume(scratch, &.{.colon}) orelse return null;

    _ = try self.it.consumeWhitespace(scratch);

    var running_text = Io.Writer.Allocating.init(scratch);
    while (try self.it.peek(scratch)) |token| {
        switch (token.token_type) {
            .newline => break,
            else => {
                _ = try running_text.writer.write(token.lexeme);
                _ = try self.it.consume(scratch, &.{token.token_type});
            },
        }
    }

    _ = try self.it.consume(scratch, &.{.newline}) orelse return null;

    const owned_name = try alloc.dupeZ(u8, name_token.lexeme);
    errdefer alloc.free(owned_name);

    var owned_value: ?[:0]const u8 = null;
    if (running_text.written().len > 0) {
        owned_value = try alloc.dupeZ(u8, running_text.written());
        errdefer alloc.free(owned_value);
    }

    did_parse = true;
    return .{
        .name = owned_name,
        .value = owned_value,
    };
}

// Scanned text that could end parsing.
const EndingScanResult = struct {
    maybe_text_value: ?[]const u8 = null,
    should_end: bool = false,
};

/// Scan text for a paragraph.
///
/// Paragraph can start with almost anything. If the token could have been
/// parsed as something else, it would have been parsed already.
///
/// Returns the scanned text and also an indicator of whether parsing should
/// end. We need to return this indicator because we consume the CLOSE token
/// when it appears. (In a lazy continuation line, we need to consume the CLOSE
/// token to parse everything after it in the line.)
fn scanParagraphText(self: *Self, scratch: Allocator) !EndingScanResult {
    var running_text = Io.Writer.Allocating.init(scratch);
    var saw_close_token = false;

    const start_token = try self.it.peek(scratch) orelse return .{};
    _ = try self.it.consume(scratch, &.{start_token.token_type});
    _ = try running_text.writer.write(start_token.lexeme);

    const State = enum { continuing, maybe_end };
    fsm: switch (State.continuing) {
        .continuing => {
            const token = try self.it.peek(scratch) orelse break :fsm;
            switch (token.token_type) {
                .newline => {
                    _ = try self.it.consume(scratch, &.{.newline});
                    _ = try running_text.writer.write("\n");
                    continue :fsm .maybe_end;
                },
                .close => {
                    _ = try self.it.consume(scratch, &.{.close});
                    saw_close_token = true;
                    continue :fsm .maybe_end;
                },
                else => |t| {
                    _ = try self.it.consume(scratch, &.{t});
                    _ = try running_text.writer.write(token.lexeme);
                    continue :fsm .continuing;
                },
            }
        },
        .maybe_end => {
            const token = try self.it.peek(scratch) orelse break :fsm;
            switch (token.token_type) {
                .newline,
                .pound,
                .rule_star,
                .rule_underline,
                .rule_dash_with_whitespace,
                .rule_dash,
                .rule_equals,
                .backtick_fence,
                .tilde_fence,
                => {
                    // These tokens can interrupt a paragraph.
                    break :fsm;
                },
                .l_angle_bracket => {
                    // Interrupts a paragraph, but only if this isn't a type 7
                    // HTML block.
                    if (try self.it.peekAhead(scratch, 2)) |first_token| {
                        const maybe_tag_token = blk: {
                            if (first_token.token_type == .slash) {
                                if (try self.it.peekAhead(
                                    scratch,
                                    3,
                                )) |second_token| {
                                    if (second_token.token_type == .text) {
                                        break :blk second_token;
                                    }
                                    break :blk null;
                                } else {
                                    break :blk null;
                                }
                            } else if (first_token.token_type == .text) {
                                break :blk first_token;
                            } else {
                                break :blk null;
                            }
                        };
                        const tag_token = maybe_tag_token orelse break :fsm;
                        if (!isLiteralContentHTMLTagName(tag_token.lexeme) and
                            !isKnownHTMLTagName(tag_token.lexeme))
                        {
                            saw_close_token = false;
                            continue :fsm .continuing;
                        }
                    }

                    break :fsm;
                },
                .close => {
                    _ = try self.it.consume(scratch, &.{.close});
                    saw_close_token = true;
                    continue :fsm .maybe_end;
                },
                else => {
                    continue :fsm .continuing;
                },
            }
        },
    }

    const text_value = try running_text.toOwnedSlice();
    return .{
        .maybe_text_value = text_value,
        .should_end = saw_close_token,
    };
}

fn scanTextFallback(self: *Self, scratch: Allocator) ![]const u8 {
    const token = try self.it.peek(scratch) orelse return "";
    _ = try self.it.consume(scratch, &.{token.token_type});
    return token.lexeme;
}

/// Creates a paragraph node containing a single text node.
fn createParagraphNode(alloc: Allocator, text_content: []const u8) !*ast.Node {
    // Trim trailing newlines
    const trimmed = std.mem.trimEnd(u8, text_content, "\n");

    const text_node = try util.nodes.createTextNode(alloc, trimmed);
    errdefer text_node.deinit(alloc);

    const children = try alloc.dupe(*ast.Node, &.{text_node});
    errdefer alloc.free(children);

    const paragraph_node = try alloc.create(ast.Node);
    paragraph_node.* = .{
        .paragraph = .{
            .children = children,
        },
    };
    return paragraph_node;
}

/// Resolve token lexeme into actual string content for a block node.
///
/// This should only be used for strings that won't subsequently be parsed by
/// the inline parser.
fn resolveText(scratch: Allocator, token: BlockToken) ![]const u8 {
    const value = switch (token.token_type) {
        .text => try escape.strip(scratch, token.lexeme),
        else => token.lexeme,
    };
    return value;
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;
const LineReader = @import("../lex/LineReader.zig");
const BlockTokenizer = @import("../lex/BlockTokenizer.zig");
const TokenSliceStream = @import("../lex/iterator.zig").TokenSliceStream;

fn parseBlocksMd(md: []const u8, link_defs: *LinkDefMap) ![]*ast.Node {
    var reader: Io.Reader = .fixed(md);
    var line_buf: [512]u8 = undefined;
    const line_reader: LineReader = .{ .in = &reader, .buf = &line_buf };
    var tokenizer = BlockTokenizer.init(line_reader);
    var it = tokenizer.iterator();
    var parser: Self = .{ .it = &it };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const nodes = try parser.parse(testing.allocator, scratch, link_defs);
    return nodes;
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

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(4, nodes.len);

    const h1 = nodes[0];
    try testing.expectEqual(.heading, @as(ast.NodeType, h1.*));
    try testing.expectEqual(1, h1.heading.depth);
    const text_node = h1.heading.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
    try testing.expectEqualStrings(
        "This is a heading",
        text_node.text.value,
    );

    const p1 = nodes[1];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p1.*));

    const p2 = nodes[2];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p2.*));

    const p3 = nodes[3];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p3.*));
}

test "ATX heading with leading whitespace" {
    const md =
        \\ ### foo
        \\   # foo
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(2, nodes.len);

    const h1 = nodes[0];
    try testing.expectEqual(.heading, @as(ast.NodeType, h1.*));
    try testing.expectEqual(3, h1.heading.depth);

    const h2 = nodes[1];
    try testing.expectEqual(.heading, @as(ast.NodeType, h2.*));
    try testing.expectEqual(1, h2.heading.depth);
}

test "ATX heading with trailing pounds" {
    const md = "## foo ##    \n";

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const h1 = nodes[0];
    try testing.expectEqual(.heading, @as(ast.NodeType, h1.*));
    try testing.expectEqual(2, h1.heading.depth);
    const text_node = h1.heading.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
    try testing.expectEqualStrings(
        "foo",
        text_node.text.value,
    );
}

test "setext headings" {
    const md =
        \\foo
        \\===
        \\bar
        \\---
        \\bam
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(3, nodes.len);

    const h1 = nodes[0];
    try testing.expectEqual(.heading, @as(ast.NodeType, h1.*));
    try testing.expectEqual(1, h1.heading.depth);
    {
        const text_node = h1.heading.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
        try testing.expectEqualStrings(
            "foo",
            text_node.text.value,
        );
    }

    const h2 = nodes[1];
    try testing.expectEqual(.heading, @as(ast.NodeType, h2.*));
    try testing.expectEqual(2, h2.heading.depth);
    {
        const text_node = h2.heading.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
        try testing.expectEqualStrings(
            "bar",
            text_node.text.value,
        );
    }

    const p = nodes[2];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));
}

test "indented setext headings" {
    const md =
        \\   foo *bar*
        \\   ===
        \\ bim _bam_
        \\ ---
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(2, nodes.len);

    const h1 = nodes[0];
    try testing.expectEqual(.heading, @as(ast.NodeType, h1.*));
    try testing.expectEqual(1, h1.heading.depth);
    {
        const text_node = h1.heading.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
        try testing.expectEqualStrings(
            "foo *bar*",
            text_node.text.value,
        );
    }

    const h2 = nodes[1];
    try testing.expectEqual(.heading, @as(ast.NodeType, h2.*));
    try testing.expectEqual(2, h2.heading.depth);
    {
        const text_node = h2.heading.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
        try testing.expectEqualStrings(
            "bim _bam_",
            text_node.text.value,
        );
    }
}

test "paragraph can contain punctuation" {
    const md =
        \\# Heading containing "symbols" ([]<>)
        \\This is a "paragraph" that contains punctuation! (We don't want any
        \\of these symbols, like [, ], <, or >, to break the paragraph.)
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(2, nodes.len);

    const h = nodes[0];
    try testing.expectEqual(.heading, @as(ast.NodeType, h.*));
    try testing.expectEqual(1, h.heading.children.len);

    const p = nodes[1];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));
}

test "link reference definition" {
    const md =
        \\[checkout this cool link][foo]
        \\
        \\[foo]: /bar "baz bot"
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    // The link definition is added to the AST (even though it isn't rendered),
    // which is why we have two nodes.
    try testing.expectEqual(2, nodes.len);

    // Link should get parsed as a paragraph by the block parser; the inline
    // parser will later turn it into a link.
    const p = nodes[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));

    try testing.expectEqual(1, link_defs.count());

    const maybe_definition = try link_defs.get(testing.allocator, "foo");
    const definition = try util.testing.expectNonNull(maybe_definition);
    try testing.expectEqualStrings("foo", definition.label);
    try testing.expectEqualStrings("/bar", definition.url);
    try testing.expectEqualStrings("baz bot", definition.title);
}

test "indented code block" {
    const md =
        \\    def foo():
        \\        pass
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const code_node = nodes[0];
    try testing.expectEqual(.code, @as(ast.NodeType, code_node.*));
    try testing.expectEqualStrings(
        "def foo():\n    pass",
        code_node.code.value,
    );
    try testing.expectEqualStrings("", code_node.code.lang);
}

test "indented code block with tab" {
    const md = "  \t\tdef foo():\n  \t\t    pass\n";

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const code_node = nodes[0];
    try testing.expectEqual(.code, @as(ast.NodeType, code_node.*));
    try testing.expectEqualStrings(
        "\tdef foo():\n\t    pass",
        code_node.code.value,
    );
}

test "empty code fence" {
    const md =
        \\  ```
        \\```
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const code_node = nodes[0];
    try testing.expectEqual(.code, @as(ast.NodeType, code_node.*));
    try testing.expectEqualStrings(
        "",
        code_node.code.value,
    );
    try testing.expectEqualStrings("", code_node.code.lang);
}

test "code fence with info string" {
    const md =
        \\````  python
        \\def foo():
        \\    pass
        \\````
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const code_node = nodes[0];
    try testing.expectEqual(.code, @as(ast.NodeType, code_node.*));
    try testing.expectEqualStrings(
        "def foo():\n    pass",
        code_node.code.value,
    );
    try testing.expectEqualStrings(
        "python",
        code_node.code.lang,
    );
}

test "code fence with indentation" {
    const md =
        \\  ```python
        \\  def foo():
        \\      pass
        \\  ```
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const code_node = nodes[0];
    try testing.expectEqual(.code, @as(ast.NodeType, code_node.*));
    try testing.expectEqualStrings(
        "def foo():\n    pass",
        code_node.code.value,
    );
    try testing.expectEqualStrings(
        "python",
        code_node.code.lang,
    );
}

test "code fence with tab indentation" {
    // The `bar()` is indented using a single tab.
    // Given that the whole block is indented by three spaces, the tab should
    // get split such that `bar()` is preceded by a single space.
    const md = "   ```python\n   foo()\n\tbar()\n   ```\n";

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const code_node = nodes[0];
    try testing.expectEqual(.code, @as(ast.NodeType, code_node.*));
    try testing.expectEqualStrings(
        "foo()\n bar()",
        code_node.code.value,
    );
}

test "tilde code fence" {
    const md =
        \\~~~python
        \\def foo():
        \\    pass
        \\~~~
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const code_node = nodes[0];
    try testing.expectEqual(.code, @as(ast.NodeType, code_node.*));
    try testing.expectEqualStrings(
        "def foo():\n    pass",
        code_node.code.value,
    );
    try testing.expectEqualStrings(
        "python",
        code_node.code.lang,
    );
}

test "backtick MyST directive" {
    const md =
        \\```{foo}
        \\Hi, this is my directive.
        \\```
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const directive_node = nodes[0];
    try testing.expectEqual(.myst_directive, @as(ast.NodeType, directive_node.*));
    try testing.expectEqualStrings(
        "foo",
        directive_node.myst_directive.name,
    );
    try testing.expectEqualStrings(
        "Hi, this is my directive.",
        directive_node.myst_directive.value,
    );
}

test "colon MyST directive" {
    const md =
        \\:::{foo}
        \\Hi, this is my directive.
        \\:::
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const directive_node = nodes[0];
    try testing.expectEqual(.myst_directive, @as(ast.NodeType, directive_node.*));
    try testing.expectEqualStrings(
        "foo",
        directive_node.myst_directive.name,
    );
    try testing.expectEqualStrings(
        "Hi, this is my directive.",
        directive_node.myst_directive.value,
    );
}

test "MyST directive with indentation" {
    const md =
        \\   ```{foo}
        \\   def foo():
        \\       pass
        \\   ```
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const directive_node = nodes[0];
    try testing.expectEqual(.myst_directive, @as(ast.NodeType, directive_node.*));
    try testing.expectEqualStrings(
        "foo",
        directive_node.myst_directive.name,
    );
    try testing.expectEqualStrings(
        "def foo():\n    pass",
        directive_node.myst_directive.value,
    );
}

test "MyST directive with nested blocks" {
    // Note that the actual content of the directive isn't parsed until later.
    // This test just ensures we are correctly handling lines that look like
    // potential closing fences but aren't.
    const md =
        \\````{foo}
        \\# Bar
        \\This is baz.
        \\
        \\```python
        \\def foo():
        \\    pass
        \\```
        \\
        \\```{bar}
        \\bim
        \\```
        \\````
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const directive_node = nodes[0];
    try testing.expectEqual(.myst_directive, @as(ast.NodeType, directive_node.*));
    try testing.expectEqualStrings(
        "foo",
        directive_node.myst_directive.name,
    );
    try testing.expectEqualStrings(
        \\# Bar
        \\This is baz.
        \\
        \\```python
        \\def foo():
        \\    pass
        \\```
        \\
        \\```{bar}
        \\bim
        \\```
    ,
        directive_node.myst_directive.value,
    );
}

test "MyST directive with invalid name" {
    const md =
        \\```{foo bar}
        \\bim
        \\```
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const error_node = nodes[0];
    try testing.expectEqual(.myst_directive_error, @as(ast.NodeType, error_node.*));
    try testing.expect(error_node.myst_directive_error.message.len > 0);
}

test "MyST directive with whitespace around name" {
    const md =
        \\```{ foo }
        \\Hi, this is my directive.
        \\```
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const directive_node = nodes[0];
    try testing.expectEqual(.myst_directive, @as(ast.NodeType, directive_node.*));
    try testing.expectEqualStrings(
        "foo",
        directive_node.myst_directive.name,
    );
    try testing.expectEqualStrings(
        "Hi, this is my directive.",
        directive_node.myst_directive.value,
    );
}

test "MyST directive with args" {
    const md =
        \\```{foo} bar baz
        \\Hi, this is my directive.
        \\```
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const directive_node = nodes[0];
    try testing.expectEqual(.myst_directive, @as(ast.NodeType, directive_node.*));
    try testing.expectEqualStrings(
        "foo",
        directive_node.myst_directive.name,
    );
    try testing.expectEqualStrings(
        "bar baz",
        directive_node.myst_directive.args,
    );
    try testing.expectEqualStrings(
        "Hi, this is my directive.",
        directive_node.myst_directive.value,
    );
}

test "MyST directive with closing backtick fence on same line not allowed" {
    const md =
        \\```{foo} bar```
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const p_node = nodes[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));
}

test "MyST directive with options" {
    const md =
        \\```{foo}
        \\:bar:
        \\:baz: bam
        \\Hi, this is my directive.
        \\```
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const directive_node = nodes[0];
    try testing.expectEqual(.myst_directive, @as(
        ast.NodeType,
        directive_node.*,
    ));
    try testing.expectEqualStrings(
        "foo",
        directive_node.myst_directive.name,
    );
    try testing.expectEqualStrings(
        "Hi, this is my directive.",
        directive_node.myst_directive.value,
    );

    const opt0 = directive_node.myst_directive.options[0];
    try testing.expectEqualStrings("bar", opt0.name);
    try testing.expect(opt0.value == null);

    const opt1 = directive_node.myst_directive.options[1];
    try testing.expectEqualStrings("baz", opt1.name);
    try testing.expectEqualStrings("bam", opt1.value.?);
}

fn parseBlocksTokens(
    tokens: []const BlockToken,
    link_defs: *LinkDefMap,
) ![]*ast.Node {
    var stream = TokenSliceStream(BlockTokenType).init(tokens);
    var it = stream.iterator();
    var parser: Self = .{ .it = &it };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const nodes = try parser.parse(testing.allocator, scratch, link_defs);
    return nodes;
}

// This is a case where the CLOSE token gets consumed as the paragraph is
// parsed.
test "close token in paragraph" {
    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksTokens(&.{
        .{
            .token_type = .text,
            .lexeme = "foo",
        },
        .{
            .token_type = .newline,
        },
        .{
            .token_type = .close,
        },
        .{
            .token_type = .text,
            .lexeme = "bar",
        },
        .{
            .token_type = .newline,
        },
    }, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const p = nodes[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));
    try testing.expectEqual(1, p.paragraph.children.len);

    const txt = p.paragraph.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, txt.*));
    try testing.expectEqualStrings(
        "foo\nbar",
        txt.text.value,
    );
}

test "close token before thematic break" {
    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksTokens(&.{
        .{
            .token_type = .text,
            .lexeme = "foo",
        },
        .{
            .token_type = .newline,
        },
        .{
            .token_type = .close,
        },
        .{
            .token_type = .rule_star,
        },
        .{
            .token_type = .newline,
        },
    }, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const p = nodes[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));
    try testing.expectEqual(1, p.paragraph.children.len);

    const txt = p.paragraph.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, txt.*));
    try testing.expectEqualStrings("foo", txt.text.value);
}

// !! DIFFERENT FROM REFERENCE MYST PARSER !!
//
// The JS MyST parser will parse this whole token stream as a single paragraph.
test "close token in setext heading" {
    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksTokens(&.{
        .{
            .token_type = .text,
            .lexeme = "foo",
        },
        .{
            .token_type = .newline,
        },
        .{
            .token_type = .close,
        },
        .{
            .token_type = .rule_equals,
            .lexeme = "===",
        },
        .{
            .token_type = .newline,
        },
    }, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const p = nodes[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));
    try testing.expectEqual(1, p.paragraph.children.len);

    const txt = p.paragraph.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, txt.*));
    try testing.expectEqualStrings("foo", txt.text.value);
}

// This is a case where the parser has to detect the close token in the body of
// parse() because it comes immediately after another block has been parsed.
//
// > # foo
// bar
test "close token after atx heading" {
    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksTokens(&.{
        .{
            .token_type = .pound,
            .lexeme = "#",
        },
        .{
            .token_type = .text,
            .lexeme = "foo",
        },
        .{
            .token_type = .newline,
        },
        .{
            .token_type = .close,
        },
        .{
            .token_type = .text,
            .lexeme = "bar",
        },
        .{
            .token_type = .newline,
        },
    }, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const h = nodes[0];
    try testing.expectEqual(.heading, @as(ast.NodeType, h.*));
    try testing.expectEqual(1, h.heading.children.len);

    const txt = h.heading.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, txt.*));
    try testing.expectEqualStrings("foo", txt.text.value);
}

test "close token in MyST directive" {
    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksTokens(&.{
        .{
            .token_type = .colon_fence,
            .lexeme = ":::",
        },
        .{ .token_type = .l_brace },
        .{
            .token_type = .text,
            .lexeme = "foo",
        },
        .{ .token_type = .r_brace },
        .{ .token_type = .newline },
        .{
            .token_type = .text,
            .lexeme = "bar",
        },
        .{ .token_type = .newline },
        .{ .token_type = .close },
        .{
            .token_type = .text,
            .lexeme = "baz",
        },
        .{ .token_type = .newline },
    }, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const directive_node = nodes[0];
    try testing.expectEqual(.myst_directive, @as(ast.NodeType, directive_node.*));
    try testing.expectEqualStrings(
        "bar",
        directive_node.myst_directive.value,
    );
}

test "HTML literal content tag" {
    const md =
        \\<textarea>
        \\Hello, foobar
        \\
        \\That was an empty line.
        \\</textarea>
        \\<pre>
        \\def foo():
        \\  pass</pre>
        \\<script>console.log("Hello");</script>
        \\<style></style>
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(4, nodes.len);

    const html_node_1 = nodes[0];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node_1.*));
    try testing.expectEqualStrings(
        "<textarea>\nHello, foobar\n\nThat was an empty line.\n</textarea>",
        html_node_1.html.value,
    );
    const html_node_2 = nodes[1];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node_2.*));
    try testing.expectEqualStrings(
        "<pre>\ndef foo():\n  pass</pre>",
        html_node_2.html.value,
    );
    const html_node_3 = nodes[2];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node_3.*));
    try testing.expectEqualStrings(
        "<script>console.log(\"Hello\");</script>",
        html_node_3.html.value,
    );
    const html_node_4 = nodes[3];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node_4.*));
    try testing.expectEqualStrings(
        "<style></style>",
        html_node_4.html.value,
    );
}

test "HTML comment" {
    const md =
        \\<!-- foobar -->
        \\<!--
        \\bimbat zam
        \\-->
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(2, nodes.len);

    const html_node_1 = nodes[0];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node_1.*));
    try testing.expectEqualStrings(
        "<!-- foobar -->",
        html_node_1.html.value,
    );

    const html_node_2 = nodes[1];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node_2.*));
    try testing.expectEqualStrings(
        "<!--\nbimbat zam\n-->",
        html_node_2.html.value,
    );
}

test "HTML comment with trailing text" {
    const md =
        \\<!--
        \\bimbat zam
        \\--> foobar
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const html_node = nodes[0];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node.*));
    try testing.expectEqualStrings(
        "<!--\nbimbat zam\n--> foobar",
        html_node.html.value,
    );
}

test "HTML comment at container close" {
    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksTokens(&.{
        .{ .token_type = .l_angle_bracket },
        .{ .token_type = .exclamation_mark },
        .{ .token_type = .hyphen },
        .{ .token_type = .hyphen },
        .{
            .token_type = .text,
            .lexeme = "foo",
        },
        .{ .token_type = .close },
    }, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const html_node = nodes[0];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node.*));
    try testing.expectEqualStrings(
        "<!--foo",
        html_node.html.value,
    );
}

// All types of HTML blocks except type 7 can interrupt a paragraph.
test "HTML comment interrupts paragraphs" {
    const md =
        \\Hi this is a paragraph.
        \\<!-- this is a comment on the very next line -->
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(2, nodes.len);

    const p_node = nodes[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));

    const html_node = nodes[1];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node.*));
    try testing.expectEqualStrings(
        "<!-- this is a comment on the very next line -->",
        html_node.html.value,
    );
}

test "HTML processing instruction" {
    const md =
        \\<?xml-stylesheet type="text/xsl" href="style.xsl"?>
        \\<?
        \\bimbat zam
        \\?>
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(2, nodes.len);

    const html_node_1 = nodes[0];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node_1.*));
    try testing.expectEqualStrings(
        "<?xml-stylesheet type=\"text/xsl\" href=\"style.xsl\"?>",
        html_node_1.html.value,
    );

    const html_node_2 = nodes[1];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node_2.*));
    try testing.expectEqualStrings(
        "<?\nbimbat zam\n?>",
        html_node_2.html.value,
    );
}

test "HTML processing instruction with trailing text" {
    const md =
        \\<?
        \\bimbat zam
        \\?> foobar
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const html_node = nodes[0];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node.*));
    try testing.expectEqualStrings(
        "<?\nbimbat zam\n?> foobar",
        html_node.html.value,
    );
}

test "HTML processing instruction at container close" {
    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksTokens(&.{
        .{ .token_type = .l_angle_bracket },
        .{ .token_type = .question_mark },
        .{
            .token_type = .text,
            .lexeme = "foo",
        },
        .{ .token_type = .close },
    }, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const html_node = nodes[0];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node.*));
    try testing.expectEqualStrings(
        "<?foo",
        html_node.html.value,
    );
}

test "HTML processing instruction interrupts paragraphs" {
    const md =
        \\Hi this is a paragraph.
        \\<?xml-stylesheet foobar ?>
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(2, nodes.len);

    const p_node = nodes[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));

    const html_node = nodes[1];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node.*));
    try testing.expectEqualStrings(
        "<?xml-stylesheet foobar ?>",
        html_node.html.value,
    );
}

test "HTML declaration" {
    const md =
        \\<!DOCTYPE html>
        \\<!foo
        \\bimbat zam
        \\>
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(2, nodes.len);

    const html_node_1 = nodes[0];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node_1.*));
    try testing.expectEqualStrings("<!DOCTYPE html>", html_node_1.html.value);

    const html_node_2 = nodes[1];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node_2.*));
    try testing.expectEqualStrings(
        "<!foo\nbimbat zam\n>",
        html_node_2.html.value,
    );
}

test "HTML declaration with trailing text" {
    const md =
        \\<!foo
        \\bimbat zam
        \\> foobar
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const html_node = nodes[0];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node.*));
    try testing.expectEqualStrings(
        "<!foo\nbimbat zam\n> foobar",
        html_node.html.value,
    );
}

test "HTML declaration at container close" {
    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksTokens(&.{
        .{ .token_type = .l_angle_bracket },
        .{ .token_type = .exclamation_mark },
        .{
            .token_type = .text,
            .lexeme = "foo",
        },
        .{ .token_type = .close },
    }, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const html_node = nodes[0];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node.*));
    try testing.expectEqualStrings(
        "<!foo",
        html_node.html.value,
    );
}

test "HTML declaration interrupts paragraphs" {
    const md =
        \\Hi this is a paragraph.
        \\<!DOCTYPE html>
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(2, nodes.len);

    const p_node = nodes[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));

    const html_node = nodes[1];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node.*));
    try testing.expectEqualStrings(
        "<!DOCTYPE html>",
        html_node.html.value,
    );
}

test "HTML CDATA" {
    const md =
        \\<![CDATA[foobar]]>
        \\<![CDATA[
        \\bimbat zam
        \\]]>
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(2, nodes.len);

    const html_node_1 = nodes[0];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node_1.*));
    try testing.expectEqualStrings(
        "<![CDATA[foobar]]>",
        html_node_1.html.value,
    );

    const html_node_2 = nodes[1];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node_2.*));
    try testing.expectEqualStrings(
        "<![CDATA[\nbimbat zam\n]]>",
        html_node_2.html.value,
    );
}

test "HTML CDATA with trailing text" {
    const md =
        \\<![CDATA[
        \\bimbat zam
        \\]]> foobar
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const html_node = nodes[0];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node.*));
    try testing.expectEqualStrings(
        "<![CDATA[\nbimbat zam\n]]> foobar",
        html_node.html.value,
    );
}

test "HTML CDATA at container close" {
    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksTokens(&.{
        .{ .token_type = .l_angle_bracket },
        .{ .token_type = .exclamation_mark },
        .{ .token_type = .l_square_bracket },
        .{
            .token_type = .text,
            .lexeme = "CDATA",
        },
        .{ .token_type = .l_square_bracket },
        .{
            .token_type = .text,
            .lexeme = "foo",
        },
        .{ .token_type = .close },
    }, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const html_node = nodes[0];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node.*));
    try testing.expectEqualStrings(
        "<![CDATA[foo",
        html_node.html.value,
    );
}

test "HTML CDATA interrupts paragraphs" {
    const md =
        \\Hi this is a paragraph.
        \\<![CDATA[foobar]]>
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(2, nodes.len);

    const p_node = nodes[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));

    const html_node = nodes[1];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node.*));
    try testing.expectEqualStrings(
        "<![CDATA[foobar]]>",
        html_node.html.value,
    );
}

test "HTML known-tag" {
    const md =
        \\<article>
        \\
        \\<div class="foo">
        \\<p>Hello</p>
        \\</div>
        \\
        \\<table>
        \\<tr></tr>
        \\</table>
        \\
        \\</article>
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(4, nodes.len);

    const html_node_1 = nodes[0];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node_1.*));
    try testing.expectEqualStrings(
        "<article>",
        html_node_1.html.value,
    );

    const html_node_2 = nodes[1];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node_2.*));
    try testing.expectEqualStrings(
        "<div class=\"foo\">\n<p>Hello</p>\n</div>",
        html_node_2.html.value,
    );

    const html_node_3 = nodes[2];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node_3.*));
    try testing.expectEqualStrings(
        "<table>\n<tr></tr>\n</table>",
        html_node_3.html.value,
    );

    const html_node_4 = nodes[3];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node_4.*));
    try testing.expectEqualStrings(
        "</article>",
        html_node_4.html.value,
    );
}

test "HTML known-tag at container close" {
    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksTokens(&.{
        .{
            .token_type = .l_angle_bracket,
            .lexeme = "<",
        },
        .{
            .token_type = .text,
            .lexeme = "div",
        },
        .{
            .token_type = .r_angle_bracket,
            .lexeme = ">",
        },
        .{ .token_type = .close },
    }, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const html_node = nodes[0];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node.*));
    try testing.expectEqualStrings(
        "<div>",
        html_node.html.value,
    );
}

test "HTML unknown tag" {
    const md =
        \\<foobar>
        \\<p>Hello</p>
        \\</foobar>
        \\
        \\Bim bam.
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(2, nodes.len);

    const html_node = nodes[0];
    try testing.expectEqual(.html, @as(ast.NodeType, html_node.*));
    try testing.expectEqualStrings(
        "<foobar>\n<p>Hello</p>\n</foobar>",
        html_node.html.value,
    );

    const p_node = nodes[1];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));
}

// These HTML tags should get parsed by the inline parser (and appear within
// the paragraph) and not the block parser.
//
// "This restriction is intended to prevent unwanted interpretation of long
// tags inside a wrapped paragraph as starting HTML blocks."
test "HTML unknown tag cannot interrupt paragraph" {
    const md =
        \\The tag name is long so it ends up alone on the next line
        \\<supercalifragaliciousexpialidocious>
        \\</supercalifragaliciousexpialidocious> even though this is supposed
        \\to be inline HTML.
        \\
    ;

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const nodes = try parseBlocksMd(md, &link_defs);
    defer {
        for (nodes) |node| {
            node.deinit(testing.allocator);
        }
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(1, nodes.len);

    const p_node = nodes[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));

    // After the inline parser parses this, the paragraph will have more
    // children. But when output from the LeafBlockParser, all paragraph
    // content is still a single blob of text.
    try testing.expectEqual(1, p_node.paragraph.children.len);

    const text_node = p_node.paragraph.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
    try testing.expectEqualStrings(
        "The tag name is long so it ends up alone on the next line\n" ++
            "<supercalifragaliciousexpialidocious>\n" ++
            "</supercalifragaliciousexpialidocious> even though this is " ++
            "supposed\nto be inline HTML.",
        text_node.text.value,
    );
}

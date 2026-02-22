//! Parser that handles leaf blocks.
//!
//! Parser pulls tokens from the iterator as needed. The tokens are stored in
//! an array list. The array list is cleared of consumed tokens as each block is
//! successfully parsed.
//!
//! This is a recursive-descent parser with backtracking.
//!
//! In addition to the regular block tokens, this parser can also handle
//! special "CLOSE" tokens. A CLOSE token indicates that the parser should not
//! parse any more blocks. This is similar to but different from the actual end
//! of the token stream: Whereas the end of the stream obviously means that the
//! parser can't parse ANYTHING more, the CLOSE token allows the parser to keep
//! parsing an open paragraph but nothing else. (CLOSE tokens are used to
//! implement lazy continuation lines.)

const std = @import("std");
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const ArrayList = std.ArrayList;

const ast = @import("ast.zig");
const BlockToken = @import("../lex/tokens.zig").BlockToken;
const BlockTokenType = @import("../lex/tokens.zig").BlockTokenType;
const cmark = @import("../cmark/cmark.zig");
const escape = @import("escape.zig");
const LinkDefMap = @import("link_defs.zig").LinkDefMap;
const link_label_max_chars = @import("link_defs.zig").label_max_chars;
const logger = @import("../logging.zig").logger;
const NodeList = @import("NodeList.zig");
const TokenIterator = @import("../lex/iterator.zig").TokenIterator;
const util = @import("../util/util.zig");

const Error = error{
    LineTooLong,
    ReadFailed,
    WriteFailed,
} || Allocator.Error;

const close_token_panic_msg = "encountered unexpected CLOSE token";

it: *TokenIterator(BlockTokenType),

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
            break; // end of parsing in response to CLOSE token
        }

        if (try self.parseIndentedCode(alloc, scratch)) |code| {
            try children.append(code);
            continue;
        }

        if (try self.parseFencedCode(alloc, scratch)) |code| {
            try children.append(code);
            continue;
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
            logParseAttempt("blank line", true);
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
        logParseAttempt("parseATXHeading()", did_parse);
        if (!did_parse) {
            self.it.backtrack(checkpoint_index);
        }
    }

    // Handle allowed leading whitespace
    _ = try self.it.consume(scratch, &.{.whitespace});

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
                while (try self.it.consume(scratch, &.{.whitespace})) |_| {}
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
            }
        }
    } else @panic(util.safety.loop_bound_panic_msg);

    _ = try self.it.consume(scratch, &.{.newline}) orelse return null;

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
        logParseAttempt("parseSetextHeading()", did_parse);
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
                .newline, .pound, .rule_star, .rule_underline,
                .rule_dash_with_whitespace, .rule_dash, .rule_equals,
                .backtick_fence, .tilde_fence => {
                    // These tokens can interrupt a paragraph. The text before
                    // the underline in a setext heading would otherwise be
                    // parsed as a paragraph.
                    break :fsm;
                },
                .close => return null,
                else => continue :fsm .open,
            }
        }
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
        const text_node = try createTextNode(alloc, trimmed_inner);
        break :blk try alloc.dupe(*ast.Node, &.{ text_node });
    };
    errdefer alloc.free(children);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .heading = .{
            .depth = depth,
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
    var did_parse = false;
    defer logParseAttempt("parseThematicBreak()", did_parse);

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
    node.* = .{ .thematic_break = .{} };
    did_parse = true;
    return node;
}

fn parseIndentedCode(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !?*ast.Node {
    var did_parse = false;
    defer logParseAttempt("parseIndentedCode()", did_parse);

    // Block has to start with an indent.
    // Consume token later; this is just a check for an easy bail condition.
    const block_start = try self.it.peek(scratch) orelse return null;
    if (block_start.token_type != .indent) {
        return null;
    }

    // Parse one or more indented lines
    var lines: ArrayList([]const u8) = .empty;
    block_loop: for (0..util.safety.loop_bound) |_| {
        var line = Io.Writer.Allocating.init(scratch);

        const line_start = try self.it.peek(scratch) orelse break :block_loop;
        switch (line_start.token_type) {
            .indent => {
                // Parse a single indented line
                _ = try self.it.consume(scratch, &.{.indent});
                line_loop: while (try self.it.peek(scratch)) |next| {
                    if (next.token_type == .newline) {
                        break :line_loop;
                    }

                    _ = try self.it.consume(scratch, &.{next.token_type});
                    try line.writer.print("{s}", .{next.lexeme});
                }

                _ = try self.it.consume(scratch, &.{.newline});
            },
            .newline => { // newline doesn't end indented block
                _ = try self.it.consume(scratch, &.{.newline});
                try line.writer.print("", .{});
            },
            .whitespace => {
                const lookahead_checkpoint_index = self.it.checkpoint();
                while (try self.it.consume(scratch, &.{.whitespace})) |_| {}
                if (try self.it.peek(scratch)) |token| {
                    if (token.token_type == .newline) {
                        _ = try self.it.consume(scratch, &.{.newline});
                        try line.writer.print("", .{});
                    } else {
                        // Unindented, non-blank line does end block
                        self.it.backtrack(lookahead_checkpoint_index);
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
    did_parse = true;
    return node;
}

/// https://spec.commonmark.org/0.30/#fenced-code-blocks
fn parseFencedCode(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.it.checkpoint();
    defer if (!did_parse) {
        self.it.backtrack(checkpoint_index);
    };

    // Opening code fence line
    const maybe_leading_whitespace = try self.it.consume(scratch, &.{.whitespace});
    const indentation: usize =
        if (maybe_leading_whitespace) |whitespace|
            whitespace.lexeme.len
        else
            0;

    const open_fence = try self.it.consume(
        scratch,
        &.{.backtick_fence, .tilde_fence},
    ) orelse return null;

    const info_lang = blk: {
        // Whitespace allowed between fence and info string
        _ = try self.it.consume(scratch, &.{.whitespace});

        // First text token is treated as language
        const text = try self.it.consume(scratch, &.{.text}) orelse break :blk "";
        if (
            open_fence.token_type == .backtick_fence
            and std.mem.count(u8, text.lexeme, "`") > 0
        ) {
            return null;
        }

        // Following tokens are allowed, but ignored
        while (try self.it.peek(scratch)) |next| {
            switch (next.token_type) {
                .text => {
                    if (
                        open_fence.token_type == .backtick_fence
                        and std.mem.count(u8, next.lexeme, "`") > 0
                    ) {
                        return null;
                    }
                    _ = try self.it.consume(scratch, &.{.text});
                },
                .newline => break,
                .backtick_fence => {
                    if (open_fence.token_type == .backtick_fence) {
                        return null;
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
    _ = try self.it.consume(scratch, &.{.newline}) orelse return null;

    // Block content
    var content = Io.Writer.Allocating.init(scratch);
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
            .whitespace => |t| {
                if (try self.peekClosingFence(scratch, open_fence)) {
                    break :loop;
                }

                _ = try self.it.consume(scratch, &.{t});
                const start = std.mem.min(
                    usize,
                    &.{indentation, line_start_token.lexeme.len},
                );
                const value = line_start_token.lexeme[start..];
                _ = try content.writer.write(value);
            },
            .indent => {
                _ = try self.it.consume(scratch, &.{.indent});
                const start = std.mem.min(
                    usize,
                    &.{indentation, line_start_token.lexeme.len},
                );
                const value = line_start_token.lexeme[start..];
                _ = try content.writer.write(value);
            },
            .newline => {
                // TODO: all tokens should have lexemes
                _ = try self.it.consume(scratch, &.{.newline});
                _ = try content.writer.write("\n");
            },
            else => |t| {
                _ = try self.it.consume(scratch, &.{t});
                _ = try content.writer.write(line_start_token.lexeme);
            }
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

    // Closing code fence line
    // Not needed if file ends
    _ = try self.it.consume(scratch, &.{.whitespace});
    if (try self.it.consume(scratch, &.{open_fence.token_type})) |_| {
        _ = try self.it.consume(scratch, &.{.whitespace});
        _ = try self.it.consume(scratch, &.{.newline}) orelse return null;
    }

    // Myst tests require trailing newline to be trimmed for AST, even though it
    // should be added back when rendered as HTML.
    // https://spec.commonmark.org/0.30/#example-119
    const trimmed = std.mem.trimEnd(u8, content.written(), "\n");

    const value = try alloc.dupe(u8, trimmed);
    errdefer alloc.free(value);
    const lang = try alloc.dupe(u8, info_lang);
    errdefer alloc.free(lang);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .code = .{
            .value = value,
            .lang = lang,
        },
    };
    did_parse = true;
    return node;
}

/// Returns true if the next tokens can be parsed as the closing fence of a
/// fenced code block.
fn peekClosingFence(
    self: *Self,
    scratch: Allocator,
    open_fence: BlockToken,
) !bool {
    const checkpoint_index = self.it.checkpoint();
    defer self.it.backtrack(checkpoint_index);

    _ = try self.it.consume(scratch, &.{.whitespace});

    const close_fence = try self.it.consume(
        scratch,
        &.{open_fence.token_type},
    ) orelse return false;
    if (close_fence.lexeme.len < open_fence.lexeme.len) {
        return false;
    }

    _ = try self.it.consume(scratch, &.{.whitespace});
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
        logParseAttempt("parseLinkReferenceDefinition()", did_parse);
        if (!did_parse) {
            self.it.backtrack(checkpoint_index);
        }
    }

    // consume allowed leading whitespace
    _ = try self.it.consume(scratch, &.{.whitespace});

    const scanned_label = try self.scanLinkDefLabel(scratch) orelse return null;
    _ = try self.it.consume(scratch, &.{.colon}) orelse return null;

    // whitespace allowed and up to one newline
    var seen_newline = false;
    while (try self.it.consume(scratch, &.{
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
    const escaped_url = try escape.copyEscape(scratch, scanned_url);
    const url = try cmark.uri.normalize(alloc, scratch, escaped_url);
    defer if (!did_parse) {
        alloc.free(url);
    };

    // whitespace allowed and up to one newline
    var seen_any_separating_whitespace = false;
    seen_newline = false;
    while (try self.it.peek(scratch)) |token| {
        switch (token.token_type) {
            .indent, .whitespace => |t| {
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
        _ = try self.it.consume(scratch, &.{.whitespace});

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
            .whitespace => {
                _ = try self.it.consume(scratch, &.{.whitespace});
                _ = try running_text.writer.write(token.lexeme);
            },
            .newline => {
                _ = try self.it.consume(scratch, &.{.newline});
                _ = try running_text.writer.write(" ");
            },
            .l_square_bracket => return null,
            .r_square_bracket => break,
            .text => {
                saw_non_blank = true;
                _ = try self.it.consume(scratch, &.{.text});
                const value = try resolveText(scratch, token);
                _ = try running_text.writer.write(value);
            },
            else => |t| {
                saw_non_blank = true;
                _ = try self.it.consume(scratch, &.{t});
                const value = try resolveText(scratch, token);
                _ = try running_text.writer.write(value);
            },
        }
    }

    _ = try self.it.consume(
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
                .indent, .rule_star, .rule_underline, .rule_dash_with_whitespace,
                .rule_dash, .rule_equals, .backtick_fence,
                .tilde_fence => return null,
                .text, .pound, .whitespace, .colon, .l_square_bracket,
                .r_square_bracket, .l_paren, .r_paren, .double_quote,
                .single_quote => |t| {
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
                .newline, .whitespace => break,
                .indent, .rule_star, .rule_underline, .rule_dash_with_whitespace,
                .rule_dash, .rule_equals, .backtick_fence,
                .tilde_fence => return null,
                .text, .pound, .colon, .l_square_bracket, .r_square_bracket,
                .l_angle_bracket, .r_angle_bracket, .double_quote,
                .single_quote => |t| {
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
        &.{.l_paren, .single_quote, .double_quote},
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
            .whitespace => {
                _ = try self.it.consume(scratch, &.{.whitespace});
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

const ParagraphResult = struct {
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
fn scanParagraphText(self: *Self, scratch: Allocator) !ParagraphResult {
    var running_text = Io.Writer.Allocating.init(scratch);
    var should_end = false;

    const start_token = try self.it.peek(scratch) orelse return .{};
    _ = try self.it.consume(scratch, &.{start_token.token_type});
    _ = try running_text.writer.write(start_token.lexeme);

    const State = enum { open, maybe_close };
    fsm: switch (State.open) {
        .open => {
            const token = try self.it.peek(scratch) orelse break :fsm;
            switch (token.token_type) {
                .newline => {
                    _ = try self.it.consume(scratch, &.{.newline});
                    _ = try running_text.writer.write("\n");
                    continue :fsm .maybe_close;
                },
                .close => {
                    _ = try self.it.consume(scratch, &.{.close});
                    continue :fsm .maybe_close;
                },
                else => |t| {
                    _ = try self.it.consume(scratch, &.{t});
                    _ = try running_text.writer.write(token.lexeme);
                    continue :fsm .open;
                },
            }
        },
        .maybe_close => {
            const token = try self.it.peek(scratch) orelse break :fsm;
            switch (token.token_type) {
                .newline, .pound, .rule_star, .rule_underline,
                .rule_dash_with_whitespace, .rule_dash, .rule_equals,
                .backtick_fence, .tilde_fence => {
                    // These tokens can interrupt a paragraph.
                    break :fsm;
                },
                .close => {
                    _ = try self.it.consume(scratch, &.{.close});
                    should_end = true;
                    continue :fsm .maybe_close;
                },
                else => {
                    should_end = false;
                    continue :fsm .open;
                },
            }
        },
    }

    const text_value = try running_text.toOwnedSlice();
    return .{
        .maybe_text_value = text_value,
        .should_end = should_end,
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

    const text_node = try createTextNode(alloc, trimmed);
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

/// Creates a text node with the given text value.
///
/// The value is copied and owned by the returned node.
fn createTextNode(alloc: Allocator, value: []const u8) !*ast.Node {
    const copy = try alloc.dupe(u8, value);
    errdefer alloc.free(copy);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .text = .{
            .value = copy,
        },
    };
    return node;
}

/// Resolve token lexeme into actual string content for a block node.
///
/// This should only be used for strings that won't subsequently be parsed by
/// the inline parser.
fn resolveText(scratch: Allocator, token: BlockToken) ![]const u8 {
    const value = switch (token.token_type) {
        .text => try escape.copyEscape(scratch, token.lexeme),
        else => token.lexeme,
    };
    return value;
}

fn logParseAttempt(comptime name: []const u8, did_parse: bool) void {
    if (did_parse) {
        logger.debug("LeafBlockParser.{s} SUCCESS", .{name});
    } else {
        logger.debug("LeafBlockParser.{s} FAIL", .{name});
    }
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
    try testing.expectEqualStrings("This is a heading", text_node.text.value);

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
    try testing.expectEqualStrings("foo", text_node.text.value);
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
        try testing.expectEqualStrings("foo", text_node.text.value);
    }

    const h2 = nodes[1];
    try testing.expectEqual(.heading, @as(ast.NodeType, h2.*));
    try testing.expectEqual(2, h2.heading.depth);
    {
        const text_node = h2.heading.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
        try testing.expectEqualStrings("bar", text_node.text.value);
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
        try testing.expectEqualStrings("foo *bar*", text_node.text.value);
    }

    const h2 = nodes[1];
    try testing.expectEqual(.heading, @as(ast.NodeType, h2.*));
    try testing.expectEqual(2, h2.heading.depth);
    {
        const text_node = h2.heading.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
        try testing.expectEqualStrings("bim _bam_", text_node.text.value);
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
    try testing.expectEqualStrings("", code_node.code.value);
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
    try testing.expectEqualStrings("python", code_node.code.lang);
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
    try testing.expectEqualStrings("python", code_node.code.lang);
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
    try testing.expectEqualStrings("python", code_node.code.lang);
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
    try testing.expectEqualStrings("foo\nbar", txt.text.value);
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

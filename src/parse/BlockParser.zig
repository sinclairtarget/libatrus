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
const logger = @import("../logging.zig").logger;
const NodeList = @import("NodeList.zig");
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
    var children = NodeList.init(alloc, scratch, createParagraphNode);
    errdefer {
        for (children.items()) |child| {
            child.deinit(alloc);
        }
        children.deinit();
    }

    var link_defs: LinkDefMap = .empty;
    errdefer link_defs.deinit(alloc);

    for (0..util.safety.loop_bound) |_| { // could hit if we forget to consume tokens
        _ = try self.peek(scratch) orelse break;

        if (self.token_index > 0) {
            self.clear_consumed_tokens();
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

        if (try self.parseLinkReferenceDefinition(alloc, scratch)) |link_def| {
            try link_defs.add(alloc, &link_def.definition);
            try children.append(link_def);
            continue;
        }

        // blank lines
        if (try self.consume(scratch, &.{.newline}) != null) {
            logParseAttempt("blank line", true);
            try children.flush(); // Blank lines close paragraphs
            continue;
        }

        if (try self.parseSetextHeading(alloc, scratch)) |heading| {
            try children.append(heading);
            continue;
        }

        // Parse paragraph text
        if (try self.scanParagraphText(scratch)) |text_value| {
            try children.appendText(text_value);
            continue;
        }

        // Parse paragraph text (last resort)
        const text_value = try self.scanTextFallback(scratch);
        if (text_value.len > 0) {
            try children.appendText(text_value);
            continue;
        }

        @panic("unable to parse block token");
    } else @panic(util.safety.loop_bound_panic_msg);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .root = .{
            .children = try children.toOwnedSlice(),
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
    defer {
        logParseAttempt("parseATXHeading()", did_parse);
        if (!did_parse) {
            self.backtrack(checkpoint_index);
        }
    }

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
                        _ = try inner.writer.write(current.lexeme);
                        self.backtrack(lookahead_checkpoint_index);
                    }
                }
            },
            .newline => break,
            else => {
                _ = try inner.writer.write(current.lexeme);
                _ = try self.consume(scratch, &.{current.token_type});
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

/// Parses a setext heading.
///
/// Will parse more than a setext heading if you let it... best to call this
/// last, with low precedence.
fn parseSetextHeading(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer {
        logParseAttempt("parseSetextHeading()", did_parse);
        if (!did_parse) {
            self.backtrack(checkpoint_index);
        }
    }

    var inner = Io.Writer.Allocating.init(scratch);

    const State = enum { open, maybe_close };
    fsm: switch (State.open) {
        .open => {
            const token = try self.peek(scratch) orelse break :fsm;
            switch (token.token_type) {
                .newline => {
                    _ = try self.consume(scratch, &.{.newline});
                    _ = try inner.writer.write("\n");
                    continue :fsm .maybe_close;
                },
                else => |t| {
                    _ = try self.consume(scratch, &.{t});
                    _ = try inner.writer.write(token.lexeme);
                    continue :fsm .open;
                },
            }
        },
        .maybe_close => {
            const token = try self.peek(scratch) orelse break :fsm;
            switch (token.token_type) {
                .newline, .pound, .rule_star, .rule_underline,
                .rule_dash_with_whitespace, .rule_dash, .rule_equals,
                .backtick_fence, .tilde_fence => {
                    // These tokens can interrupt a paragraph.
                    break :fsm;
                },
                else => continue :fsm .open,
            }
        }
    }

    const depth: u8 = blk: {
        if (try self.consume(scratch, &.{.rule_equals})) |_| {
            break :blk 1;
        } else if (try self.consume(scratch, &.{.rule_dash})) |_| {
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
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    // Opening code fence line
    const maybe_leading_whitespace = try self.consume(scratch, &.{.whitespace});
    const indentation: usize =
        if (maybe_leading_whitespace) |whitespace|
            whitespace.lexeme.len
        else
            0;

    const open_fence = try self.consume(
        scratch,
        &.{.backtick_fence, .tilde_fence},
    ) orelse return null;

    const info_lang = blk: {
        // Whitespace allowed between fence and info string
        _ = try self.consume(scratch, &.{.whitespace});

        // First text token is treated as language
        const text = try self.consume(scratch, &.{.text}) orelse break :blk "";
        if (
            open_fence.token_type == .backtick_fence
            and std.mem.count(u8, text.lexeme, "`") > 0
        ) {
            return null;
        }

        // Following tokens are allowed, but ignored
        while (try self.peek(scratch)) |next| {
            switch (next.token_type) {
                .text => {
                    if (
                        open_fence.token_type == .backtick_fence
                        and std.mem.count(u8, next.lexeme, "`") > 0
                    ) {
                        return null;
                    }
                    _ = try self.consume(scratch, &.{.text});
                },
                .newline => break,
                .backtick_fence => {
                    if (open_fence.token_type == .backtick_fence) {
                        return null;
                    }
                    _ = try self.consume(scratch, &.{.backtick_fence});
                },
                else => |t| {
                    _ = try self.consume(scratch, &.{t});
                },
            }
        }

        break :blk text.lexeme;
    };
    _ = try self.consume(scratch, &.{.newline}) orelse return null;

    // Block content
    var content = Io.Writer.Allocating.init(scratch);
    loop: while (try self.peek(scratch)) |line_start_token| {
        // First token in line
        switch (line_start_token.token_type) {
            .backtick_fence, .tilde_fence => |t| {
                if (try self.peekClosingFence(scratch, open_fence)) {
                    break :loop;
                }

                _ = try self.consume(scratch, &.{t});
                _ = try content.writer.write(line_start_token.lexeme);
            },
            .whitespace => |t| {
                if (try self.peekClosingFence(scratch, open_fence)) {
                    break :loop;
                }

                _ = try self.consume(scratch, &.{t});
                const start = std.mem.min(
                    usize,
                    &.{indentation, line_start_token.lexeme.len},
                );
                const value = line_start_token.lexeme[start..];
                _ = try content.writer.write(value);
            },
            .indent => {
                _ = try self.consume(scratch, &.{.indent});
                const start = std.mem.min(
                    usize,
                    &.{indentation, line_start_token.lexeme.len},
                );
                const value = line_start_token.lexeme[start..];
                _ = try content.writer.write(value);
            },
            .newline => {
                // TODO: all tokens should have lexemes
                _ = try self.consume(scratch, &.{.newline});
                _ = try content.writer.write("\n");
            },
            else => |t| {
                _ = try self.consume(scratch, &.{t});
                _ = try content.writer.write(line_start_token.lexeme);
            }
        }

        // Trailing tokens in line
        while (try self.peek(scratch)) |token| {
            switch (token.token_type) {
                .newline => {
                    // TODO: all tokens should have lexemes
                    _ = try self.consume(scratch, &.{.newline});
                    _ = try content.writer.write("\n");
                    break;
                },
                else => {
                    _ = try self.consume(scratch, &.{token.token_type});
                    _ = try content.writer.write(token.lexeme);
                },
            }
        }
    }

    // Closing code fence line
    // Not needed if file ends
    _ = try self.consume(scratch, &.{.whitespace});
    if (try self.consume(scratch, &.{open_fence.token_type})) |_| {
        _ = try self.consume(scratch, &.{.whitespace});
        _ = try self.consume(scratch, &.{.newline}) orelse return null;
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
    const checkpoint_index = self.checkpoint();
    defer self.backtrack(checkpoint_index);

    _ = try self.consume(scratch, &.{.whitespace});

    const close_fence = try self.consume(
        scratch,
        &.{open_fence.token_type},
    ) orelse return false;
    if (close_fence.lexeme.len < open_fence.lexeme.len) {
        return false;
    }

    _ = try self.consume(scratch, &.{.whitespace});
    _ = try self.consume(scratch, &.{.newline}) orelse return false;

    return true;
}

/// https://spec.commonmark.org/0.30/#link-reference-definition
fn parseLinkReferenceDefinition(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) !?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer {
        logParseAttempt("parseLinkReferenceDefinition()", did_parse);
        if (!did_parse) {
            self.backtrack(checkpoint_index);
        }
    }

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
    const escaped_url = try escape.copyEscape(scratch, scanned_url);
    const url = try cmark.uri.normalize(alloc, scratch, escaped_url);
    defer if (!did_parse) {
        alloc.free(url);
    };

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
        if (!seen_any_separating_whitespace) {
            break :blk "";
        }

        const title_checkpoint_index = self.checkpoint();
        const t = try self.scanLinkDefTitle(scratch) orelse break :blk "";

        // "no further character can occur" says the spec, but then there's an
        // example of spaces following the title, so we optionally consume
        // whitespace here.
        _ = try self.consume(scratch, &.{.whitespace});

        if (seen_newline) {
            _ = try self.consume(scratch, &.{.newline}) orelse {
                // There was something after the title, but the title was
                // already on a separate line, so just fail to parse the title.
                self.backtrack(title_checkpoint_index);
                break :blk "";
            };
        }

        break :blk t;
    };

    if (!seen_newline) {
        // We didn't see a newline before the title (or there was no title). We
        // must see a newline now for this to be a valid link def.
        _ = try self.consume(scratch, &.{.newline}) orelse return null;
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
                const value = try resolveText(scratch, token);
                _ = try running_text.writer.write(value);
            },
            else => |t| {
                saw_non_blank = true;
                _ = try self.consume(scratch, &.{t});
                const value = try resolveText(scratch, token);
                _ = try running_text.writer.write(value);
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
                .rule_dash, .rule_equals, .backtick_fence,
                .tilde_fence => return null,
                .text, .pound, .whitespace, .colon, .l_square_bracket,
                .r_square_bracket, .l_paren, .r_paren, .double_quote,
                .single_quote => |t| {
                    _ = try self.consume(scratch, &.{t});
                    const value = try resolveText(scratch, token);
                    _ = try running_text.writer.write(value);
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
                .rule_dash, .rule_equals, .backtick_fence,
                .tilde_fence => return null,
                .text, .pound, .colon, .l_square_bracket, .r_square_bracket,
                .l_angle_bracket, .r_angle_bracket, .double_quote,
                .single_quote => |t| {
                    _ = try self.consume(scratch, &.{t});
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
                const value = try resolveText(scratch, token);
                _ = try running_text.writer.write(value);
                blank_line_so_far = false;
            },
        }
    }
    _ = try self.consume(scratch, &.{close_t}) orelse return null;

    did_parse = true;
    return try running_text.toOwnedSlice();
}

/// Scan text for a paragraph.
fn scanParagraphText(self: *Self, scratch: Allocator) !?[]const u8 {
    var running_text = Io.Writer.Allocating.init(scratch);

    // Paragraph can start with anything. If the token could have been parsed as
    // something else, it would have been parsed already.
    const start_token = try self.peek(scratch) orelse return null;
    _ = try self.consume(scratch, &.{start_token.token_type});
    _ = try running_text.writer.write(start_token.lexeme);

    const State = enum { open, maybe_close };
    fsm: switch (State.open) {
        .open => {
            const token = try self.peek(scratch) orelse break :fsm;
            switch (token.token_type) {
                .newline => {
                    _ = try self.consume(scratch, &.{.newline});
                    _ = try running_text.writer.write("\n");
                    continue :fsm .maybe_close;
                },
                else => |t| {
                    _ = try self.consume(scratch, &.{t});
                    _ = try running_text.writer.write(token.lexeme);
                    continue :fsm .open;
                },
            }
        },
        .maybe_close => {
            const token = try self.peek(scratch) orelse break :fsm;
            switch (token.token_type) {
                .newline, .pound, .rule_star, .rule_underline,
                .rule_dash_with_whitespace, .rule_dash, .rule_equals,
                .backtick_fence, .tilde_fence => {
                    // These tokens can interrupt a paragraph.
                    break :fsm;
                },
                else => continue :fsm .open,
            }
        },
    }

    return try running_text.toOwnedSlice();
}

fn scanTextFallback(self: *Self, scratch: Allocator) ![]const u8 {
    const token = try self.peek(scratch) orelse return "";
    _ = try self.consume(scratch, &.{token.token_type});
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
    std.debug.assert(self.token_index > 0);

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

fn logParseAttempt(comptime name: []const u8, did_parse: bool) void {
    if (did_parse) {
        logger.debug("BlockParser.{s} SUCCESS", .{name});
    } else {
        logger.debug("BlockParser.{s} FAIL", .{name});
    }
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

    const h1 = root.root.children[0];
    try testing.expectEqual(.heading, @as(ast.NodeType, h1.*));
    try testing.expectEqual(1, h1.heading.depth);
    const text_node = h1.heading.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
    try testing.expectEqualStrings("This is a heading", text_node.text.value);

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
    try testing.expectEqual(3, h1.heading.depth);

    const h2 = root.root.children[1];
    try testing.expectEqual(.heading, @as(ast.NodeType, h2.*));
    try testing.expectEqual(1, h2.heading.depth);
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

    const root, var link_defs = try parseBlocks(md);
    defer root.deinit(testing.allocator);
    defer link_defs.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try testing.expectEqual(3, root.root.children.len);

    const h1 = root.root.children[0];
    try testing.expectEqual(.heading, @as(ast.NodeType, h1.*));
    try testing.expectEqual(1, h1.heading.depth);
    {
        const text_node = h1.heading.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
        try testing.expectEqualStrings("foo", text_node.text.value);
    }

    const h2 = root.root.children[1];
    try testing.expectEqual(.heading, @as(ast.NodeType, h2.*));
    try testing.expectEqual(2, h2.heading.depth);
    {
        const text_node = h2.heading.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
        try testing.expectEqualStrings("bar", text_node.text.value);
    }

    const p = root.root.children[2];
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

    const root, var link_defs = try parseBlocks(md);
    defer root.deinit(testing.allocator);
    defer link_defs.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try testing.expectEqual(2, root.root.children.len);

    const h1 = root.root.children[0];
    try testing.expectEqual(.heading, @as(ast.NodeType, h1.*));
    try testing.expectEqual(1, h1.heading.depth);
    {
        const text_node = h1.heading.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
        try testing.expectEqualStrings("foo *bar*", text_node.text.value);
    }

    const h2 = root.root.children[1];
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

test "empty code fence" {
    const md =
        \\  ```
        \\```
        \\
    ;

    const root, var link_defs = try parseBlocks(md);
    defer root.deinit(testing.allocator);
    defer link_defs.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));

    try testing.expectEqual(1, root.root.children.len);

    const code_node = root.root.children[0];
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

    const root, var link_defs = try parseBlocks(md);
    defer root.deinit(testing.allocator);
    defer link_defs.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));

    try testing.expectEqual(1, root.root.children.len);

    const code_node = root.root.children[0];
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

    const root, var link_defs = try parseBlocks(md);
    defer root.deinit(testing.allocator);
    defer link_defs.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));

    try testing.expectEqual(1, root.root.children.len);

    const code_node = root.root.children[0];
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

    const root, var link_defs = try parseBlocks(md);
    defer root.deinit(testing.allocator);
    defer link_defs.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));

    try testing.expectEqual(1, root.root.children.len);

    const code_node = root.root.children[0];
    try testing.expectEqual(.code, @as(ast.NodeType, code_node.*));
    try testing.expectEqualStrings(
        "def foo():\n    pass",
        code_node.code.value,
    );
    try testing.expectEqualStrings("python", code_node.code.lang);
}

//! Parser for the second parsing stage that handles inline elements.
//!
//! This is a recursive-descent parser with backtracking.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const ast = @import("ast.zig");
const tokens = @import("../lex/tokens.zig");
const InlineToken = tokens.InlineToken;
const InlineTokenType = tokens.InlineTokenType;
const InlineTokenizer = @import("../lex/InlineTokenizer.zig");
const NodeList = @import("NodeList.zig");
const escape = @import("escape.zig");
const references = @import("references.zig");
const safety = @import("../util/safety.zig");
const strings = @import("../util/strings.zig");

pub const Error = error{
    WriteFailed,
} || references.CharacterReferenceError || Allocator.Error;

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
pub fn parse(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error![]*ast.Node {
    var nodes = NodeList.init(alloc, scratch, createTextNode);
    errdefer {
        for (nodes.items()) |node| {
            node.deinit(alloc);
        }
        nodes.deinit();
    }

    for (0..safety.loop_bound) |_| { // could hit if we forget to consume tokens
        _ = try self.peek(scratch) orelse break;

        if (try self.parseInlineCode(alloc, scratch)) |code| {
            try nodes.append(code);
            continue;
        }

        if (try self.parseURIAutolink(alloc, scratch)) |link| {
            try nodes.append(link);
            continue;
        }

        if (try self.parseInlineLink(alloc, scratch)) |link| {
            try nodes.append(link);
            continue;
        }

        if (try self.parseAnyEmphasis(alloc, scratch)) |emph| {
            try nodes.append(emph);
            continue;
        }

        if (try self.parseAnyStrong(alloc, scratch)) |strong| {
            try nodes.append(strong);
            continue;
        }

        const text_value = try self.scanText(scratch);
        if (text_value.len > 0) {
            try nodes.appendText(text_value);
            continue;
        }

        const text_fallback_value = try self.scanTextFallback(scratch);
        if (text_fallback_value.len > 0) {
            try nodes.appendText(text_fallback_value);
            continue;
        }

        @panic("unable to parse inline token");
    } else @panic(safety.loop_bound_panic_msg);

    return try nodes.toOwnedSlice();
}

// strong => open inner close
// open   => l_star l_star | lr_star lr_star
// close  => r_star r_star | lr_star lr_star
// inner  => (link | emph | strong | text)+
fn parseStarStrong(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var strong_node: ?*ast.Node = null;
    var children = NodeList.init(alloc, scratch, createTextNode);
    const checkpoint_index = self.checkpoint();
    defer {
        if (strong_node == null) {
            self.backtrack(checkpoint_index);
            for (children.items()) |child| {
                child.deinit(alloc);
            }
            children.deinit();
        }
    }

    const open_token = try self.consume(scratch, &.{
        .l_delim_star,
        .lr_delim_star,
    }) orelse return null;
    _ = try self.consume(scratch, &.{
        .l_delim_star,
        .lr_delim_star,
    }) orelse return null;

    for (0..safety.loop_bound) |_| {
        if (try self.parseInlineCode(alloc, scratch)) |code| {
            try children.append(code);
            continue;
        }

        if (try self.parseInlineLink(alloc, scratch)) |link| {
            try children.append(link);
            continue;
        }

        if (try self.parseAnyEmphasis(alloc, scratch)) |emph| {
            try children.append(emph);
            continue;
        }

        if (try self.parseAnyStrong(alloc, scratch)) |strong| {
            try children.append(strong);
            continue;
        }

        const text_value = try self.scanText(scratch);
        if (text_value.len > 0) {
            try children.appendText(text_value);
            continue;
        }

        // Check for closing condition
        if (try self.peek(scratch)) |node| {
            switch (node.token_type) {
                .r_delim_star, .lr_delim_star => |t| {
                    if (try self.peekAhead(scratch, 2)) |next_node| {
                        if (next_node.token_type == t) {
                            break;
                        }
                    }
                },
                else => {},
            }
        }

        const text_fallback_value = try self.scanTextFallback(scratch);
        if (text_fallback_value.len > 0) {
            try children.appendText(text_fallback_value);
            continue;
        }

        break;
    } else @panic(safety.loop_bound_panic_msg);

    try children.flush();
    if (children.len() == 0) {
        return null;
    }

    const close_token = try self.consume(scratch, &.{
        .r_delim_star,
        .lr_delim_star,
    }) orelse return null;
    _ = try self.consume(scratch, &.{
        .r_delim_star,
        .lr_delim_star,
    }) orelse return null;

    if (!isValidBySumOfLengthsRule(open_token, close_token)) {
        return null;
    }

    strong_node = try alloc.create(ast.Node);
    strong_node.?.* = .{
        .strong = .{
            .children = try children.toOwnedSlice(),
        },
    };
    return strong_node;
}

// star_emph  => open inner close
// open  => l_star | lr_star
// close => r_star | lr_star
// inner => (star_emph? (link | under_emph | strong | text) star_emph?)+
//
/// Parse emphasis using star delimiters.
///
/// We don't allow star-delimited emphasis to nest immediately inside each
/// other. (That should get parsed as strong.)
fn parseStarEmphasis(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var emphasis_node: ?*ast.Node = null;
    var children = NodeList.init(alloc, scratch, createTextNode);
    const checkpoint_index = self.checkpoint();
    defer {
        if (emphasis_node == null) {
            self.backtrack(checkpoint_index);
            for (children.items()) |child| {
                child.deinit(alloc);
            }
            children.deinit();
        }
    }

    const open_token = try self.consume(scratch, &.{
        .l_delim_star,
        .lr_delim_star,
    }) orelse return null;

    for (0..safety.loop_bound) |_| {
        const maybe_leading_emph = try self.parseStarEmphasis(alloc, scratch);

        if (blk: {
            if (try self.parseInlineCode(alloc, scratch)) |code| {
                break :blk code;
            }

            if (try self.parseInlineLink(alloc, scratch)) |link| {
                break :blk link;
            }

            if (try self.parseUnderscoreEmphasis(alloc, scratch)) |emph| {
                break :blk emph;
            }

            if (try self.parseAnyStrong(alloc, scratch)) |strong| {
                break :blk strong;
            }

            break :blk null;
        }) |node| {
            if (maybe_leading_emph) |emph| {
                try children.append(emph);
            }
            try children.append(node);
            if (try self.parseStarEmphasis(alloc, scratch)) |emph| {
                try children.append(emph);
            }
            continue;
        }

        const text_value = try self.scanText(scratch);
        if (text_value.len > 0) {
            if (maybe_leading_emph) |emph| {
                try children.append(emph);
            }
            try children.appendText(text_value);
            if (try self.parseStarEmphasis(alloc, scratch)) |emph| {
                try children.append(emph);
            }
            continue;
        }

        // failed to parse anything
        if (maybe_leading_emph) |emph| {
            emph.deinit(alloc);
        }

        // Check for closing condition
        if (try self.peek(scratch)) |node| {
            switch (node.token_type) {
                .r_delim_star, .lr_delim_star => break,
                else => {},
            }
        }

        const text_fallback_value = try self.scanTextFallback(scratch);
        if (text_fallback_value.len > 0) {
            try children.appendText(text_fallback_value);
            continue;
        }

        break;
    } else @panic(safety.loop_bound_panic_msg);

    try children.flush();
    if (children.len() == 0) {
        return null;
    }

    const close_token = try self.consume(scratch, &.{
        .r_delim_star,
        .lr_delim_star,
    }) orelse return null;

    if (!isValidBySumOfLengthsRule(open_token, close_token)) {
        return null;
    }

    emphasis_node = try alloc.create(ast.Node);
    emphasis_node.?.* = .{
        .emphasis = .{
            .children = try children.toOwnedSlice(),
        },
    };
    return emphasis_node;
}

// strong => open inner close
// open   => l_star l_star | lr_star lr_star
// close  => r_star r_star | lr_star lr_star
// inner  => (link | emph | strong | text)+
fn parseUnderscoreStrong(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var strong_node: ?*ast.Node = null;
    var children = NodeList.init(alloc, scratch, createTextNode);
    const checkpoint_index = self.checkpoint();
    defer {
        if (strong_node == null) {
            self.backtrack(checkpoint_index);
            for (children.items()) |child| {
                child.deinit(alloc);
            }
            children.deinit();
        }
    }

    const open_token = try self.peek(scratch) orelse return null;
    switch (open_token.token_type) {
        .l_delim_underscore => |t| {
            _ = try self.consume(scratch, &.{t});
            _ = try self.consume(scratch, &.{t}) orelse return null;
        },
        .lr_delim_underscore => |t| {
            // Can only open strong if delimiter run follows punctuation
            if (!open_token.context.delim_underscore.preceded_by_punct) {
                return null;
            }

            _ = try self.consume(scratch, &.{t});
            _ = try self.consume(scratch, &.{t}) orelse return null;
        },
        else => return null,
    }

    for (0..safety.loop_bound) |_| {
        if (try self.parseInlineCode(alloc, scratch)) |code| {
            try children.append(code);
            continue;
        }

        if (try self.parseInlineLink(alloc, scratch)) |link| {
            try children.append(link);
            continue;
        }

        if (try self.parseAnyEmphasis(alloc, scratch)) |emph| {
            try children.append(emph);
            continue;
        }

        if (try self.parseAnyStrong(alloc, scratch)) |strong| {
            try children.append(strong);
            continue;
        }

        const text_value = try self.scanText(scratch);
        if (text_value.len > 0) {
            try children.appendText(text_value);
            continue;
        }

        // Check for closing condition
        if (try self.peek(scratch)) |node| {
            switch (node.token_type) {
                .r_delim_underscore, .lr_delim_underscore => |t| {
                    if (try self.peekAhead(scratch, 2)) |next_node| {
                        if (next_node.token_type == t) {
                            break;
                        }
                    }
                },
                else => {},
            }
        }

        const text_fallback_value = try self.scanTextFallback(scratch);
        if (text_fallback_value.len > 0) {
            try children.appendText(text_fallback_value);
            continue;
        }

        break;
    } else @panic(safety.loop_bound_panic_msg);

    try children.flush();
    if (children.len() == 0) {
        return null;
    }

    const close_token = try self.peek(scratch) orelse return null;
    switch (close_token.token_type) {
        .r_delim_underscore => |t| {
            _ = try self.consume(scratch, &.{t});
            _ = try self.consume(scratch, &.{t}) orelse return null;
        },
        .lr_delim_underscore => |t| {
            // Can only close strong if delimiter run is followed by punctuation
            if (!close_token.context.delim_underscore.followed_by_punct) {
                return null;
            }

            _ = try self.consume(scratch, &.{t});
            _ = try self.consume(scratch, &.{t}) orelse return null;
        },
        else => return null,
    }

    if (!isValidBySumOfLengthsRule(open_token, close_token)) {
        return null;
    }

    strong_node = try alloc.create(ast.Node);
    strong_node.?.* = .{
        .strong = .{
            .children = try children.toOwnedSlice(),
        },
    };
    return strong_node;
}

// under_emph  => open inner close
// open  => l_underscore | lr_underscore
// close => r_underscore | lr_underscore
// inner => (under_emph? (link | star_emph | strong | text) under_emph?)+
//
/// Parse underscore-delimited emphasis.
///
/// We don't allow underscore-delimited emphasis to nest immediately inside each
/// other. (That should get parsed as strong.)
fn parseUnderscoreEmphasis(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var emphasis_node: ?*ast.Node = null;
    var children = NodeList.init(alloc, scratch, createTextNode);
    const checkpoint_index = self.checkpoint();
    defer {
        if (emphasis_node == null) {
            self.backtrack(checkpoint_index);
            for (children.items()) |child| {
                child.deinit(alloc);
            }
            children.deinit();
        }
    }

    const open_token = try self.peek(scratch) orelse return null;
    switch (open_token.token_type) {
        .l_delim_underscore => _ = try self.consume(scratch, &.{.l_delim_underscore}),
        .lr_delim_underscore => {
            // Can only open emphasis if delimiter run follows punctuation
            if (!open_token.context.delim_underscore.preceded_by_punct) {
                return null;
            }

            _ = try self.consume(scratch, &.{.lr_delim_underscore});
        },
        else => return null,
    }

    for (0..safety.loop_bound) |_| {
        const maybe_leading_emph = try self.parseUnderscoreEmphasis(alloc, scratch);

        if (blk: {
            if (try self.parseInlineCode(alloc, scratch)) |code| {
                break :blk code;
            }

            if (try self.parseInlineLink(alloc, scratch)) |link| {
                break :blk link;
            }

            if (try self.parseStarEmphasis(alloc, scratch)) |emph| {
                break :blk emph;
            }

            if (try self.parseAnyStrong(alloc, scratch)) |strong| {
                break :blk strong;
            }

            break :blk null;
        }) |node| {
            if (maybe_leading_emph) |emph| {
                try children.append(emph);
            }
            try children.append(node);
            if (try self.parseUnderscoreEmphasis(alloc, scratch)) |emph| {
                try children.append(emph);
            }
            continue;
        }

        const text_value = try self.scanText(scratch);
        if (text_value.len > 0) {
            if (maybe_leading_emph) |emph| {
                try children.append(emph);
            }
            try children.appendText(text_value);
            if (try self.parseStarEmphasis(alloc, scratch)) |emph| {
                try children.append(emph);
            }
            continue;
        }

        // failed to parse anything
        if (maybe_leading_emph) |emph| {
            emph.deinit(alloc);
        }

        // Check for closing condition
        if (try self.peek(scratch)) |node| {
            switch (node.token_type) {
                .r_delim_underscore, .lr_delim_underscore => break,
                else => {},
            }
        }

        const text_fallback_value = try self.scanTextFallback(scratch);
        if (text_fallback_value.len > 0) {
            try children.appendText(text_fallback_value);
            continue;
        }

        break;
    } else @panic(safety.loop_bound_panic_msg);

    try children.flush();
    if (children.len() == 0) {
        return null;
    }

    const close_token = try self.peek(scratch) orelse return null;
    switch (close_token.token_type) {
        .r_delim_underscore => _ = try self.consume(scratch, &.{.r_delim_underscore}),
        .lr_delim_underscore => {
            // Can only close emphasis if delimiter run is followed by punctuation
            if (!close_token.context.delim_underscore.followed_by_punct) {
                return null;
            }

            _ = try self.consume(scratch, &.{.lr_delim_underscore});
        },
        else => return null,
    }

    if (!isValidBySumOfLengthsRule(open_token, close_token)) {
        return null;
    }

    emphasis_node = try alloc.create(ast.Node);
    emphasis_node.?.* = .{
        .emphasis = .{
            .children = try children.toOwnedSlice(),
        },
    };
    return emphasis_node;
}

/// Checks commonmark spec rule 9. and 10. for parsing emphasis and strong
/// emphasis.
///
/// Returns true if the emphasis is valid, false otherwise.
fn isValidBySumOfLengthsRule(open: InlineToken, close: InlineToken) bool {
    if (
        open.token_type == .lr_delim_star
        or close.token_type == .lr_delim_star
    ) {
        const sum_of_len = (
            open.context.delim_star.run_len
            + close.context.delim_star.run_len
        );
        if (sum_of_len % 3 == 0) {
            return (
                open.context.delim_star.run_len % 3 == 0
                and open.context.delim_star.run_len % 3 == 0
            );
        }
    }

    if (
        open.token_type == .lr_delim_underscore
        and close.token_type == .lr_delim_underscore
    ) {
        const sum_of_len = (
            open.context.delim_underscore.run_len
            + close.context.delim_underscore.run_len
        );
        if (sum_of_len % 3 == 0) {
            return (
                open.context.delim_underscore.run_len % 3 == 0
                and open.context.delim_underscore.run_len % 3 == 0
            );
        }
    }

    return true;
}

fn parseAnyEmphasis(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    if (try self.parseStarEmphasis(alloc, scratch)) |emph| {
        return emph;
    }

    if (try self.parseUnderscoreEmphasis(alloc, scratch)) |emph| {
        return emph;
    }

    return null;
}

fn parseAnyStrong(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    if (try self.parseStarStrong(alloc, scratch)) |strong| {
        return strong;
    }

    if (try self.parseUnderscoreStrong(alloc, scratch)) |strong| {
        return strong;
    }

    return null;
}

// @ => backtick(n) .+ backtick(n)
fn parseInlineCode(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var inline_code_node: ?*ast.Node = null;
    const checkpoint_index = self.checkpoint();
    defer {
        if (inline_code_node == null) {
            self.backtrack(checkpoint_index);
        }
    }

    const open = try self.consume(scratch, &.{ .backtick }) orelse return null;

    var values: ArrayList([]const u8) = .empty;
    for (0..safety.loop_bound) |_| {
        const token = try self.peek(scratch) orelse return null;
        switch (token.token_type) {
            .backtick => {
                _ = try self.consume(scratch, &.{ .backtick });
                if (token.lexeme.len == open.lexeme.len) {
                    break;
                }

                const value = try resolveInlineCode(token);
                try values.append(scratch, value);
            },
            else => |t| {
                _ = try self.consume(scratch, &.{t});

                const value = try resolveInlineCode(token);
                try values.append(scratch, value);
            }
        }
    } else @panic(safety.loop_bound_panic_msg);

    if (values.items.len == 0) {
        return null;
    }

    var value = try std.mem.join(alloc, "", values.items);

    // Special case for stripping single leading and following space
    if (value.len > 1 and !strings.containsOnly(value, " ")) {
        if (value[0] == ' ' and value[value.len - 1] == ' ') {
            // TODO: Do we have to allocate here?
            const new = try alloc.dupe(u8, value[1..value.len - 1]);
            alloc.free(value);
            value = new;
        }
    }

    inline_code_node = try alloc.create(ast.Node);
    inline_code_node.?.* = .{
        .inline_code = .{
            .value = value,
        },
    };
    return inline_code_node;
}

// @ => link_text l_paren (link_dest link_title?)? r_paren
/// Parses an inline link.
fn parseInlineLink(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var inline_link: ?*ast.Node = null;
    const checkpoint_index = self.checkpoint();
    defer {
        if (inline_link == null) {
            self.backtrack(checkpoint_index);
        }
    }

    // handle link text
    const link_text_nodes = (
        try self.parseLinkText(alloc, scratch) orelse return null
    );
    defer {
        if (inline_link == null) {
            for (link_text_nodes) |node| {
                node.deinit(alloc);
            }
            alloc.free(link_text_nodes);
        }
    }

    _ = try self.consume(scratch, &.{.l_paren}) orelse return null;

    // link destination
    const url = try self.scanLinkDestination(scratch);

    const title = blk: {
        // link title, if present, must be separated from destination by
        // whitespace
        if (try self.consume(scratch, &.{.newline, .whitespace})) |_| {
            break :blk try self.scanLinkTitle(scratch);
        }

        break :blk "";
    };

    _ = try self.consume(scratch, &.{.r_paren}) orelse return null;

    inline_link = try alloc.create(ast.Node);
    inline_link.?.* = .{
        .link = .{
            .url = try alloc.dupe(u8, url),
            .title = try alloc.dupe(u8, title),
            .children = link_text_nodes,
        },
    };
    return inline_link;
}

/// Parses the link text component of an inline link. Returns a slice of inline
/// AST nodes.
fn parseLinkText(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?[]*ast.Node {
    var nodes = NodeList.init(alloc, scratch, createTextNode);
    var did_parse_successfully = false;
    const checkpoint_index = self.checkpoint();
    defer {
        if (!did_parse_successfully) {
            self.backtrack(checkpoint_index);
            for (nodes.items()) |node| {
                node.deinit(alloc);
            }
            nodes.deinit();
        }
    }

    _ = try self.consume(scratch, &.{.l_square_bracket}) orelse return null;

    var bracket_depth: u32 = 0;
    loop: for (0..safety.loop_bound) |_| {
        if (try self.parseInlineLink(alloc, scratch)) |link| {
            try nodes.append(link); // ensure it gets cleaned up
            return null; // nested links are not allowed!
        }

        if (try self.parseInlineCode(alloc, scratch)) |code| {
            try nodes.append(code);
            continue;
        }

        // Handle square brackets, which are only allowed if they are balanced
        const allowed_bracket: []const u8 = blk: {
            const token = try self.peek(scratch) orelse return null;
            switch (token.token_type) {
                .l_square_bracket => {
                    bracket_depth += 1;
                },
                .r_square_bracket => {
                    if (bracket_depth == 0) {
                        // end of link text
                        break :loop;
                    }

                    bracket_depth -= 1;
                },
                else => break :blk "",
            }

            _ = try self.consume(scratch, &.{token.token_type});
            const value = try resolveInlineText(scratch, token);
            break :blk value;
        };
        if (allowed_bracket.len > 0) {
            try nodes.appendText(allowed_bracket);
            continue;
        }

        if (try self.parseAnyEmphasis(alloc, scratch)) |emph| {
            try nodes.append(emph);
            continue;
        }

        if (try self.parseAnyStrong(alloc, scratch)) |strong| {
            try nodes.append(strong);
            continue;
        }

        const text_value = try self.scanText(scratch);
        if (text_value.len > 0) {
            try nodes.appendText(text_value);
            continue;
        }

        const text_fallback_value = try self.scanTextFallback(scratch);
        if (text_fallback_value.len > 0) {
            try nodes.appendText(text_fallback_value);
            continue;
        }

        break;
    } else @panic(safety.loop_bound_panic_msg);

    _ = try self.consume(scratch, &.{.r_square_bracket}) orelse return null;

    if (bracket_depth > 0) {
        return null; // contained unbalanced brackets
    }

    did_parse_successfully = true;
    return try nodes.toOwnedSlice();
}

/// Parses the URL for a link, which can be either:
/// <foobar>
/// or
/// nonempty sequence without a space (or unbalanced parens)
fn scanLinkDestination(self: *Self, scratch: Allocator) ![]const u8 {
    var running_text = Io.Writer.Allocating.init(scratch);
    var did_parse_successfully = false;
    const checkpoint_index = self.checkpoint();
    defer {
        if (!did_parse_successfully) {
            self.backtrack(checkpoint_index);
        }
    }

    if (try self.consume(scratch, &.{.l_angle_bracket})) |_| {
        // Option one, angle bracket delimited
        while (try self.peek(scratch)) |token| {
            switch (token.token_type) {
                .l_angle_bracket, .newline => return "",
                .r_angle_bracket => break,
                else => |t| {
                    _ = try self.consume(scratch, &.{t});
                    const value = try resolveInlineText(scratch, token);
                    _ = try running_text.writer.write(value);
                },
            }
        }
        _ = try self.consume(scratch, &.{.r_angle_bracket});
    } else {
        // Option two
        // - no ascii control chars
        // - no spaces
        // - balanced parens
        var paren_depth: u32 = 0;
        while (try self.peek(scratch)) |token| {
            switch (token.token_type) {
                .newline => return "",
                .l_paren => {
                    paren_depth += 1;
                    _ = try self.consume(scratch, &.{.l_paren});
                    const value = try resolveInlineText(scratch, token);
                    _ = try running_text.writer.write(value);
                },
                .r_paren => {
                    if (paren_depth == 0) {
                        break;
                    }

                    paren_depth -= 1;
                },
                .whitespace => break,
                else => |t| {
                    _ = try self.consume(scratch, &.{t});
                    const value = try resolveInlineText(scratch, token);
                    _ = try running_text.writer.write(value);
                },
            }
        }
    }

    did_parse_successfully = true;
    return try running_text.toOwnedSlice();
}

// Title part of an inline link.
//
// Should be enclosed in () or "" or ''. Can span multiple lines but cannot
// contain a blank line.
fn scanLinkTitle(self: *Self, scratch: Allocator) ![]const u8 {
    var running_text = Io.Writer.Allocating.init(scratch);
    var did_parse_successfully = false;
    const checkpoint_index = self.checkpoint();
    defer {
        if (!did_parse_successfully) {
            self.backtrack(checkpoint_index);
        }
    }

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
                    return ""; // link title cannot contain blank line
                }
                _ = try self.consume(scratch, &.{.newline});
                const value = try resolveInlineText(scratch, token);
                _ = try running_text.writer.write(value);

                blank_line_so_far = true;
            },
            .whitespace => {
                _ = try self.consume(scratch, &.{.whitespace});
                const value = try resolveInlineText(scratch, token);
                _ = try running_text.writer.write(value);
            },
            else => |t| {
                if (t == close_t) {
                    break;
                }

                _ = try self.consume(scratch, &.{t});
                const value = try resolveInlineText(scratch, token);
                _ = try running_text.writer.write(value);
                blank_line_so_far = false;
            },
        }
    }
    _ = try self.consume(scratch, &.{close_t}) orelse return "";

    did_parse_successfully = true;
    return try running_text.toOwnedSlice();
}

fn parseURIAutolink(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    const open_token = try self.peek(scratch) orelse return null;
    if (open_token.token_type != .l_angle_bracket) {
        return null;
    }

    const uri_token = try self.peekAhead(scratch, 2) orelse return null;
    if (uri_token.token_type != .absolute_uri) {
        return null;
    }

    const close_token = try self.peekAhead(scratch, 3) orelse return null;
    if (close_token.token_type != .r_angle_bracket) {
        return null;
    }

    _ = try self.consume(scratch, &.{.l_angle_bracket}) orelse return null;
    _ = try self.consume(scratch, &.{.absolute_uri}) orelse return null;
    _ = try self.consume(scratch, &.{.r_angle_bracket}) orelse return null;

    const url = try resolveInlineText(scratch, uri_token);
    const text = try createTextNode(alloc, url);

    const inline_link = try alloc.create(ast.Node);
    inline_link.* = .{
        .link = .{
            .url = try alloc.dupe(u8, url),
            .title = "",
            .children = try alloc.dupe(*ast.Node, &.{text}),
        },
    };
    return inline_link;
}

fn scanText(self: *Self, scratch: Allocator) ![]const u8 {
    var running_text = Io.Writer.Allocating.init(scratch);

    while (try self.peek(scratch)) |token| {
        switch (token.token_type) {
            .decimal_character_reference, .hexadecimal_character_reference,
            .entity_reference, .newline, .whitespace, .text => |t| {
                _ = try self.consume(scratch, &.{t});

                const value = try resolveInlineText(scratch, token);
                _ = try running_text.writer.write(value);
            },
            .lr_delim_underscore => {
                // Only allowed if cannot start or stop emphasis
                if (
                    token.context.delim_underscore.preceded_by_punct
                    or token.context.delim_underscore.followed_by_punct
                ) {
                    break;
                }
                _ = try self.consume(scratch, &.{.lr_delim_underscore});

                const value = try resolveInlineText(scratch, token);
                _ = try running_text.writer.write(value);
            },
            else => break,
        }
    }

    return try running_text.toOwnedSlice();
}

fn scanTextFallback(self: *Self, scratch: Allocator) ![]const u8 {
    const token = try self.peek(scratch) orelse return "";
    _ = try self.consume(scratch, &.{token.token_type});

    const text_value = try resolveInlineText(scratch, token);
    return text_value;
}

/// Resolve token to actual string content within an inline code node.
fn resolveInlineCode(token: InlineToken) ![]const u8 {
    const value = switch (token.token_type) {
        .decimal_character_reference, .hexadecimal_character_reference,
        .entity_reference, .absolute_uri, .email, .backtick, .whitespace,
        .text => token.lexeme,
        .newline => " ",
        .l_delim_star, .r_delim_star, .lr_delim_star => "*",
        .l_delim_underscore, .r_delim_underscore, .lr_delim_underscore => "_",
        .l_square_bracket => "[",
        .r_square_bracket => "]",
        .l_angle_bracket => "<",
        .r_angle_bracket => ">",
        .l_paren => "(",
        .r_paren => ")",
        .single_quote => "'",
        .double_quote => "\"",
    };
    return value;
}

/// Resolve token to actual string content within a text node.
fn resolveInlineText(scratch: Allocator, token: InlineToken) ![]const u8 {
    const value = switch (token.token_type) {
        .decimal_character_reference, .hexadecimal_character_reference,
        .entity_reference => blk: {
            break :blk try resolveCharacterEntityRef(scratch, token);
        },
        .newline => "\n",
        .absolute_uri, .email, .backtick, .whitespace => token.lexeme,
        .l_delim_star, .r_delim_star, .lr_delim_star => "*",
        .l_delim_underscore, .r_delim_underscore, .lr_delim_underscore => "_",
        .text => try escape.copyEscape(scratch, token.lexeme),
        .l_square_bracket => "[",
        .r_square_bracket => "]",
        .l_angle_bracket => "<",
        .r_angle_bracket => ">",
        .l_paren => "(",
        .r_paren => ")",
        .single_quote => "'",
        .double_quote => "\"",
    };
    return value;
}

fn resolveCharacterEntityRef(scratch: Allocator, token: InlineToken) ![]const u8 {
    switch (token.token_type) {
        .decimal_character_reference => {
            const value = try references.resolveCharacter(
                scratch,
                token.lexeme[2..token.lexeme.len - 1],
                10, // base
            );
            return value;
        },
        .hexadecimal_character_reference => {
            const value = try references.resolveCharacter(
                scratch,
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

/// Create a new AST text node.
///
/// The string value passed in gets copied to a new location in memory owned by
/// the returned text node.
fn createTextNode(alloc: Allocator, value: []const u8) !*ast.Node {
    const node = try alloc.create(ast.Node);
    node.* = .{
        .text = .{
            .value = try alloc.dupe(u8, value),
        },
    };
    return node;
}

fn peek(self: *Self, scratch: Allocator) !?InlineToken {
    return self.peekAhead(scratch, 1);
}

fn peekAhead(self: *Self, scratch: Allocator, count: u16) !?InlineToken {
    const index = self.token_index + (count - 1);
    while (index >= self.line.items.len) {
        // Returning null here means end of token stream
        const next = try self.tokenizer.next(scratch) orelse return null;
        try self.line.append(scratch, next);
    }

    return self.line.items[index];
}

fn consume(
    self: *Self,
    scratch: Allocator,
    token_types: []const InlineTokenType,
) !?InlineToken {
    const current = try self.peek(scratch) orelse return null;
    for (token_types) |token_type| {
        if (current.token_type == token_type) {
            self.token_index += 1;
            return current;
        }
    }

    return null;
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

fn parseIntoNodes(value: []const u8) ![]*ast.Node {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var tokenizer = InlineTokenizer.init(value);
    var parser = Self.init(&tokenizer);
    return try parser.parse(testing.allocator, scratch);
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

test "unmatched nested emphasis" {
    const value = "**strong * with asterisk**";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.strong, @as(ast.NodeType, nodes[0].*));
    try testing.expectEqual(1, nodes[0].strong.children.len);

    try testing.expectEqual(
        ast.NodeType.text,
        @as(ast.NodeType, nodes[0].strong.children[0].*),
    );
    try testing.expectEqualStrings(
        "strong * with asterisk",
        nodes[0].strong.children[0].text.value,
    );
}

test "unmatched nested emphasis no spacing" {
    const value = "**foo*bar**";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.strong, @as(ast.NodeType, nodes[0].*));
    try testing.expectEqual(1, nodes[0].strong.children.len);

    try testing.expectEqual(
        ast.NodeType.text,
        @as(ast.NodeType, nodes[0].strong.children[0].*),
    );
    try testing.expectEqualStrings(
        "foo*bar",
        nodes[0].strong.children[0].text.value,
    );
}

test "bad star strong given spacing" {
    // the space following "hello" means the last two asterisks shouldn't get
    // tokenized as a delimiter run
    const value = "**hello **";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[0].*));
}

test "unmatched nested underscore" {
    const value = "*foo _bar*";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(
        ast.NodeType.emphasis,
        @as(ast.NodeType, nodes[0].*),
    );
    try testing.expectEqual(1, nodes[0].emphasis.children.len);

    try testing.expectEqual(
        ast.NodeType.text,
        @as(ast.NodeType, nodes[0].emphasis.children[0].*),
    );
    try testing.expectEqualStrings(
        "foo _bar",
        nodes[0].emphasis.children[0].text.value,
    );
}

test "triple underscore strong nested" {
    const value = "This is ___a strong in an emphasis___.";
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

test "underscore emphasis" {
    const value = "This _is emphasized._";
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

test "underscore right-delimiter emphasis" {
    const value = "This is _hyper_-cool!";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[0].*));
    try testing.expectEqual(
        ast.NodeType.emphasis,
        @as(ast.NodeType, nodes[1].*),
    );
    try testing.expectEqualStrings(
        "hyper",
        nodes[1].emphasis.children[0].text.value,
    );
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[2].*));
}

// Unlike with star emphasis, this isn't valid
test "intraword underscore emphasis" {
    const value = "snake_case_baby";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[0].*));
    try testing.expectEqualStrings("snake_case_baby", nodes[0].text.value);
}

test "underscore emphasis after punctuation" {
    const value = "(_\"emphasis\"_)";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[0].*));

    try testing.expectEqual(
        ast.NodeType.emphasis,
        @as(ast.NodeType, nodes[1].*),
    );
    try testing.expectEqualStrings(
        "\"emphasis\"",
        nodes[1].emphasis.children[0].text.value,
    );

    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, nodes[2].*));
}

test "underscore emphasis nested unmatched" {
    const value = "_foo *bar_";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(
        ast.NodeType.emphasis,
        @as(ast.NodeType, nodes[0].*),
    );
    try testing.expectEqual(1, nodes[0].emphasis.children.len);

    try testing.expectEqual(
        ast.NodeType.text,
        @as(ast.NodeType, nodes[0].emphasis.children[0].*),
    );
    try testing.expectEqualStrings(
        "foo *bar",
        nodes[0].emphasis.children[0].text.value,
    );
}

test "underscore strong" {
    const value = "This is __strongly emphasized__.";
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

test "underscore strong with nested unmatched" {
    const value = "__foo*bar__";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.strong, @as(ast.NodeType, nodes[0].*));
    try testing.expectEqual(1, nodes[0].strong.children.len);

    try testing.expectEqual(
        ast.NodeType.text,
        @as(ast.NodeType, nodes[0].strong.children[0].*),
    );
    try testing.expectEqualStrings(
        "foo*bar",
        nodes[0].strong.children[0].text.value,
    );
}

test "nesting feast of insanity" {
    const value = "**_My, __**hello**___, *what a __feast!__***";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    // strong
    // - emphasis
    //   - text "My, "
    //   - strong
    //     - strong
    //       - text "hello"
    // - text ", "
    // - emphasis
    //   - text "what a "
    //   - strong
    //     - text "feast!"
    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.strong, @as(ast.NodeType, nodes[0].*));
    try testing.expectEqual(3, nodes[0].strong.children.len);

    const emph = nodes[0].strong.children[0];
    try testing.expectEqual(ast.NodeType.emphasis, @as(ast.NodeType, emph.*));
    try testing.expectEqual(2, emph.emphasis.children.len);
    {
        const child_text = emph.emphasis.children[0];
        try testing.expectEqual(
            ast.NodeType.text,
            @as(ast.NodeType, child_text.*),
        );
        try testing.expectEqualStrings("My, ", child_text.text.value);

        const child_strong = emph.emphasis.children[1];
        try testing.expectEqual(
            ast.NodeType.strong,
            @as(ast.NodeType, child_strong.*),
        );
        try testing.expectEqual(1, child_strong.strong.children.len);
        const grandchild_strong = child_strong.strong.children[0];
        try testing.expectEqual(
            ast.NodeType.strong,
            @as(ast.NodeType, grandchild_strong.*),
        );
        try testing.expectEqual(1, grandchild_strong.strong.children.len);
        const ggrandchild_text = grandchild_strong.strong.children[0];
        try testing.expectEqual(
            ast.NodeType.text,
            @as(ast.NodeType, ggrandchild_text.*),
        );
        try testing.expectEqualStrings("hello", ggrandchild_text.text.value);
    }

    const text = nodes[0].strong.children[1];
    try testing.expectEqual(ast.NodeType.text, @as(ast.NodeType, text.*));
    try testing.expectEqualStrings(", ", text.text.value);

    const emph2 = nodes[0].strong.children[2];
    try testing.expectEqual(ast.NodeType.emphasis, @as(ast.NodeType, emph2.*));
    try testing.expectEqual(2, emph2.emphasis.children.len);
    {
        const child_text = emph2.emphasis.children[0];
        try testing.expectEqual(
            ast.NodeType.text,
            @as(ast.NodeType, child_text.*),
        );
        try testing.expectEqualStrings("what a ", child_text.text.value);

        const child_strong = emph2.emphasis.children[1];
        try testing.expectEqual(
            ast.NodeType.strong,
            @as(ast.NodeType, child_strong.*),
        );
        try testing.expectEqual(1, child_strong.strong.children.len);
        const grandchild_text = child_strong.strong.children[0];
        try testing.expectEqual(
            ast.NodeType.text,
            @as(ast.NodeType, grandchild_text.*),
        );
        try testing.expectEqualStrings("feast!", grandchild_text.text.value);
    }
}

test "codespan and underscore emphasis" {
    const value = "`foo`_bim_`bar`";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);

    try testing.expectEqual(
        ast.NodeType.inline_code,
        @as(ast.NodeType, nodes[0].*),
    );
    try testing.expectEqualStrings(
        "foo",
        nodes[0].inline_code.value,
    );

    try testing.expectEqual(
        ast.NodeType.emphasis,
        @as(ast.NodeType, nodes[1].*),
    );
    try testing.expectEqualStrings(
        "bim",
        nodes[1].emphasis.children[0].text.value,
    );

    try testing.expectEqual(
        ast.NodeType.inline_code,
        @as(ast.NodeType, nodes[2].*),
    );
    try testing.expectEqualStrings(
        "bar",
        nodes[2].inline_code.value,
    );
}

test "codespan strip space" {
    const value = "` ``foo`` `";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(
        ast.NodeType.inline_code,
        @as(ast.NodeType, nodes[0].*),
    );
    try testing.expectEqualStrings(
        "``foo``",
        nodes[0].inline_code.value,
    );
}

test "inline link containing emphasis" {
    const value = "[*my link*]()";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(
        ast.NodeType.link,
        @as(ast.NodeType, nodes[0].*),
    );

    try testing.expectEqual(1, nodes[0].link.children.len);
    const emph = nodes[0].link.children[0];
    try testing.expectEqual(
        ast.NodeType.emphasis,
        @as(ast.NodeType, emph.*),
    );
    try testing.expectEqualStrings(
        "my link",
        emph.emphasis.children[0].text.value,
    );
}

test "inline link emphasis precedence" {
    const value = "*[foo*]()";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(2, nodes.len);

    try testing.expectEqual(
        ast.NodeType.text,
        @as(ast.NodeType, nodes[0].*),
    );
    try testing.expectEqualStrings(
        "*",
        nodes[0].text.value,
    );

    const link_node = nodes[1];
    try testing.expectEqual(
        ast.NodeType.link,
        @as(ast.NodeType, link_node.*),
    );

    try testing.expectEqual(1, link_node.link.children.len);
    try testing.expectEqual(
        ast.NodeType.text,
        @as(ast.NodeType, link_node.link.children[0].*),
    );
    try testing.expectEqualStrings(
        "foo*",
        link_node.link.children[0].text.value,
    );
}

test "inline link nesting" {
    const value = "[foo [bar]()]()";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);

    try testing.expectEqual(
        ast.NodeType.text,
        @as(ast.NodeType, nodes[0].*),
    );
    try testing.expectEqualStrings("[foo ", nodes[0].text.value);

    try testing.expectEqual(
        ast.NodeType.link,
        @as(ast.NodeType, nodes[1].*),
    );

    try testing.expectEqual(
        ast.NodeType.text,
        @as(ast.NodeType, nodes[2].*),
    );
    try testing.expectEqualStrings("]()", nodes[2].text.value);
}

test "inline link destination angle brackets" {
    const value = "[foo](<bar>)";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.link, @as(ast.NodeType, nodes[0].*));

    try testing.expectEqualStrings(nodes[0].link.url, "bar");
}

test "inline link destination no angle brackets" {
    const value = "[foo](bar)";

    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.link, @as(ast.NodeType, nodes[0].*));

    try testing.expectEqualStrings(nodes[0].link.url, "bar");
}

test "inline link with destination and title" {
    const value = "[foo](bar (baz))";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.link, @as(ast.NodeType, nodes[0].*));

    try testing.expectEqualStrings("bar", nodes[0].link.url);
    try testing.expectEqualStrings("baz", nodes[0].link.title);
}

test "URI autolink" {
    const value = "<http://foo.com/bar>";
    const nodes = try parseIntoNodes(value);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.link, @as(ast.NodeType, nodes[0].*));

    const link_node = nodes[0];
    try testing.expectEqualStrings("http://foo.com/bar", link_node.link.url);
    try testing.expectEqualStrings("", link_node.link.title);

    try testing.expectEqual(1, link_node.link.children.len);
    try testing.expectEqual(
        ast.NodeType.text,
        @as(ast.NodeType, link_node.link.children[0].*),
    );
    try testing.expectEqualStrings(
        "http://foo.com/bar",
        link_node.link.children[0].text.value,
    );
}

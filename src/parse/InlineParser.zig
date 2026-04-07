//! Parser for the second parsing stage that handles inline elements.
//!
//! This is a recursive-descent parser with backtracking.
//!
//! A naming convention used here is that parseX() functions return AST nodes
//! allocated using the non-scratch allocator, while scanX() functions return
//! strings allocated using the scratch allocator. The scanX() functions parse
//! subcomponents of recognized constructs that aren't themselves represented
//! in the final AST as nodes. Both kinds of functions are responsible for
//! backtracking to ensure that the parser is only advanced after successfully
//! parsing something.
//!
//! One of the most complicated parts of the inline parser is parsing
//! interleaved constructs with the correct precedence. We have to be able to
//! abort parsing some construct if we see a token that closes an already open
//! construct with higher precedence.
//!
//! Making sure that interleaved star- and underscore-delimited emphasis is
//! parsed correctly requires us to pass down the last opening token (of the
//! other delimiter type) through the recursive descent parser. This gives us
//! enough information to evaluate whether a closing token matches the opening
//! token and so ensure that the emphasis opening first takes precedence. (This
//! is emphasis parsing rule 15 in the CommonMark specification.)
//!
//! When inline link text is interleaved with emphasis, we must also make sure
//! that the inline link takes precedence. This is made especially challenging
//! by the fact that square brackets are allowed within link text as long as
//! they are balanced. We handle this by tracking the bracket depth through all
//! nested emphasis. A right square bracket closes link text (and aborts any
//! emphasis parsing) only when the bracket depth is 0. Brackets appearing in
//! other constructs like code spans or inline HTML aren't relevant because
//! those constructs have higher precedence than inline links.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const fmt = std.fmt;

const tokens = @import("../lex/tokens.zig");
const InlineToken = tokens.InlineToken;
const InlineTokenType = tokens.InlineTokenType;
const InlineTokenizer = @import("../lex/InlineTokenizer.zig");
const cmark = @import("../cmark/cmark.zig");
const LinkDefMap = @import("../parse/link_defs.zig").LinkDefMap;
const link_label_max_chars = @import("link_defs.zig").label_max_chars;
const util = @import("../util/util.zig");
const ast = @import("../ast.zig");
const NodeList = @import("NodeList.zig");
const alttext = @import("alttext.zig");
const escape = @import("escape.zig");

pub const Error = (
    Io.Writer.Error
    || Allocator.Error
    || cmark.character_refs.CharacterReferenceError
);

tokenizer: *InlineTokenizer,
line: ArrayList(InlineToken),
token_index: usize,
link_defs: LinkDefMap,

const Self = @This();

pub fn init(tokenizer: *InlineTokenizer, link_defs: LinkDefMap) Self {
    return .{
        .tokenizer = tokenizer,
        .line = .empty,
        .token_index = 0,
        .link_defs = link_defs,
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

    for (0..util.safety.loop_bound) |_| { // could hit if we forget to consume tokens
        _ = try self.peek(scratch) orelse break;

        if (try self.parseInlineCode(alloc, scratch)) |code| {
            try nodes.append(code);
            continue;
        }

        if (try self.parseAnyLink(alloc, scratch)) |link| {
            try nodes.append(link);
            continue;
        }

        if (try self.parseHTMLTag(alloc, scratch)) |html| {
            try nodes.append(html);
            continue;
        }

        if (try self.parseInlineImage(alloc, scratch)) |image| {
            try nodes.append(image);
            continue;
        }

        if (
            try self.parseFullReferenceImage(alloc, scratch)
        ) |image| {
            try nodes.append(image);
            continue;
        }

        if (
            try self.parseCollapsedReferenceImage(alloc, scratch)
        ) |image| {
            try nodes.append(image);
            continue;
        }

        if (
            try self.parseShortcutReferenceImage(alloc, scratch)
        ) |image| {
            try nodes.append(image);
            continue;
        }

        if (try self.parseAnyEmphasis(alloc, scratch, .{})) |emph| {
            try nodes.append(emph);
            continue;
        }

        if (try self.parseAnyStrong(alloc, scratch, .{})) |strong| {
            try nodes.append(strong);
            continue;
        }

        if (try self.parseHardLineBreak(alloc, scratch)) |brk| {
            try nodes.append(brk);
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
    } else @panic(util.safety.loop_bound_panic_msg);

    return try nodes.toOwnedSlice();
}

/// Parse star-delimited strong emphasis.
fn parseStarStrong(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
    opts: struct {
        maybe_underscore_open_token: ?InlineToken = null,
        is_link_allowed: bool = true,
        bracket_depth: ?*u32 = null,
    },
) Error!?*ast.Node {
    var did_parse = false;
    var children = NodeList.init(alloc, scratch, createTextNode);
    const checkpoint_index = self.checkpoint();

    // Track bracket depth so we know if we need to exit early because a parent
    // link text has closed (happens when we see ']' and depth is zero).
    // If we weren't given a bracket depth, just use a giant number so we
    // effectively ignore it.
    var noop_bracket_depth: u32 = std.math.maxInt(u32);
    const bracket_depth: *u32 = opts.bracket_depth orelse &noop_bracket_depth;
    const start_bracket_depth = bracket_depth.*;

    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
        bracket_depth.* = start_bracket_depth;

        for (children.items()) |child| {
            child.deinit(alloc);
        }
        children.deinit();
    };

    // strong => open inner close
    // open   => l_star l_star | lr_star lr_star
    // close  => r_star r_star | lr_star lr_star
    // inner  => (link | emph | strong | text etc.)+
    const open_token = try self.consume(scratch, &.{
        .l_delim_star,
        .lr_delim_star,
    }) orelse return null;
    _ = try self.consume(scratch, &.{
        .l_delim_star,
        .lr_delim_star,
    }) orelse return null;

    for (0..util.safety.loop_bound) |_| {
        if (try self.parseInlineCode(alloc, scratch)) |code| {
            try children.append(code);
            continue;
        }

        if (try self.parseHTMLTag(alloc, scratch)) |html| {
            try children.append(html);
            continue;
        }

        if (try self.parseInlineImage(alloc, scratch)) |image| {
            try children.append(image);
            continue;
        }

        if (try self.parseAnyLink(alloc, scratch)) |link| {
            if (!opts.is_link_allowed) {
                link.deinit(alloc);
                return null;
            }

            try children.append(link);
            continue;
        }

        if (try self.parseHardLineBreak(alloc, scratch)) |brk| {
            try children.append(brk);
            continue;
        }

        if (
            try self.parseStarEmphasis(
                alloc,
                scratch,
                .{
                    .maybe_underscore_open_token =
                        opts.maybe_underscore_open_token,
                    .is_link_allowed = opts.is_link_allowed,
                    .bracket_depth = bracket_depth,
                },
            )
        ) |emph| {
            try children.append(emph);
            continue;
        }

        if (
            try self.parseUnderscoreEmphasis(
                alloc,
                scratch,
                .{
                    .maybe_star_open_token = open_token,
                    .is_link_allowed = opts.is_link_allowed,
                    .bracket_depth = bracket_depth,
                },
            )
        ) |emph| {
            try children.append(emph);
            continue;
        }

        if (
            try self.parseStarStrong(
                alloc,
                scratch,
                .{
                    .maybe_underscore_open_token =
                        opts.maybe_underscore_open_token,
                    .is_link_allowed = opts.is_link_allowed,
                    .bracket_depth = bracket_depth,
                },
            )
        ) |strong| {
            try children.append(strong);
            continue;
        }

        if (
            try self.parseUnderscoreStrong(
                alloc,
                scratch,
                .{
                    .maybe_star_open_token = open_token,
                    .is_link_allowed = opts.is_link_allowed,
                    .bracket_depth = bracket_depth,
                },
            )
        ) |strong| {
            try children.append(strong);
            continue;
        }

        const text_value = try self.scanText(scratch);
        if (text_value.len > 0) {
            try children.appendText(text_value);
            continue;
        }

        // Check for closing condition
        const can_close = blk: {
            const token = try self.peek(scratch) orelse break :blk false;
            const close_token_type = switch (token.token_type) {
                .r_delim_star, .lr_delim_star => |t| t,
                .r_delim_underscore, .lr_delim_underscore => {
                    // Handle interleaved emphasis.
                    const underscore_open_token = (
                        opts.maybe_underscore_open_token
                        orelse break :blk false
                    );
                    if (isValidBySumOfLengthsRule(underscore_open_token, token)) {
                        // Ancestor closes before this emphasis can close.
                        // Give up.
                        return null;
                    }

                    break :blk false;
                },
                .l_square_bracket => {
                    // saturating addition
                    bracket_depth.* +|= 1;
                    break :blk false;
                },
                .r_square_bracket => {
                    if (bracket_depth.* == 0) {
                        // Ancestor link text closes before this emphasis can.
                        // Give up.
                        return null;
                    }

                    bracket_depth.* -= 1;
                    break :blk false;
                },
                else => break :blk false,
            };

            const next = try self.peekAhead(scratch, 2) orelse break :blk false;
            if (next.token_type != close_token_type) {
                break :blk false;
            }

            break :blk isValidBySumOfLengthsRule(open_token, token);
        };
        if (can_close) {
            break;
        }

        const text_fallback_value = try self.scanTextFallback(scratch);
        if (text_fallback_value.len > 0) {
            try children.appendText(text_fallback_value);
            continue;
        }

        break;
    } else @panic(util.safety.loop_bound_panic_msg);

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

    const node = try alloc.create(ast.Node);
    errdefer alloc.destroy(node);
    const owned = try children.toOwnedSlice();
    node.* = .{
        .tag = .strong,
        .payload = .{
            .strong = .{
                .children = owned.ptr,
                .n_children = @intCast(owned.len),
            },
        },
    };
    did_parse = true;
    return node;
}

/// Parse emphasis using star delimiters.
///
/// We don't allow star-delimited emphasis to nest immediately inside each
/// other. (That should get parsed as strong.)
fn parseStarEmphasis(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
    opts: struct {
        maybe_underscore_open_token: ?InlineToken = null,
        is_link_allowed: bool = true,
        bracket_depth: ?*u32 = null,
    },
) Error!?*ast.Node {
    var did_parse = false;
    var children = NodeList.init(alloc, scratch, createTextNode);
    const checkpoint_index = self.checkpoint();

    // Track bracket depth so we know if we need to exit early because a parent
    // link text has closed (happens when we see ']' and depth is zero).
    // If we weren't given a bracket depth, just use a giant number so we
    // effectively ignore it.
    var noop_bracket_depth: u32 = std.math.maxInt(u32);
    const bracket_depth: *u32 = opts.bracket_depth orelse &noop_bracket_depth;
    const start_bracket_depth = bracket_depth.*;

    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
        bracket_depth.* = start_bracket_depth;

        for (children.items()) |child| {
            child.deinit(alloc);
        }
        children.deinit();
    };

    // star_emph  => open inner close
    // open  => l_star | lr_star
    // close => r_star | lr_star
    // inner => (star_emph? (non-text | text) star_emph?)+
    // non-text => image | link | strong | code etc. etc.
    const open_token = try self.consume(scratch, &.{
        .l_delim_star,
        .lr_delim_star,
    }) orelse return null;

    for (0..util.safety.loop_bound) |_| {
        var did_parse_this_loop = false;

        // leading star_emph?
        const maybe_leading_emph = try self.parseStarEmphasis(
            alloc,
            scratch,
            .{
                .maybe_underscore_open_token = opts.maybe_underscore_open_token,
                .is_link_allowed = opts.is_link_allowed,
                .bracket_depth = bracket_depth,
            },
        );
        defer if (!did_parse_this_loop) {
            if (maybe_leading_emph) |emph| {
                emph.deinit(alloc);
            }
        };

        // Handle non-text nodes
        if (blk: {
            if (try self.parseInlineCode(alloc, scratch)) |code| {
                break :blk code;
            }

            if (try self.parseHTMLTag(alloc, scratch)) |html| {
                break :blk html;
            }

            if (try self.parseInlineImage(alloc, scratch)) |image| {
                break :blk image;
            }

            if (try self.parseAnyLink(alloc, scratch)) |link| {
                if (!opts.is_link_allowed) {
                    link.deinit(alloc);
                    return null;
                }

                break :blk link;
            }

            if (try self.parseHardLineBreak(alloc, scratch)) |brk| {
                break :blk brk;
            }

            if (
                try self.parseUnderscoreEmphasis(
                    alloc,
                    scratch,
                    .{
                        .maybe_star_open_token = open_token,
                        .is_link_allowed = opts.is_link_allowed,
                        .bracket_depth = bracket_depth,
                    },
                )
            ) |emph| {
                break :blk emph;
            }

            if (
                try self.parseStarStrong(
                    alloc,
                    scratch,
                    .{
                        .maybe_underscore_open_token =
                            opts.maybe_underscore_open_token,
                        .is_link_allowed = opts.is_link_allowed,
                        .bracket_depth = bracket_depth,
                    },
                )
            ) |strong| {
                try children.append(strong);
                continue;
            }

            if (
                try self.parseUnderscoreStrong(
                    alloc,
                    scratch,
                    .{
                        .maybe_star_open_token = open_token,
                        .is_link_allowed = opts.is_link_allowed,
                        .bracket_depth = bracket_depth,
                    },
                )
            ) |strong| {
                try children.append(strong);
                continue;
            }

            break :blk null;
        }) |node| {
            if (maybe_leading_emph) |emph| {
                try children.append(emph);
            }
            try children.append(node);

            // trailing star_emph?
            if (
                try self.parseStarEmphasis(
                    alloc,
                    scratch,
                    .{
                        .maybe_underscore_open_token = opts.maybe_underscore_open_token,
                        .is_link_allowed = opts.is_link_allowed,
                        .bracket_depth = bracket_depth,
                    },
                )
            ) |emph| {
                try children.append(emph);
            }

            did_parse_this_loop = true;
            continue;
        }

        // Handle text node. Here we need to make sure not to consume a closing
        // delimiter.
        const text_content = blk: {
            const text_value = try self.scanText(scratch);
            if (text_value.len > 0) {
                break :blk text_value;
            }

            // Check for closing condition
            const token = try self.peek(scratch) orelse break :blk "";
            swtch: switch (token.token_type) {
                .r_delim_star, .lr_delim_star => {
                    if (isValidBySumOfLengthsRule(open_token, token)) {
                        break :blk "";
                    }
                },
                .r_delim_underscore, .lr_delim_underscore => {
                    // Handle interleaved emphasis. If we are nested within
                    // another emphasis, check if this could be the close
                    // token.
                    const underscore_open_token = (
                        opts.maybe_underscore_open_token
                        orelse break :swtch
                    );
                    if (isValidBySumOfLengthsRule(underscore_open_token, token)) {
                        // Ancestor closes before this emphasis can close.
                        // Give up.
                        return null;
                    }
                },
                .l_square_bracket => {
                    // saturating addition
                    bracket_depth.* +|= 1;
                },
                .r_square_bracket => {
                    if (bracket_depth.* == 0) {
                        // Link text closes before this emphasis can close.
                        // Give up.
                        return null;
                    }

                    bracket_depth.* -= 1;
                },
                else => {},
            }

            // Okay, if we don't have a closing condition, allow basically
            // anything.
            const fallback_text_value = try self.scanTextFallback(scratch);
            break :blk fallback_text_value;
        };
        if (text_content.len > 0) {
            if (maybe_leading_emph) |emph| {
                try children.append(emph);
            }
            try children.appendText(text_content);

            // trailing star_emph?
            if (
                try self.parseStarEmphasis(
                    alloc,
                    scratch,
                    .{
                        .maybe_underscore_open_token = opts.maybe_underscore_open_token,
                        .is_link_allowed = opts.is_link_allowed,
                        .bracket_depth = bracket_depth,
                    },
                )
            ) |emph| {
                try children.append(emph);
            }

            did_parse_this_loop = true;
            continue;
        }

        // We failed to parse anything valid this loop. If we parsed just a
        // single emphasis node, that's not allowed.
        if (maybe_leading_emph) |_| {
            return null;
        }

        // Reached end of interior content
        break;
    } else @panic(util.safety.loop_bound_panic_msg);

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

    const emphasis_node = try alloc.create(ast.Node);
    errdefer alloc.destroy(emphasis_node);
    const owned = try children.toOwnedSlice();
    emphasis_node.* = .{
        .tag = .emphasis,
        .payload = .{
            .emphasis = .{
                .children = owned.ptr,
                .n_children = @intCast(owned.len),
            },
        },
    };
    did_parse = true;
    return emphasis_node;
}

/// Parse underscore-delimited strong emphasis.
fn parseUnderscoreStrong(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
    opts: struct {
        maybe_star_open_token: ?InlineToken = null,
        is_link_allowed: bool = true,
        bracket_depth: ?*u32 = null,
    },
) Error!?*ast.Node {
    var did_parse = false;
    var children = NodeList.init(alloc, scratch, createTextNode);
    const checkpoint_index = self.checkpoint();

    // Track bracket depth so we know if we need to exit early because a parent
    // link text has closed (happens when we see ']' and depth is zero).
    // If we weren't given a bracket depth, just use a giant number so we
    // effectively ignore it.
    var noop_bracket_depth: u32 = std.math.maxInt(u32);
    const bracket_depth: *u32 = opts.bracket_depth orelse &noop_bracket_depth;
    const start_bracket_depth = bracket_depth.*;

    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
        bracket_depth.* = start_bracket_depth;

        for (children.items()) |child| {
            child.deinit(alloc);
        }
        children.deinit();
    };

    // strong => open inner close
    // open   => l_star l_star | lr_star lr_star
    // close  => r_star r_star | lr_star lr_star
    // inner  => (link | emph | strong | text)+
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

    for (0..util.safety.loop_bound) |_| {
        if (try self.parseInlineCode(alloc, scratch)) |code| {
            try children.append(code);
            continue;
        }

        if (try self.parseHTMLTag(alloc, scratch)) |html| {
            try children.append(html);
            continue;
        }

        if (try self.parseInlineImage(alloc, scratch)) |image| {
            try children.append(image);
            continue;
        }

        if (try self.parseAnyLink(alloc, scratch)) |link| {
            if (!opts.is_link_allowed) {
                link.deinit(alloc);
                return null;
            }

            try children.append(link);
            continue;
        }

        if (try self.parseHardLineBreak(alloc, scratch)) |brk| {
            try children.append(brk);
            continue;
        }

        if (
            try self.parseStarEmphasis(
                alloc,
                scratch,
                .{
                    .maybe_underscore_open_token = open_token,
                    .is_link_allowed = opts.is_link_allowed,
                    .bracket_depth = bracket_depth,
                },
            )
        ) |emph| {
            try children.append(emph);
            continue;
        }

        if (
            try self.parseUnderscoreEmphasis(
                alloc,
                scratch,
                .{
                    .maybe_star_open_token =
                        opts.maybe_star_open_token,
                    .is_link_allowed = opts.is_link_allowed,
                    .bracket_depth = bracket_depth,
                },
            )
        ) |emph| {
            try children.append(emph);
            continue;
        }

        if (
            try self.parseStarStrong(
                alloc,
                scratch,
                .{
                    .maybe_underscore_open_token = open_token,
                    .is_link_allowed = opts.is_link_allowed,
                    .bracket_depth = bracket_depth,
                },
            )
        ) |strong| {
            try children.append(strong);
            continue;
        }

        if (
            try self.parseUnderscoreStrong(
                alloc,
                scratch,
                .{
                    .maybe_star_open_token =
                        opts.maybe_star_open_token,
                    .is_link_allowed = opts.is_link_allowed,
                    .bracket_depth = bracket_depth,
                },
            )
        ) |strong| {
            try children.append(strong);
            continue;
        }

        const text_value = try self.scanText(scratch);
        if (text_value.len > 0) {
            try children.appendText(text_value);
            continue;
        }

        // Check for closing condition
        const can_close = blk: {
            const token = try self.peek(scratch) orelse break :blk false;
            const close_token_type = switch (token.token_type) {
                .r_delim_underscore, .lr_delim_underscore => |t| t,
                .r_delim_star, .lr_delim_star => {
                    // Handle interleaved emphasis.
                    const star_open_token = (
                        opts.maybe_star_open_token
                        orelse break :blk false
                    );
                    if (isValidBySumOfLengthsRule(star_open_token, token)) {
                        // Ancestor closes before this emphasis can close.
                        // Give up.
                        return null;
                    }

                    break :blk false;
                },
                .l_square_bracket => {
                    // saturating addition
                    bracket_depth.* +|= 1;
                    break :blk false;
                },
                .r_square_bracket => {
                    if (bracket_depth.* == 0) {
                        // Ancestor link text closes before this emphasis can.
                        // Give up.
                        return null;
                    }

                    bracket_depth.* -= 1;
                    break :blk false;
                },
                else => break :blk false,
            };

            const next = try self.peekAhead(scratch, 2) orelse break :blk false;
            if (next.token_type != close_token_type) {
                break :blk false;
            }

            break :blk isValidBySumOfLengthsRule(open_token, token);
        };
        if (can_close) {
            break;
        }

        const text_fallback_value = try self.scanTextFallback(scratch);
        if (text_fallback_value.len > 0) {
            try children.appendText(text_fallback_value);
            continue;
        }

        break;
    } else @panic(util.safety.loop_bound_panic_msg);

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

    const strong_node = try alloc.create(ast.Node);
    errdefer alloc.destroy(strong_node);
    const owned = try children.toOwnedSlice();
    strong_node.* = .{
        .tag = .strong,
        .payload = .{
            .strong = .{
                .children = owned.ptr,
                .n_children = @intCast(owned.len),
            },
        },
    };
    did_parse = true;
    return strong_node;
}

/// Parse underscore-delimited emphasis.
///
/// We don't allow underscore-delimited emphasis to nest immediately inside
/// each other. (That should get parsed as strong.)
fn parseUnderscoreEmphasis(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
    opts: struct {
        maybe_star_open_token: ?InlineToken = null,
        is_link_allowed: bool = true,
        bracket_depth: ?*u32 = null,
    },
) Error!?*ast.Node {
    var did_parse = false;
    var children = NodeList.init(alloc, scratch, createTextNode);
    const checkpoint_index = self.checkpoint();

    // Track bracket depth so we know if we need to exit early because a parent
    // link text has closed (happens when we see ']' and depth is zero).
    // If we weren't given a bracket depth, just use a giant number so we
    // effectively ignore it.
    var noop_bracket_depth: u32 = std.math.maxInt(u32);
    const bracket_depth: *u32 = opts.bracket_depth orelse &noop_bracket_depth;
    const start_bracket_depth = bracket_depth.*;

    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
        bracket_depth.* = start_bracket_depth;

        for (children.items()) |child| {
            child.deinit(alloc);
        }
        children.deinit();
    };

    // under_emph  => open inner close
    // open  => l_underscore | lr_underscore
    // close => r_underscore | lr_underscore
    // inner => (under_emph? (non-text | text) under_emph?)+
    // non-text => image | link | strong etc. etc.
    const open_token = try self.peek(scratch) orelse return null;
    switch (open_token.token_type) {
        .l_delim_underscore => {
            _ = try self.consume(scratch, &.{.l_delim_underscore});
        },
        .lr_delim_underscore => {
            // Can only open emphasis if delimiter run follows punctuation
            if (!open_token.context.delim_underscore.preceded_by_punct) {
                return null;
            }

            _ = try self.consume(scratch, &.{.lr_delim_underscore});
        },
        else => return null,
    }

    for (0..util.safety.loop_bound) |_| {
        var did_parse_this_loop = false;

        // leading under_emph?
        const maybe_leading_emph = try self.parseUnderscoreEmphasis(
            alloc,
            scratch,
            .{
                .maybe_star_open_token = opts.maybe_star_open_token,
                .is_link_allowed = opts.is_link_allowed,
                .bracket_depth = bracket_depth,
            },
        );
        defer if (!did_parse_this_loop) {
            if (maybe_leading_emph) |emph| {
                emph.deinit(alloc);
            }
        };

        // Handle non-text nodes
        if (blk: {
            if (try self.parseInlineCode(alloc, scratch)) |code| {
                break :blk code;
            }

            if (try self.parseHTMLTag(alloc, scratch)) |html| {
                break :blk html;
            }

            if (try self.parseInlineImage(alloc, scratch)) |image| {
                break :blk image;
            }

            if (try self.parseAnyLink(alloc, scratch)) |link| {
                if (!opts.is_link_allowed) {
                    link.deinit(alloc);
                    return null;
                }

                break :blk link;
            }

            if (try self.parseHardLineBreak(alloc, scratch)) |brk| {
                break :blk brk;
            }

            if (try self.parseStarEmphasis(
                    alloc,
                    scratch,
                    .{
                        .maybe_underscore_open_token = open_token,
                        .is_link_allowed = opts.is_link_allowed,
                        .bracket_depth = bracket_depth,
                    },
                )
            ) |emph| {
                break :blk emph;
            }

            if (
                try self.parseStarStrong(
                    alloc,
                    scratch,
                    .{
                        .maybe_underscore_open_token = open_token,
                        .is_link_allowed = opts.is_link_allowed,
                        .bracket_depth = bracket_depth,
                    },
                )
            ) |strong| {
                try children.append(strong);
                continue;
            }

            if (
                try self.parseUnderscoreStrong(
                    alloc,
                    scratch,
                    .{
                        .maybe_star_open_token =
                            opts.maybe_star_open_token,
                        .is_link_allowed = opts.is_link_allowed,
                        .bracket_depth = bracket_depth,
                    },
                )
            ) |strong| {
                try children.append(strong);
                continue;
            }

            break :blk null;
        }) |node| {
            if (maybe_leading_emph) |emph| {
                try children.append(emph);
            }
            try children.append(node);

            // trailing under_emph?
            if (
                try self.parseUnderscoreEmphasis(
                    alloc,
                    scratch,
                    .{
                        .maybe_star_open_token = opts.maybe_star_open_token,
                        .is_link_allowed = opts.is_link_allowed,
                        .bracket_depth = bracket_depth,
                    },
                )
            ) |emph| {
                try children.append(emph);
            }

            did_parse_this_loop = true;
            continue;
        }

        // Handle text node. Here we need to make sure not to consume the
        // closing delimiter.
        const text_content = blk: {
            const text_value = try self.scanText(scratch);
            if (text_value.len > 0) {
                break :blk text_value;
            }

            // Check for closing condition
            const token = try self.peek(scratch) orelse break :blk "";
            swtch: switch (token.token_type) {
                .r_delim_underscore, .lr_delim_underscore => {
                    if (isValidBySumOfLengthsRule(open_token, token)) {
                        break :blk "";
                    }
                },
                .r_delim_star, .lr_delim_star => {
                    // Handle interleaved emphasis. If we are nested within
                    // another emphasis, check if this could be the close
                    // token.
                    const star_open_token = (
                        opts.maybe_star_open_token orelse break :swtch
                    );
                    if (isValidBySumOfLengthsRule(star_open_token, token)) {
                        // Ancestor closes before this emphasis can close.
                        // Give up.
                        return null;
                    }
                },
                .l_square_bracket => {
                    // saturating addition
                    bracket_depth.* +|= 1;
                },
                .r_square_bracket => {
                    if (bracket_depth.* == 0) {
                        // Link text closes before this emphasis can close.
                        // Give up.
                        return null;
                    }

                    bracket_depth.* -= 1;
                },
                else => {},
            }

            // Okay, if we don't have a closing delimiter, allow basically
            // anything.
            const fallback_text_value = try self.scanTextFallback(scratch);
            break :blk fallback_text_value;
        };
        if (text_content.len > 0) {
            if (maybe_leading_emph) |emph| {
                try children.append(emph);
            }
            try children.appendText(text_content);

            // trailing under_emph?
            if (
                try self.parseUnderscoreEmphasis(
                    alloc,
                    scratch,
                    .{
                        .maybe_star_open_token = opts.maybe_star_open_token,
                        .is_link_allowed = opts.is_link_allowed,
                        .bracket_depth = bracket_depth,
                    },
                )
            ) |emph| {
                try children.append(emph);
            }

            did_parse_this_loop = true;
            continue;
        }

        // We failed to parse anything valid this loop. If we parsed just a
        // single emphasis node, that's not allowed.
        if (maybe_leading_emph) |_| {
            return null;
        }

        // Reached end of interior content
        break;
    } else @panic(util.safety.loop_bound_panic_msg);

    try children.flush();
    if (children.len() == 0) {
        return null;
    }

    const close_token = try self.peek(scratch) orelse return null;
    switch (close_token.token_type) {
        .r_delim_underscore => {
            _ = try self.consume(scratch, &.{.r_delim_underscore});
        },
        .lr_delim_underscore => {
            // Can only close emphasis if delimiter run is followed by
            // punctuation.
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

    const emphasis_node = try alloc.create(ast.Node);
    errdefer alloc.destroy(emphasis_node);
    const owned = try children.toOwnedSlice();
    emphasis_node.* = .{
        .tag = .emphasis,
        .payload = .{
            .emphasis = .{
                .children = owned.ptr,
                .n_children = @intCast(owned.len),
            },
        },
    };
    did_parse = true;
    return emphasis_node;
}

/// Checks commonmark spec rule 9. and 10. for parsing emphasis and strong
/// emphasis. Returns true if the emphasis is valid, false otherwise.
///
/// Delimiter run length comes from token context.
///
/// This function trivially evaluates to true if neither the open nor the close
/// token is an lr delimiter.
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
                and close.context.delim_star.run_len % 3 == 0
            );
        }
    }

    if (
        open.token_type == .lr_delim_underscore
        or close.token_type == .lr_delim_underscore
    ) {
        const sum_of_len = (
            open.context.delim_underscore.run_len
            + close.context.delim_underscore.run_len
        );
        if (sum_of_len % 3 == 0) {
            return (
                open.context.delim_underscore.run_len % 3 == 0
                and close.context.delim_underscore.run_len % 3 == 0
            );
        }
    }

    return true;
}

/// Parses either star- or underscore-delimited emphasis.
///
/// Shouldn't be used to parse nested emphasis.
fn parseAnyEmphasis(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
    opts: struct {
        is_link_allowed: bool = true,
        bracket_depth: ?*u32 = null,
    },
) Error!?*ast.Node {
    if (try self.parseStarEmphasis(
            alloc,
            scratch,
            .{
                .is_link_allowed = opts.is_link_allowed,
                .bracket_depth = opts.bracket_depth,
            },
        )
    ) |emph| {
        return emph;
    }

    if (try self.parseUnderscoreEmphasis(
            alloc,
            scratch,
            .{
                .is_link_allowed = opts.is_link_allowed,
                .bracket_depth = opts.bracket_depth,
            },
        )
    ) |emph| {
        return emph;
    }

    return null;
}

/// Parses either star- or underscore-delimited strong emphasis.
///
/// Shouldn't be used to parse nested strong emphasis.
fn parseAnyStrong(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
    opts: struct {
        is_link_allowed: bool = true,
        bracket_depth: ?*u32 = null,
    },
) Error!?*ast.Node {
    if (try self.parseStarStrong(
            alloc,
            scratch,
            .{
                .is_link_allowed = opts.is_link_allowed,
                .bracket_depth = opts.bracket_depth,
            },
        )
    ) |strong| {
        return strong;
    }

    if (try self.parseUnderscoreStrong(
            alloc,
            scratch,
            .{
                .is_link_allowed = opts.is_link_allowed,
                .bracket_depth = opts.bracket_depth,
            },
        )
    ) |strong| {
        return strong;
    }

    return null;
}

/// Parses an inline code span.
///
/// Inline code spans must be surrouned by backticks.
fn parseInlineCode(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    // @ => backtick(n) .+ backtick(n)
    const open = try self.consume(scratch, &.{ .backtick }) orelse return null;

    var values: ArrayList([]const u8) = .empty;
    for (0..util.safety.loop_bound) |_| {
        const token = try self.peek(scratch) orelse return null;
        switch (token.token_type) {
            .backtick => {
                _ = try self.consume(scratch, &.{ .backtick });
                if (token.lexeme.len == open.lexeme.len) {
                    break;
                }

                const value = try emitInlineCode(scratch, token);
                try values.append(scratch, value);
            },
            .escaped_backtick => {
                // Backslash-escaping is not allowed in code spans. Treat as a
                // backslash followed by a backtick.
                _ = try self.consume(scratch, &.{ .escaped_backtick });
                try values.append(scratch, "\\");

                if (try self.consume(scratch, &.{.backtick})) |following| {
                    // Handle case where escaped backtick should be counted
                    // with folloiwng backticks.
                    const backtick_count = following.lexeme.len + 1;
                    if (open.lexeme.len == backtick_count) {
                        break;
                    }

                    const value_escaped = try emitInlineCode(scratch, token);
                    const value_following = try emitInlineCode(
                        scratch,
                        following,
                    );
                    try values.append(scratch, value_escaped);
                    try values.append(scratch, value_following);
                } else {
                    // No following backticks, so we just have a single
                    // backtick.
                    if (open.lexeme.len == 1) {
                        break;
                    }

                    const value = try emitInlineCode(scratch, token);
                    try values.append(scratch, value);
                }
            },
            else => |t| {
                _ = try self.consume(scratch, &.{t});

                const value = try emitInlineCode(scratch, token);
                try values.append(scratch, value);
            }
        }
    } else @panic(util.safety.loop_bound_panic_msg);

    if (values.items.len == 0) {
        return null;
    }

    var value = try std.mem.join(scratch, "", values.items);

    // Special case for stripping single leading and following space
    if (value.len > 1 and !util.strings.containsOnly(value, " ")) {
        if (value[0] == ' ' and value[value.len - 1] == ' ') {
            value = value[1..value.len - 1];
        }
    }

    const value_copy = try alloc.dupeZ(u8, value);
    errdefer alloc.free(value_copy);

    const inline_code_node = try alloc.create(ast.Node);
    inline_code_node.* = .{
        .tag = .inline_code,
        .payload = .{
            .inline_code = .{
                .value = value_copy.ptr,
            },
        },
    };
    did_parse = true;
    return inline_code_node;
}

/// Parses an inline link looking like `[foo](bar.com/url)`.
fn parseInlineLink(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    // @ => link_text l_paren (link_dest link_title?)? r_paren

    // handle link text
    const link_text_nodes = (
        try self.parseLinkText(alloc, scratch) orelse return null
    );
    defer if (!did_parse) {
        for (link_text_nodes) |node| {
            node.deinit(alloc);
        }
        alloc.free(link_text_nodes);
    };

    var newline_count: u8 = 0;
    _ = try self.consume(scratch, &.{.l_paren}) orelse return null;

    while (try self.consume(scratch, &.{.newline, .whitespace})) |token| {
        if (token.token_type == .newline) {
            newline_count += 1;
        }
    }

    // link destination
    const raw_url = try self.scanLinkDestination(scratch) orelse "";
    const url = try cmark.uri.normalize(scratch, scratch, raw_url);

    const title = blk: {
        // link title, if present, must be separated from destination by
        // whitespace
        var consumed_whitespace_or_newline = false;
        while (try self.consume(scratch, &.{.newline, .whitespace})) |token| {
            if (token.token_type == .newline) {
                newline_count += 1;
            }

            consumed_whitespace_or_newline = true;
        }

        if (consumed_whitespace_or_newline) {
            break :blk try self.scanLinkTitle(scratch) orelse "";
        }

        break :blk "";
    };

    while (try self.consume(scratch, &.{.newline, .whitespace})) |token| {
        if (token.token_type == .newline) {
            newline_count += 1;
        }
    }
    _ = try self.consume(scratch, &.{.r_paren}) orelse return null;

    if (newline_count > 1) {
        return null; // up to one newline allowed
    }

    const ownedUrl = try alloc.dupeZ(u8, url);
    errdefer alloc.free(ownedUrl);
    const ownedTitle = try alloc.dupeZ(u8, title);
    errdefer alloc.free(ownedTitle);
    const inline_link = try alloc.create(ast.Node);
    inline_link.* = .{
        .tag = .link,
        .payload = .{
            .link = .{
                .url = ownedUrl,
                .title = ownedTitle,
                .children = link_text_nodes.ptr,
                .n_children = @intCast(link_text_nodes.len),
            },
        },
    };
    did_parse = true;
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
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
        for (nodes.items()) |node| {
            node.deinit(alloc);
        }
        nodes.deinit();
    };

    _ = try self.consume(scratch, &.{.l_square_bracket}) orelse return null;

    var bracket_depth: u32 = 0;
    loop: for (0..util.safety.loop_bound) |_| {
        if (try self.parseInlineImage(alloc, scratch)) |image| {
            try nodes.append(image);
            continue;
        }

        if (try self.parseAnyLink(alloc, scratch)) |link| {
            try nodes.append(link); // ensure it gets cleaned up
            return null; // nested links are not allowed!
        }

        if (try self.parseInlineCode(alloc, scratch)) |code| {
            try nodes.append(code);
            continue;
        }

        if (try self.parseHTMLTag(alloc, scratch)) |html| {
            try nodes.append(html);
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
            const value = try emitInlineText(scratch, token);
            break :blk value;
        };
        if (allowed_bracket.len > 0) {
            try nodes.appendText(allowed_bracket);
            continue;
        }

        if (try self.parseHardLineBreak(alloc, scratch)) |brk| {
            try nodes.append(brk);
            continue;
        }

        if (try self.parseAnyEmphasis(
                alloc,
                scratch,
                .{
                    .is_link_allowed = false,
                    .bracket_depth = &bracket_depth,
                },
            )
        ) |emph| {
            try nodes.append(emph);
            continue;
        }

        if (try self.parseAnyStrong(
                alloc,
                scratch,
                .{
                    .is_link_allowed = false,
                    .bracket_depth = &bracket_depth,
                },
            )
        ) |strong| {
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
    } else @panic(util.safety.loop_bound_panic_msg);

    _ = try self.consume(scratch, &.{.r_square_bracket}) orelse return null;

    if (bracket_depth > 0) {
        return null; // contained unbalanced brackets
    }

    did_parse = true;
    return try nodes.toOwnedSlice();
}

/// Parses the URL for a link, which can be either:
/// <foobar>
/// or
/// nonempty sequence without a space (or unbalanced parens)
fn scanLinkDestination(self: *Self, scratch: Allocator) !?[]const u8 {
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
                else => |t| {
                    _ = try self.consume(scratch, &.{t});
                    const value = try emitInlineText(scratch, token);
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
                    const value = try emitInlineText(scratch, token);
                    _ = try running_text.writer.write(value);
                },
                .r_paren => {
                    if (paren_depth == 0) {
                        break;
                    }

                    paren_depth -= 1;
                    _ = try self.consume(scratch, &.{.r_paren});
                    const value = try emitInlineText(scratch, token);
                    _ = try running_text.writer.write(value);
                },
                .whitespace, .newline => break,
                else => |t| {
                    _ = try self.consume(scratch, &.{t});
                    const value = try emitInlineText(scratch, token);
                    if (util.strings.containsAsciiControl(value)) {
                        return "";
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

/// Title part of an inline link.
///
/// Should be enclosed in () or "" or ''. Can span multiple lines but cannot
/// contain a blank line.
fn scanLinkTitle(self: *Self, scratch: Allocator) !?[]const u8 {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    var running_text = Io.Writer.Allocating.init(scratch);

    const open = try self.consume(
        scratch,
        &.{.l_paren, .single_quote, .double_quote},
    ) orelse return null;

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
                const value = try emitInlineText(scratch, token);
                _ = try running_text.writer.write(value);

                blank_line_so_far = true;
            },
            .whitespace => {
                _ = try self.consume(scratch, &.{.whitespace});
                const value = try emitInlineText(scratch, token);
                _ = try running_text.writer.write(value);
            },
            else => |t| {
                if (t == close_t) {
                    break;
                }

                _ = try self.consume(scratch, &.{t});
                const value = try emitInlineText(scratch, token);
                _ = try running_text.writer.write(value);
                blank_line_so_far = false;
            },
        }
    }
    _ = try self.consume(scratch, &.{close_t}) orelse return null;

    did_parse = true;
    return try running_text.toOwnedSlice();
}

/// Scans spaces, tabs, and up to one newline.
fn scanSeparatingWhitespace(self: *Self, scratch: Allocator) Error!?[]const u8 {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    var running_text = Io.Writer.Allocating.init(scratch);

    var seen_newline = false;
    while (try self.consume(scratch, &.{.newline, .whitespace})) |token| {
        if (token.token_type == .newline) {
            if (seen_newline) {
                return null;
            }
            seen_newline = true;
        }

        const value = try emitInlineText(scratch, token);
        _ = try running_text.writer.write(value);
    }

    did_parse = true;
    return try running_text.toOwnedSlice();
}

/// Parse link looking like `[foo][ref]`.
///
/// https://spec.commonmark.org/0.30/#full-reference-link
fn parseFullReferenceLink(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    // handle link text
    const link_text_nodes = (
        try self.parseLinkText(alloc, scratch) orelse return null
    );
    defer if (!did_parse) {
        for (link_text_nodes) |node| {
            node.deinit(alloc);
        }
        alloc.free(link_text_nodes);
    };

    // handle link label
    const scanned_link_label = (
        try self.scanLinkLabel(scratch) orelse return null
    );

    // lookup link def
    const link_def = try self.link_defs.get(
        scratch,
        scanned_link_label,
    ) orelse return null; // no matching def means parse failure

    const url = try alloc.dupeZ(u8, std.mem.span(link_def.url));
    errdefer alloc.free(url);
    const title = try alloc.dupeZ(u8, std.mem.span(link_def.title));
    errdefer alloc.free(title);

    const link_node = try alloc.create(ast.Node);
    link_node.* = .{
        .tag = .link,
        .payload = .{
            .link = .{
                .url = url,
                .title = title,
                .children = link_text_nodes.ptr,
                .n_children = @intCast(link_text_nodes.len),
            },
        },
    };
    did_parse = true;
    return link_node;
}

/// Parse link looking like `[ref][]`.
///
/// We parse the leading label twice, first as a string label and again as
/// inline content.
///
/// https://spec.commonmark.org/0.30/#collapsed-reference-link
fn parseCollapsedReferenceLink(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    // handle link label
    const scanned_link_label = (
        try self.scanLinkLabel(scratch) orelse return null
    );

    _ = try self.consume(scratch, &.{.l_square_bracket}) orelse return null;
    _ = try self.consume(scratch, &.{.r_square_bracket}) orelse return null;

    // lookup link def
    const link_def = try self.link_defs.get(
        scratch,
        scanned_link_label,
    ) orelse return null; // no matching def means parse failure

    // !! re-parse label as inline content !!
    self.backtrack(checkpoint_index);
    const inline_nodes = (
        try self.parseLinkLabel(alloc, scratch) orelse return null
    );
    defer if (!did_parse) {
        for (inline_nodes) |node| {
            node.deinit(alloc);
        }
        alloc.free(inline_nodes);
    };

    // re-consume trailing "[]"
    _ = try self.consume(scratch, &.{.l_square_bracket}) orelse unreachable;
    _ = try self.consume(scratch, &.{.r_square_bracket}) orelse unreachable;

    const url = try alloc.dupeZ(u8, std.mem.span(link_def.url));
    errdefer alloc.free(url);
    const title = try alloc.dupeZ(u8, std.mem.span(link_def.title));
    errdefer alloc.free(title);

    const link_node = try alloc.create(ast.Node);
    link_node.* = .{
        .tag = .link,
        .payload = .{
            .link = .{
                .url = url,
                .title = title,
                .children = inline_nodes.ptr,
                .n_children = @intCast(inline_nodes.len),
            },
        },
    };
    did_parse = true;
    return link_node;
}

/// Parse link looking like `[ref]`.
///
/// https://spec.commonmark.org/0.30/#shortcut-reference-link
fn parseShortcutReferenceLink(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    // handle link label
    const scanned_link_label = (
        try self.scanLinkLabel(scratch) orelse return null
    );

    // lookup link def
    const link_def = try self.link_defs.get(
        scratch,
        scanned_link_label,
    ) orelse return null; // no matching def means parse failure

    // !! re-parse label as inline content !!
    self.backtrack(checkpoint_index);
    const inline_nodes = (
        try self.parseLinkLabel(alloc, scratch) orelse return null
    );
    defer if (!did_parse) {
        for (inline_nodes) |node| {
            node.deinit(alloc);
        }
        alloc.free(inline_nodes);
    };

    const url = try alloc.dupeZ(u8, std.mem.span(link_def.url));
    errdefer alloc.free(url);
    const title = try alloc.dupeZ(u8, std.mem.span(link_def.title));
    errdefer alloc.free(title);

    const link_node = try alloc.create(ast.Node);
    link_node.* = .{
        .tag = .link,
        .payload = .{
            .link = .{
                .url = url,
                .title = title,
                .children = inline_nodes.ptr,
                .n_children = @intCast(inline_nodes.len),
            },
        },
    };
    did_parse = true;
    return link_node;
}

/// Scans a link label, returning a string.
fn scanLinkLabel(self: *Self, scratch: Allocator) Error!?[]const u8 {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    var running_text = Io.Writer.Allocating.init(scratch);

    _ = try self.consume(
        scratch,
        &.{.l_square_bracket},
    ) orelse return null;

    var saw_non_blank = false;
    while (try self.peek(scratch)) |token| {
        switch (token.token_type) {
            .whitespace => {
                _ = try self.consume(scratch, &.{.whitespace});
                const value = try emitInlineText(scratch, token);
                _ = try running_text.writer.write(value);
            },
            .newline => {
                _ = try self.consume(scratch, &.{.newline});
                const value = try emitInlineText(scratch, token);
                _ = try running_text.writer.write(value);
            },
            .l_square_bracket => return null,
            .r_square_bracket => break,
            else => |t| {
                saw_non_blank = true;
                _ = try self.consume(scratch, &.{t});
                const value = try emitInlineText(scratch, token);
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

/// Parses a link label as inline content.
///
/// This does not enforce some rules about link labels since this should only be
/// used in concert with scanLinkLabel().
fn parseLinkLabel(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?[]*ast.Node {
    var nodes = NodeList.init(alloc, scratch, createTextNode);
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
        for (nodes.items()) |node| {
            node.deinit(alloc);
        }
        nodes.deinit();
    };

    _ = try self.consume(scratch, &.{.l_square_bracket}) orelse return null;

    for (0..util.safety.loop_bound) |_| {
        // square brackets not permitted within link label
        if (try self.peek(scratch)) |token| {
            switch (token.token_type) {
                .l_square_bracket => return null,
                .r_square_bracket => break,
                else => {},
            }
        }

        if (try self.parseInlineCode(alloc, scratch)) |code| {
            try nodes.append(code);
            continue;
        }

        if (try self.parseHardLineBreak(alloc, scratch)) |brk| {
            try nodes.append(brk);
            continue;
        }

        if (try self.parseAnyEmphasis(alloc, scratch, .{})) |emph| {
            try nodes.append(emph);
            continue;
        }

        if (try self.parseAnyStrong(alloc, scratch, .{})) |strong| {
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
    } else @panic(util.safety.loop_bound_panic_msg);

    _ = try self.consume(scratch, &.{.r_square_bracket}) orelse return null;

    did_parse = true;
    return try nodes.toOwnedSlice();
}

/// Parses an inline image link like `![my alt text](bar.com/url)`.
fn parseInlineImage(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    // @ => ! link_description l_paren (link_dest link_title?)? r_paren
    _ = try self.consume(scratch, &.{.exclamation_mark}) orelse return null;

    const img_desc_nodes = (
        try self.parseImageDescription(alloc, scratch) orelse return null
    );
    defer {
        // We only need these nodes to produce the alt text. They won't end
        // up in the final AST.
        for (img_desc_nodes) |node| {
            node.deinit(alloc);
        }
        alloc.free(img_desc_nodes);
    }

    _ = try self.consume(scratch, &.{.l_paren}) orelse return null;
    _ = try self.scanSeparatingWhitespace(scratch) orelse return null;

    // link destination
    const raw_url = try self.scanLinkDestination(scratch) orelse "";
    const url = try cmark.uri.normalize(scratch, scratch, raw_url);

    const whitespace = (
        try self.scanSeparatingWhitespace(scratch) orelse return null
    );
    const title = blk: {
        // link title, if present, must be separated from destination by
        // whitespace
        if (whitespace.len == 0) {
            break :blk "";
        }

        const t = try self.scanLinkTitle(scratch) orelse "";
        _ = try self.scanSeparatingWhitespace(scratch) orelse return null;
        break :blk t;
    };

    _ = try self.consume(scratch, &.{.r_paren}) orelse return null;

    // render "plain text" alt text
    var running_text = Io.Writer.Allocating.init(alloc);
    errdefer running_text.deinit();
    for (img_desc_nodes) |node| {
        try alttext.write(&running_text.writer, node);
    }

    const ownedUrl = try alloc.dupeZ(u8, url);
    errdefer alloc.free(ownedUrl);
    const ownedTitle = try alloc.dupeZ(u8, title);
    errdefer alloc.free(ownedTitle);
    const ownedAlt = try running_text.toOwnedSliceSentinel(0);
    errdefer alloc.free(ownedAlt);
    const image = try alloc.create(ast.Node);
    image.* = .{
        .tag = .image,
        .payload = .{
            .image = .{
                .url = ownedUrl,
                .title = ownedTitle,
                .alt = ownedAlt,
            },
        },
    };
    did_parse = true;
    return image;
}

/// Parses the image description component of an inline image. Returns a slice
/// of inline AST nodes.
fn parseImageDescription(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?[]*ast.Node {
    var did_parse = false;
    var nodes = NodeList.init(alloc, scratch, createTextNode);
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
        for (nodes.items()) |node| {
            node.deinit(alloc);
        }
        nodes.deinit();
    };

    _ = try self.consume(scratch, &.{.l_square_bracket}) orelse return null;

    var bracket_depth: u32 = 0;
    loop: for (0..util.safety.loop_bound) |_| {
        if (try self.parseInlineImage(alloc, scratch)) |image| {
            try nodes.append(image);
            continue;
        }

        if (try self.parseAnyLink(alloc, scratch)) |link| {
            try nodes.append(link);
            continue;
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
            const value = try emitInlineText(scratch, token);
            break :blk value;
        };
        if (allowed_bracket.len > 0) {
            try nodes.appendText(allowed_bracket);
            continue;
        }

        if (try self.parseHardLineBreak(alloc, scratch)) |brk| {
            try nodes.append(brk);
            continue;
        }

        if (try self.parseAnyEmphasis(
                alloc,
                scratch,
                .{.bracket_depth = &bracket_depth},
            )
        ) |emph| {
            try nodes.append(emph);
            continue;
        }

        if (try self.parseAnyStrong(
                alloc,
                scratch,
                .{.bracket_depth = &bracket_depth},
            )
        ) |strong| {
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
    } else @panic(util.safety.loop_bound_panic_msg);

    _ = try self.consume(scratch, &.{.r_square_bracket}) orelse return null;

    if (bracket_depth > 0) {
        return null; // contained unbalanced brackets
    }

    did_parse = true;
    return try nodes.toOwnedSlice();
}

/// Parses an image like `![my alt text][ref]`.
fn parseFullReferenceImage(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    _ = try self.consume(scratch, &.{.exclamation_mark}) orelse return null;

    const img_desc_nodes = (
        try self.parseImageDescription(alloc, scratch) orelse return null
    );
    defer {
        // We only need these nodes to produce the alt text. They won't end
        // up in the final AST.
        for (img_desc_nodes) |node| {
            node.deinit(alloc);
        }
        alloc.free(img_desc_nodes);
    }

    // handle link label
    const scanned_link_label = (
        try self.scanLinkLabel(scratch) orelse return null
    );

    // lookup link def
    const link_def = try self.link_defs.get(
        scratch,
        scanned_link_label,
    ) orelse return null; // no matching def means parse failure

    // render "plain text" alt text
    var running_text = Io.Writer.Allocating.init(alloc);
    errdefer running_text.deinit();
    for (img_desc_nodes) |node| {
        try alttext.write(&running_text.writer, node);
    }

    const url = try alloc.dupeZ(u8, std.mem.span(link_def.url));
    errdefer alloc.free(url);
    const title = try alloc.dupeZ(u8, std.mem.span(link_def.title));
    errdefer alloc.free(title);
    const alt = try running_text.toOwnedSliceSentinel(0);
    errdefer alloc.free(alt);

    const img_node = try alloc.create(ast.Node);
    img_node.* = .{
        .tag = .image,
        .payload = .{
            .image = .{
                .url = url,
                .title = title,
                .alt = alt,
            },
        },
    };
    did_parse = true;
    return img_node;
}

/// Parses an image like `![ref][]`.
fn parseCollapsedReferenceImage(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    _ = try self.consume(scratch, &.{.exclamation_mark}) orelse return null;

    const label_begin_index = self.checkpoint();

    // handle link label
    const scanned_link_label = (
        try self.scanLinkLabel(scratch) orelse return null
    );

    _ = try self.consume(scratch, &.{.l_square_bracket}) orelse return null;
    _ = try self.consume(scratch, &.{.r_square_bracket}) orelse return null;

    // lookup link def
    const link_def = try self.link_defs.get(
        scratch,
        scanned_link_label,
    ) orelse return null; // no matching def means parse failure

    // !! re-parse label as inline content !!
    self.backtrack(label_begin_index);
    const inline_nodes = (
        try self.parseLinkLabel(alloc, scratch) orelse return null
    );
    defer {
        // We only need these nodes to produce the alt text. They won't end
        // up in the final AST.
        for (inline_nodes) |node| {
            node.deinit(alloc);
        }
        alloc.free(inline_nodes);
    }

    // re-consume trailing "[]"
    _ = try self.consume(scratch, &.{.l_square_bracket}) orelse unreachable;
    _ = try self.consume(scratch, &.{.r_square_bracket}) orelse unreachable;

    // render "plain text" alt text
    var running_text = Io.Writer.Allocating.init(alloc);
    errdefer running_text.deinit();
    for (inline_nodes) |node| {
        try alttext.write(&running_text.writer, node);
    }

    const url = try alloc.dupeZ(u8, std.mem.span(link_def.url));
    errdefer alloc.free(url);
    const title = try alloc.dupeZ(u8, std.mem.span(link_def.title));
    errdefer alloc.free(title);
    const alt = try running_text.toOwnedSliceSentinel(0);
    errdefer alloc.free(alt);

    const img_node = try alloc.create(ast.Node);
    img_node.* = .{
        .tag = .image,
        .payload = .{
            .image = .{
                .url = url,
                .title = title,
                .alt = alt,
            },
        },
    };
    did_parse = true;
    return img_node;
}

/// Parses an image like `![ref]`.
fn parseShortcutReferenceImage(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    _ = try self.consume(scratch, &.{.exclamation_mark}) orelse return null;

    const label_begin_index = self.checkpoint();

    // handle link label
    const scanned_link_label = (
        try self.scanLinkLabel(scratch) orelse return null
    );

    // lookup link def
    const link_def = try self.link_defs.get(
        scratch,
        scanned_link_label,
    ) orelse return null; // no matching def means parse failure

    // !! re-parse label as inline content !!
    self.backtrack(label_begin_index);
    const inline_nodes = (
        try self.parseLinkLabel(alloc, scratch) orelse return null
    );
    defer {
        // We only need these nodes to produce the alt text. They won't end
        // up in the final AST.
        for (inline_nodes) |node| {
            node.deinit(alloc);
        }
        alloc.free(inline_nodes);
    }

    // render "plain text" alt text
    var running_text = Io.Writer.Allocating.init(alloc);
    errdefer running_text.deinit();
    for (inline_nodes) |node| {
        try alttext.write(&running_text.writer, node);
    }

    const url = try alloc.dupeZ(u8, std.mem.span(link_def.url));
    errdefer alloc.free(url);
    const title = try alloc.dupeZ(u8, std.mem.span(link_def.title));
    errdefer alloc.free(title);
    const alt = try running_text.toOwnedSliceSentinel(0);
    errdefer alloc.free(alt);

    const img_node = try alloc.create(ast.Node);
    img_node.* = .{
        .tag = .image,
        .payload = .{
            .image = .{
                .url = url,
                .title = title,
                .alt = alt,
            },
        },
    };
    did_parse = true;
    return img_node;
}

fn parseURIAutolink(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    _ = try self.consume(scratch, &.{.l_angle_bracket}) orelse return null;

    var running_text = Io.Writer.Allocating.init(scratch);

    while (try self.peek(scratch)) |token| {
        switch (token.token_type) {
            .r_angle_bracket => break,
            .escaped_r_angle_bracket => {
                _ = try running_text.writer.write("\\");
                break;
            },
            else => {
                const value = emitInlineLiteral(token);
                _ = try running_text.writer.write(value);
                _ = try self.consume(scratch, &.{token.token_type});
            },
        }
    }

    _ = try self.consume(
        scratch,
        &.{.r_angle_bracket, .escaped_r_angle_bracket},
        ) orelse return null;

    const content = try running_text.toOwnedSlice();
    if (!isValidAbsoluteURI(content)) {
        return null;
    }

    const url = try cmark.uri.normalize(scratch, scratch, content);
    const text = try createTextNode(alloc, content);
    errdefer text.deinit(alloc);

    const children = try alloc.dupe(*ast.Node, &.{text});
    errdefer alloc.free(children);
    const ownedUrl = try alloc.dupeZ(u8, url);
    errdefer alloc.free(ownedUrl);
    const ownedTitle = try alloc.dupeZ(u8, "");
    errdefer alloc.free(ownedTitle);

    const inline_link = try alloc.create(ast.Node);
    inline_link.* = .{
        .tag = .link,
        .payload = .{
            .link = .{
                .url = ownedUrl,
                .title = ownedTitle,
                .children = children.ptr,
                .n_children = @intCast(children.len),
            },
        },
    };
    did_parse = true;
    return inline_link;
}

/// Returns true if the given string is a valid absolute URI according to the
/// commonmark spec, false otherwise.
///
/// https://spec.commonmark.org/0.30/#absolute-uri
fn isValidAbsoluteURI(content: []const u8) bool {
    var lookahead_i: usize = 0;

    const State = enum { start, scheme, rest };
    fsm: switch (State.start) {
        .start => {
            if (lookahead_i >= content.len) {
                return false;
            }

            switch (content[lookahead_i]) {
                'a'...'z', 'A'...'Z' => {
                    lookahead_i += 1;
                    continue :fsm .scheme;
                },
                else => return false,
            }
        },
        .scheme => {
            if (lookahead_i >= content.len) {
                return false;
            }

            switch (content[lookahead_i]) {
                'a'...'z', 'A'...'Z', '0'...'9', '+', '.', '-' => {
                    lookahead_i += 1;
                    continue :fsm .scheme;
                },
                ':' => {
                    const scheme_len = lookahead_i;
                    if (scheme_len < 2 or scheme_len > 32) {
                        return false;
                    }

                    lookahead_i += 1;
                    continue :fsm .rest;
                },
                else => return false,
            }
        },
        .rest => {
            if (lookahead_i >= content.len) {
                break :fsm; // 0 characters after the scheme is allowed
            }

            switch (content[lookahead_i]) {
                '<', '>', ' ' => return false,
                else => |b| {
                    if (std.ascii.isControl(b)) {
                        return false;
                    }

                    lookahead_i += 1;
                    continue :fsm .rest;
                },
            }
        },
    }

    return true;
}

fn parseEmailAutolink(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    _ = try self.consume(scratch, &.{.l_angle_bracket}) orelse return null;

    var running_text = Io.Writer.Allocating.init(scratch);

    while (try self.peek(scratch)) |token| {
        switch (token.token_type) {
            .r_angle_bracket => break,
            .escaped_r_angle_bracket => {
                _ = try running_text.writer.write("\\");
                break;
            },
            else => {
                const value = emitInlineLiteral(token);
                _ = try running_text.writer.write(value);
                _ = try self.consume(scratch, &.{token.token_type});
            },
        }
    }

    _ = try self.consume(
        scratch,
        &.{.r_angle_bracket, .escaped_r_angle_bracket},
    ) orelse return null;

    const content = try running_text.toOwnedSlice();
    if (!isValidEmailAddress(content)) {
        return null;
    }

    const text = try createTextNode(alloc, content);
    errdefer text.deinit(alloc);

    const url = try fmt.allocPrintSentinel(
        alloc,
        "mailto:{s}",
        .{content},
        0,
    );
    errdefer alloc.free(url);

    const children = try alloc.dupe(*ast.Node, &.{text});
    errdefer alloc.free(children);
    const ownedTitle = try alloc.dupeZ(u8, "");
    errdefer alloc.free(ownedTitle);
    const inline_link = try alloc.create(ast.Node);
    inline_link.* = .{
        .tag = .link,
        .payload = .{
            .link = .{
                .url = url,
                .title = ownedTitle,
                .children = children.ptr,
                .n_children = @intCast(children.len),
            },
        },
    };
    did_parse = true;
    return inline_link;
}

/// Returns true if the given string is a valid email address according to the
/// commonmark spec; false otherwise.
///
/// [a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+
/// @
/// [a-zA-Z0-9]([a-zA-Z0-9-]{0, 61}[a-zA-Z0-9])?
/// (\.[a-zA-Z0-9]([a-zA-Z0-9-]{0, 61}[a-zA-Z0-9])*
fn isValidEmailAddress(content: []const u8) bool {
    var lookahead_i: usize = 0;

    var host_component_len: usize = 0; // max of 63 for each '.'-delimited part
    const State = enum {
        name_start,
        name,
        host_start,
        host,
        host_end,
    };
    fsm: switch (State.name_start) {
        .name_start => {
            if (lookahead_i >= content.len) {
                return false;
            }

            switch (content[lookahead_i]) {
                'a'...'z', 'A'...'Z', '0'...'9', '.', '!', '#', '$', '%', '&',
                '\'', '*', '+', '/', '=', '?', '^', '_', '`', '{', '|', '}',
                '~', '-' => {
                    lookahead_i += 1;
                    continue :fsm .name;
                },
                else => return false,
            }
        },
        .name => {
            if (lookahead_i >= content.len) {
                return false;
            }

            switch (content[lookahead_i]) {
                'a'...'z', 'A'...'Z', '0'...'9', '.', '!', '#', '$', '%', '&',
                '\'', '*', '+', '/', '=', '?', '^', '_', '`', '{', '|', '}',
                '~', '-' => {
                    lookahead_i += 1;
                    continue :fsm .name;
                },
                '@' => {
                    lookahead_i += 1;
                    continue :fsm .host_start;
                },
                else => return false,
            }
        },
        .host_start => {
            if (lookahead_i >= content.len) {
                return false;
            }

            switch (content[lookahead_i]) {
                'a'...'z', 'A'...'Z', '0'...'9' => {
                    lookahead_i += 1;
                    host_component_len += 1;
                    continue :fsm .host_end;
                },
                else => return false,
            }
        },
        .host => {
            if (lookahead_i >= content.len) {
                return false;
            }

            if (host_component_len >= 63) {
                return false;
            }

            switch (content[lookahead_i]) {
                'a'...'z', 'A'...'Z', '0'...'9' => {
                    lookahead_i += 1;
                    host_component_len += 1;
                    continue :fsm .host_end;
                },
                '-' => {
                    lookahead_i += 1;
                    host_component_len += 1;
                    continue :fsm .host;
                },
                else => return false,
            }
        },
        .host_end => {
            if (lookahead_i >= content.len) {
                break :fsm;
            }

            switch (content[lookahead_i]) {
                '.' => {
                    lookahead_i += 1;
                    host_component_len = 0;
                    continue :fsm .host_start;
                },
                'a'...'z', 'A'...'Z', '0'...'9', '-' => continue :fsm .host,
                else => return false,
            }
        },
    }

    return true;
}

fn parseAnyLink(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    if (try self.parseURIAutolink(alloc, scratch)) |link| {
        return link;
    }

    if (try self.parseEmailAutolink(alloc, scratch)) |link| {
        return link;
    }

    if (try self.parseInlineLink(alloc, scratch)) |link| {
        return link;
    }

    if (try self.parseFullReferenceLink(alloc, scratch)) |link| {
        return link;
    }

    if (try self.parseCollapsedReferenceLink(alloc, scratch)) |link| {
        return link;
    }

    if (try self.parseShortcutReferenceLink(alloc, scratch)) |link| {
        return link;
    }

    return null;
}

/// https://spec.commonmark.org/0.30/#hard-line-breaks
fn parseHardLineBreak(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    const token = try self.peek(scratch) orelse return null;
    if (token.token_type != .hard_break) {
        return null;
    }

    if (try self.peekAhead(scratch, 2) == null) {
        // end of block, can't put hard line break here
        return null;
    }

    _ = try self.consume(scratch, &.{token.token_type});

    const break_node = try alloc.create(ast.Node);
    break_node.* = .{
        .tag = .@"break",
        .payload = .{
            .@"break" = {},
        },
    };
    return break_node;
}

/// Parses inline raw HTML.
///
/// https://spec.commonmark.org/0.30/#raw-html
///
/// An HTML tag could be an open tag, a closing tag, an HTML comment, a
/// processing instruction, a declaration, or a CDATA section.
fn parseHTMLTag(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    if (try self.parseHTMLOpenTag(alloc, scratch)) |node| {
        return node;
    }

    if (try self.parseHTMLCloseTag(alloc, scratch)) |node| {
        return node;
    }

    if (try self.parseHTMLComment(alloc, scratch)) |node| {
        return node;
    }

    if (try self.parseHTMLProcessingInstruction(alloc, scratch)) |node| {
        return node;
    }

    if (try self.parseHTMLDeclaration(alloc, scratch)) |node| {
        return node;
    }

    if (try self.parseHTMLCDATA(alloc, scratch)) |node| {
        return node;
    }

    return null;
}

/// Parses an HTML open tag.
///
/// Must have a tag name.
///
/// Can have: zero or more attributes; optional spaces, tabs and up to one
/// line ending; an optional "/".
fn parseHTMLOpenTag(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var did_parse = false;
    var running_text = Io.Writer.Allocating.init(alloc);
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
        running_text.deinit();
    };

    var newline_count: u8 = 0;

    _ = try self.consume(scratch, &.{.l_angle_bracket}) orelse return null;
    _ = try running_text.writer.write("<");

    const tag = try self.scanHTMLTagName(scratch) orelse return null;
    _ = try running_text.writer.write(tag);

    for (0..util.safety.loop_bound) |_| {
        if (try self.consume(scratch, &.{.whitespace})) |ws| {
            _ = try running_text.writer.write(emitInlineLiteral(ws));
        } else if (try self.consume(scratch, &.{.newline})) |nl| {
            _ = try running_text.writer.write(emitInlineLiteral(nl));
            newline_count += 1;
        } else {
            // whitespace is required before attributes
            break;
        }

        if (try self.scanHTMLAttribute(scratch)) |attr| {
            _ = try running_text.writer.write(attr);
        } else {
            // no more attributes, we are done
            break;
        }
    } else @panic(util.safety.loop_bound_panic_msg);

    // Allow "/" before closing bracket
    if (try self.consume(scratch, &.{.slash})) |_| {
        _ = try running_text.writer.write("/");
    }

    _ = try self.consume(scratch, &.{.r_angle_bracket}) orelse return null;
    _ = try running_text.writer.write(">");

    if (newline_count > 1) {
        // At most one line ending allowed
        return null;
    }

    const content = try running_text.toOwnedSliceSentinel(0);
    errdefer alloc.free(content);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .tag = .html,
        .payload = .{
            .html = .{
                .value = content,
            },
        },
    };
    did_parse = true;
    return node;
}

/// Parses an HTML closing tag.
///
/// Closing tags start with "</", must have a tag name, and cannot have
/// attributes.
fn parseHTMLCloseTag(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    _ = try self.consume(scratch, &.{.l_angle_bracket}) orelse return null;
    _ = try self.consume(scratch, &.{.slash}) orelse return null;

    const tag = try self.scanHTMLTagName(scratch) orelse return null;

    const ws = blk: {
        const maybe_token = try self.consume(scratch, &.{.whitespace});
        if (maybe_token) |token| {
            break :blk emitInlineLiteral(token);
        }
        break :blk "";
    };

    _ = try self.consume(scratch, &.{.r_angle_bracket}) orelse return null;

    const content = try fmt.allocPrintSentinel(
        alloc,
        "</{s}{s}>",
        .{ tag, ws },
        0,
    );
    errdefer alloc.free(content);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .tag = .html,
        .payload = .{
            .html = .{
                .value = content,
            },
        },
    };
    did_parse = true;
    return node;
}

/// Parses an HTML comment.
///
/// Comments consist of <!-- (text) -->, where (text) does not start with > or
/// ->, does not end with -, and does not contain --.
fn parseHTMLComment(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    _ = try self.consume(scratch, &.{.l_angle_bracket}) orelse return null;
    _ = try self.consume(scratch, &.{.exclamation_mark}) orelse return null;
    _ = try self.consume(scratch, &.{.hyphen}) orelse return null;
    _ = try self.consume(scratch, &.{.hyphen}) orelse return null;

    var running_text = Io.Writer.Allocating.init(scratch);

    while (try self.peek(scratch)) |token| {
        switch (token.token_type) {
            .hyphen => {
                _ = try self.consume(scratch, &.{.hyphen});
                _ = try self.consume(scratch, &.{.hyphen}) orelse {
                    _ = try running_text.writer.write("-");
                    continue;
                };
                _ = try self.consume(scratch, &.{.r_angle_bracket}) orelse {
                    // comment contained "--"
                    return null;
                };

                // reached "-->"
                break;
            },
            else => |token_type| {
                const value = emitInlineLiteral(token);
                _ = try running_text.writer.write(value);
                _ = try self.consume(scratch, &.{token_type});
            },
        }
    }

    const content = try running_text.toOwnedSlice();

    if (
        std.mem.startsWith(u8, content, ">")
        or std.mem.startsWith(u8, content, "->")
    ) {
        return null;
    }

    if (std.mem.endsWith(u8, content, "-")) {
        return null;
    }

    const comment = try fmt.allocPrintSentinel(
        alloc,
        "<!--{s}-->",
        .{content},
        0,
    );
    errdefer alloc.free(comment);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .tag = .html,
        .payload = .{
            .html = .{
                .value = comment,
            },
        },
    };
    did_parse = true;
    return node;
}

/// https://spec.commonmark.org/0.30/#processing-instruction
fn parseHTMLProcessingInstruction(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    _ = try self.consume(scratch, &.{.l_angle_bracket}) orelse return null;
    _ = try self.consume(scratch, &.{.question_mark}) orelse return null;

    var running_text = Io.Writer.Allocating.init(scratch);

    while (try self.peek(scratch)) |token| {
        switch (token.token_type) {
            .question_mark => {
                _ = try self.consume(scratch, &.{.question_mark});
                _ = try self.consume(scratch, &.{.r_angle_bracket}) orelse {
                    _ = try running_text.writer.write("?");
                    continue;
                };

                // reached "?>"
                break;
            },
            else => |token_type| {
                const value = emitInlineLiteral(token);
                _ = try running_text.writer.write(value);
                _ = try self.consume(scratch, &.{token_type});
            },
        }
    }

    const content = try running_text.toOwnedSlice();
    const instruction = try fmt.allocPrintSentinel(
        alloc,
        "<?{s}?>",
        .{content},
        0,
    );
    errdefer alloc.free(instruction);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .tag = .html,
        .payload = .{
            .html = .{
                .value = instruction,
            },
        },
    };
    did_parse = true;
    return node;
}

/// https://spec.commonmark.org/0.30/#declaration
fn parseHTMLDeclaration(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    _ = try self.consume(scratch, &.{.l_angle_bracket}) orelse return null;
    _ = try self.consume(scratch, &.{.exclamation_mark}) orelse return null;

    var running_text = Io.Writer.Allocating.init(scratch);

    while (try self.peek(scratch)) |token| {
        switch (token.token_type) {
            .r_angle_bracket => {
                break;
            },
            else => |token_type| {
                const value = emitInlineLiteral(token);
                _ = try running_text.writer.write(value);
                _ = try self.consume(scratch, &.{token_type});
            },
        }
    }

    _ = try self.consume(scratch, &.{.r_angle_bracket}) orelse return null;

    const content = try running_text.toOwnedSlice();
    if (content.len == 0 or !std.ascii.isAlphabetic(content[0])) {
        // must start with ASCII letter
        return null;
    }

    const declaration = try fmt.allocPrintSentinel(
        alloc,
        "<!{s}>",
        .{content},
        0,
    );
    errdefer alloc.free(declaration);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .tag = .html,
        .payload = .{
            .html = .{
                .value = declaration,
            },
        },
    };
    did_parse = true;
    return node;
}

fn parseHTMLCDATA(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
) Error!?*ast.Node {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    _ = try self.consume(scratch, &.{.l_angle_bracket}) orelse return null;
    _ = try self.consume(scratch, &.{.exclamation_mark}) orelse return null;
    _ = try self.consume(scratch, &.{.l_square_bracket}) orelse return null;
    const text = try self.consume(scratch, &.{.text}) orelse return null;
    if (!std.mem.eql(u8, text.lexeme, "CDATA")) {
        return null;
    }
    _ = try self.consume(scratch, &.{.l_square_bracket}) orelse return null;

    var running_text = Io.Writer.Allocating.init(scratch);

    while (try self.peek(scratch)) |token| {
        switch (token.token_type) {
            .r_square_bracket => {
                _ = try self.consume(scratch, &.{.r_square_bracket});
                _ = try self.consume(scratch, &.{.r_square_bracket}) orelse {
                    _ = try running_text.writer.write("]");
                    continue;
                };
                _ = try self.consume(scratch, &.{.r_angle_bracket}) orelse {
                    _ = try running_text.writer.write("]]");
                    continue;
                };

                // reached "]]>"
                break;
            },
            else => |token_type| {
                const value = emitInlineLiteral(token);
                _ = try running_text.writer.write(value);
                _ = try self.consume(scratch, &.{token_type});
            },
        }
    }

    const content = try running_text.toOwnedSlice();
    const cdata = try fmt.allocPrintSentinel(
        alloc,
        "<![CDATA[{s}]]>",
        .{content},
        0,
    );
    errdefer alloc.free(cdata);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .tag = .html,
        .payload = .{
            .html = .{
                .value = cdata,
            },
        },
    };
    did_parse = true;
    return node;
}


/// A tag name consists of an ASCII letter followed by zero or more ASCII
/// letters, digits, or hyphens.
fn scanHTMLTagName(self: *Self, scratch: Allocator) !?[]const u8 {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    var running_text = Io.Writer.Allocating.init(scratch);

    while (try self.consume(scratch, &.{.text, .hyphen})) |token| {
        const value = emitInlineLiteral(token);
        _ = try running_text.writer.write(value);
    }

    const tag_name = try running_text.toOwnedSlice();

    if (tag_name.len == 0) {
        return null;
    }

    if (!std.ascii.isAlphabetic(tag_name[0])) {
        return null;
    }

    for (1..tag_name.len) |i| {
        if (!std.ascii.isAlphanumeric(tag_name[i]) and tag_name[i] != '-') {
            return null;
        }
    }

    did_parse = true;
    return tag_name;
}

/// https://spec.commonmark.org/0.30/#attribute
fn scanHTMLAttribute(self: *Self, scratch: Allocator) !?[]const u8 {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    var running_text = Io.Writer.Allocating.init(scratch);
    var newline_count: u8 = 0;

    const attr_name = try self.scanHTMLAttrName(scratch) orelse return null;
    _ = try running_text.writer.write(attr_name);

    const equals = blk: {
        // We want to allow whitespace and a newline before the "=", but don't
        // want to consume it unless it is indeed followed by a "=".
        const lookahead_checkpoint = self.checkpoint();

        if (try self.consume(scratch, &.{.whitespace})) |ws| {
            _ = try running_text.writer.write(emitInlineLiteral(ws));
        }
        if (try self.consume(scratch, &.{.newline})) |nl| {
            _ = try running_text.writer.write(emitInlineLiteral(nl));
            newline_count += 1;
        }

        if (try self.consume(scratch, &.{.equals})) |token| {
            break :blk token;
        } else {
            self.backtrack(lookahead_checkpoint);
            break :blk null;
        }
    };

    if (equals == null) {
        // attribute without value
        did_parse = true;
        return attr_name;
    }

    _ = try running_text.writer.write("=");

    if (try self.consume(scratch, &.{.whitespace})) |ws| {
        _ = try running_text.writer.write(emitInlineLiteral(ws));
    }
    if (try self.consume(scratch, &.{.newline})) |nl| {
        _ = try running_text.writer.write(emitInlineLiteral(nl));
        newline_count += 1;
    }

    const attr_val = blk: {
        if (try self.scanHTMLAttrValQuoted(scratch)) |val| {
            break :blk val;
        }

        if (try self.scanHTMLAttrValUnquoted(scratch)) |val| {
            break :blk val;
        }

        break :blk null;
    } orelse return null;

    _ = try running_text.writer.write(attr_val);

    if (newline_count > 1) {
        // At most one newline
        return null;
    }

    did_parse = true;
    return try running_text.toOwnedSlice();
}

/// Parse HTML attribute name.
///
/// ASCII letter, _, or :, followed by zero or more ASCII letters, digits,
/// _, ., :, or -.
fn scanHTMLAttrName(self: *Self, scratch: Allocator) !?[]const u8 {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    var running_text = Io.Writer.Allocating.init(scratch);

    while (try self.consume(scratch, &.{
        .text,
        .hyphen,
        .l_delim_underscore,
        .r_delim_underscore,
        .lr_delim_underscore,
    })) |token| {
        const value = emitInlineLiteral(token);
        _ = try running_text.writer.write(value);
    }

    const attr_name = try running_text.toOwnedSlice();

    if (attr_name.len == 0) {
        return null;
    }

    if (
        !std.ascii.isAlphabetic(attr_name[0])
        and !util.strings.containsScalar("_:", attr_name[0])
    ) {
        return null;
    }

    for (1..attr_name.len) |i| {
        if (
            !std.ascii.isAlphanumeric(attr_name[i])
            and !util.strings.containsScalar("_:.-", attr_name[i])
        ) {
            return null;
        }
    }

    did_parse = true;
    return attr_name;
}

fn scanHTMLAttrValQuoted(self: *Self, scratch: Allocator) !?[]const u8 {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    var running_text = Io.Writer.Allocating.init(scratch);

    const open_quote = try self.consume(
        scratch,
        &.{.single_quote, .double_quote},
    ) orelse return null;
    _ = try running_text.writer.write(emitInlineLiteral(open_quote));

    while (try self.peek(scratch)) |token| {
        switch (token.token_type) {
            .newline => break,
            .single_quote, .double_quote => |token_type| {
                _ = try self.consume(scratch, &.{token_type});

                const value = emitInlineLiteral(token);
                _ = try running_text.writer.write(value);

                if (token.token_type == open_quote.token_type) {
                    break;
                }
            },
            .escaped_single_quote => {
                _ = try self.consume(scratch, &.{.escaped_single_quote});

                const value = emitInlineLiteral(token);
                _ = try running_text.writer.write(value);

                if (open_quote.token_type == .single_quote) {
                    break;
                }
            },
            .escaped_double_quote => {
                _ = try self.consume(scratch, &.{.escaped_double_quote});

                const value = emitInlineLiteral(token);
                _ = try running_text.writer.write(value);

                if (open_quote.token_type == .double_quote) {
                    break;
                }
            },
            else => |token_type| {
                _ = try self.consume(scratch, &.{token_type});
                const value = emitInlineLiteral(token);
                _ = try running_text.writer.write(value);
            },
        }
    }

    did_parse = true;
    return try running_text.toOwnedSlice();
}

fn scanHTMLAttrValUnquoted(self: *Self, scratch: Allocator) !?[]const u8 {
    var did_parse = false;
    const checkpoint_index = self.checkpoint();
    defer if (!did_parse) {
        self.backtrack(checkpoint_index);
    };

    var running_text = Io.Writer.Allocating.init(scratch);

    while (try self.consume(scratch, &.{
        .text,
        .hyphen,
        .question_mark,
        .l_square_bracket,
        .r_square_bracket,
        .l_paren,
        .r_paren,
        .exclamation_mark,
        .l_delim_underscore,
        .r_delim_underscore,
        .lr_delim_underscore,
    })) |token| {
        const value = emitInlineLiteral(token);
        _ = try running_text.writer.write(value);
    }

    if (running_text.written().len == 0) {
        return null; // val cannot be empty
    }

    did_parse = true;
    return try running_text.toOwnedSlice();
}

/// Consumes tokens we know won't be parsed as anything else and emits them as
/// regular text.
///
/// Consumes only:
/// - text tokens
/// - character reference tokens
/// - whitespace / newlines
/// - underscores that cannot start or stop emphasis
fn scanText(self: *Self, scratch: Allocator) ![]const u8 {
    var running_text = Io.Writer.Allocating.init(scratch);

    const State = enum { normal, soft_break };
    fsm: switch (State.normal) {
        .normal => {
            const token = try self.peek(scratch) orelse break :fsm;
            switch (token.token_type) {
                .decimal_character_reference,
                .hexadecimal_character_reference, .entity_reference,
                .text => |t| {
                    _ = try self.consume(scratch, &.{t});

                    const value = try emitInlineText(scratch, token);
                    _ = try running_text.writer.write(value);
                },
                .whitespace, .newline => {
                    continue :fsm .soft_break;
                },
                .lr_delim_underscore => {
                    // Only allowed if cannot start or stop emphasis
                    if (
                        token.context.delim_underscore.preceded_by_punct
                        or token.context.delim_underscore.followed_by_punct
                    ) {
                        break :fsm;
                    }
                    _ = try self.consume(scratch, &.{.lr_delim_underscore});

                    const value = try emitInlineText(scratch, token);
                    _ = try running_text.writer.write(value);
                },
                else => break :fsm,
            }

            continue :fsm .normal;
        },
        .soft_break => {
            const maybe_whitespace = try self.consume(scratch, &.{.whitespace});

            if (try self.consume(scratch, &.{.newline})) |newline| {
                _ = try self.consume(scratch, &.{.whitespace});
                const value = try emitInlineText(scratch, newline);
                _ = try running_text.writer.write(value);
            } else if (maybe_whitespace) |whitespace| {
                const value = try emitInlineText(scratch, whitespace);
                _ = try running_text.writer.write(value);
            }

            continue :fsm .normal;
        },
    }

    return try running_text.toOwnedSlice();
}

/// Consumes exactly one token of ANY type and emits it as regular text.
fn scanTextFallback(self: *Self, scratch: Allocator) ![]const u8 {
    const token = try self.peek(scratch) orelse return "";
    _ = try self.consume(scratch, &.{token.token_type});

    const text_value = try emitInlineText(scratch, token);
    return text_value;
}

/// Emit tokens as "regular" inline text.
///
/// Strips backslash escapes. Resolves character references.
fn emitInlineText(scratch: Allocator, token: InlineToken) ![]const u8 {
    const value = switch (token.token_type) {
        .decimal_character_reference,
        .hexadecimal_character_reference,
        .entity_reference
            => try resolveCharacterReference(scratch, token),
        .text => try escape.strip(scratch, token.lexeme),
        .escaped_single_quote => "'",
        .escaped_double_quote => "\"",
        .escaped_r_angle_bracket => ">",
        .escaped_backtick => "`",
        else => emitInlineLiteral(token),
    };

    return value;
}

/// Emit tokens as inline code.
///
/// Newlines and hard linebreaks get converted to whitespace.
fn emitInlineCode(scratch: Allocator, token: InlineToken) ![]const u8 {
    const value = switch (token.token_type) {
        .newline => " ",
        // Hard line breaks not allowed in inline code. Just emit the chars as
        // text, keeping to the rule that newlines are replaced with spaces.
        .hard_break => try std.mem.replaceOwned(
            u8,
            scratch,
            token.lexeme,
            "\n",
            " ",
        ),
        else => emitInlineLiteral(token),
    };

    return value;
}

/// Emit tokens with no modification.
fn emitInlineLiteral(token: InlineToken) []const u8 {
    const value = switch (token.token_type) {
        .decimal_character_reference,
        .hexadecimal_character_reference,
        .entity_reference,
        .backtick,
        .whitespace,
        .text,
        // If we are emitting the hard break, it was matched in a place where
        // hard linebreaks aren't allowed. So just emit the chars as text
        .hard_break
            => token.lexeme,
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
        .exclamation_mark => "!",
        .equals => "=",
        .slash => "/",
        .hyphen => "-",
        .question_mark => "?",
        .newline => "\n",
        .escaped_single_quote => "\\'",
        .escaped_double_quote => "\\\"",
        .escaped_r_angle_bracket => "\\>",
        .escaped_backtick => "\\`",
    };

    return value;
}

fn resolveCharacterReference(
    scratch: Allocator,
    token: InlineToken,
) ![]const u8 {
    switch (token.token_type) {
        .decimal_character_reference => {
            const value = try cmark.character_refs.resolveNumericCharacter(
                scratch,
                token.lexeme[2..token.lexeme.len - 1],
                10, // base
            );
            return value;
        },
        .hexadecimal_character_reference => {
            const value = try cmark.character_refs.resolveNumericCharacter(
                scratch,
                token.lexeme[3..token.lexeme.len - 1],
                16, // base
            );
            return value;
        },
        .entity_reference => {
            const lexeme = token.lexeme;
            const value = cmark.character_refs.resolveCharacterEntity(
                lexeme[1..lexeme.len - 1],
            );
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
    const copy = try alloc.dupeZ(u8, value);
    errdefer alloc.free(copy);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .tag = .text,
        .payload = .{
            .text = .{
                .value = copy,
            },
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

fn parseIntoNodes(value: []const u8, link_defs: LinkDefMap) ![]*ast.Node {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var tokenizer = InlineTokenizer.init(value);
    var parser = Self.init(&tokenizer, link_defs);
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
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(2, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);
    try testing.expectEqual(
        ast.NodeType.emphasis,
        nodes[1].tag,
    );
    try testing.expectEqualStrings(
        "is emphasized.",
        std.mem.span(nodes[1].payload.emphasis.children[0].payload.text.value),
    );
}

test "intraword star emphasis" {
    const value = "em*pha*sis";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);
    try testing.expectEqual(
        ast.NodeType.emphasis,
        nodes[1].tag,
    );
    try testing.expectEqualStrings(
        "pha",
        std.mem.span(nodes[1].payload.emphasis.children[0].payload.text.value),
    );
    try testing.expectEqual(ast.NodeType.text, nodes[2].tag);
}

test "nested star emphasis" {
    const value = "This **is* emphasized.*";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(2, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);

    try testing.expectEqual(
        ast.NodeType.emphasis,
        nodes[1].tag,
    );
    try testing.expectEqual(2, nodes[1].payload.emphasis.n_children);

    const nested_emph = nodes[1].payload.emphasis.children[0];
    try testing.expectEqual(
        ast.NodeType.emphasis,
        nested_emph.tag,
    );
    try testing.expectEqualStrings(
        "is",
        std.mem.span(nested_emph.payload.emphasis.children[0].payload.text.value),
    );
    try testing.expectEqualStrings(
        " emphasized.",
        std.mem.span(nodes[1].payload.emphasis.children[1].payload.text.value),
    );
}

test "unmatched open star emphasis" {
    const value = "This *is unmatched.";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);
    try testing.expectEqualStrings(value, std.mem.span(nodes[0].payload.text.value));
}

test "unmatched close star emphasis" {
    const value = "This is unmatched.*";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);
    try testing.expectEqualStrings(value, std.mem.span(nodes[0].payload.text.value));
}

test "same delimiter run star emphasis" {
    const value = "This is not ** emphasis.";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);
    try testing.expectEqualStrings(value, std.mem.span(nodes[0].payload.text.value));
}

test "same delimiter run star strong" {
    const value = "This is not **** strong.";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);
    try testing.expectEqualStrings(value, std.mem.span(nodes[0].payload.text.value));
}

test "star strong" {
    const value = "This is **strongly emphasized**.";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);

    try testing.expectEqual(ast.NodeType.strong, nodes[1].tag);
    try testing.expectEqualStrings(
        "strongly emphasized",
        std.mem.span(nodes[1].payload.strong.children[0].payload.text.value),
    );

    try testing.expectEqual(ast.NodeType.text, nodes[2].tag);
}

test "triple star strong nested" {
    const value = "This is ***a strong in an emphasis***.";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);
    try testing.expectEqualStrings(
        "This is ",
        std.mem.span(nodes[0].payload.text.value),
    );

    try testing.expectEqual(
        ast.NodeType.emphasis,
        nodes[1].tag,
    );
    try testing.expectEqual(
        ast.NodeType.strong,
        nodes[1].payload.emphasis.children[0].tag,
    );
    try testing.expectEqualStrings(
        "a strong in an emphasis",
        std.mem.span(
            nodes[1].payload.emphasis.children[0].payload.strong.children[0].payload.text.value
        ),
    );

    try testing.expectEqual(ast.NodeType.text, nodes[2].tag);
    try testing.expectEqualStrings(".", std.mem.span(nodes[2].payload.text.value));
}

test "unmatched nested emphasis" {
    const value = "**strong * with asterisk**";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.strong, nodes[0].tag);
    try testing.expectEqual(1, nodes[0].payload.strong.n_children);

    try testing.expectEqual(
        ast.NodeType.text,
        nodes[0].payload.strong.children[0].tag,
    );
    try testing.expectEqualStrings(
        "strong * with asterisk",
        std.mem.span(nodes[0].payload.strong.children[0].payload.text.value),
    );
}

test "unmatched nested emphasis no spacing" {
    const value = "**foo*bar**";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.strong, nodes[0].tag);
    try testing.expectEqual(1, nodes[0].payload.strong.n_children);

    try testing.expectEqual(
        ast.NodeType.text,
        nodes[0].payload.strong.children[0].tag,
    );
    try testing.expectEqualStrings(
        "foo*bar",
        std.mem.span(nodes[0].payload.strong.children[0].payload.text.value),
    );
}

test "bad star strong given spacing" {
    // the space following "hello" means the last two asterisks shouldn't get
    // tokenized as a delimiter run
    const value = "**hello **";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);
}

test "star strong nested inside star emphasis" {
    const value = "This ***is strong** that is also emphasized*.";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);

    const emphasis_node = nodes[1];
    try testing.expectEqual(
        ast.NodeType.emphasis,
        emphasis_node.tag,
    );
    try testing.expectEqual(2, emphasis_node.payload.emphasis.n_children);
    try testing.expectEqual(
        ast.NodeType.strong,
        emphasis_node.payload.emphasis.children[0].tag,
    );
    try testing.expectEqualStrings(
        "is strong",
        std.mem.span(
            emphasis_node.payload.emphasis.children[0].payload.strong.children[0].payload.text.value,
        ),
    );
    try testing.expectEqual(
        ast.NodeType.text,
        emphasis_node.payload.emphasis.children[1].tag,
    );
    try testing.expectEqualStrings(
        " that is also emphasized",
        std.mem.span(emphasis_node.payload.emphasis.children[1].payload.text.value),
    );

    try testing.expectEqual(ast.NodeType.text, nodes[2].tag);
}

test "star emphasis nested inside star strong" {
    const value = "This ***is emphasis* that is also strong**.";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);

    const strong_node = nodes[1];
    try testing.expectEqual(
        ast.NodeType.strong,
        strong_node.tag,
    );
    try testing.expectEqual(2, strong_node.payload.strong.n_children);
    try testing.expectEqual(
        ast.NodeType.emphasis,
        strong_node.payload.strong.children[0].tag,
    );
    try testing.expectEqualStrings(
        "is emphasis",
        std.mem.span(
            strong_node.payload.strong.children[0].payload.emphasis.children[0].payload.text.value,
        ),
    );
    try testing.expectEqual(
        ast.NodeType.text,
        strong_node.payload.strong.children[1].tag,
    );
    try testing.expectEqualStrings(
        " that is also strong",
        std.mem.span(strong_node.payload.strong.children[1].payload.text.value),
    );

    try testing.expectEqual(ast.NodeType.text, nodes[2].tag);
}

test "star strong interior sum of lengths rule" {
    // See the "underscore emphasis interior sum of lengths rule" for a fuller
    // explanation of this test.
    //
    // This test is similar to commonmark example 411 but uses strong nodes
    // instead of emphasis nodes.
    const value = "**(foo)****(bar)**";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.strong, nodes[0].tag);
    try testing.expectEqual(1, nodes[0].payload.strong.n_children);

    try testing.expectEqual(
        ast.NodeType.text,
        nodes[0].payload.strong.children[0].tag,
    );
    try testing.expectEqualStrings(
        "(foo)****(bar)",
        std.mem.span(nodes[0].payload.strong.children[0].payload.text.value),
    );
}

test "underscore emphasis" {
    const value = "This _is emphasized._";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(2, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);
    try testing.expectEqual(
        ast.NodeType.emphasis,
        nodes[1].tag,
    );
    try testing.expectEqualStrings(
        "is emphasized.",
        std.mem.span(nodes[1].payload.emphasis.children[0].payload.text.value),
    );
}

test "underscore right-delimiter emphasis" {
    const value = "This is _hyper_-cool!";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);
    try testing.expectEqual(
        ast.NodeType.emphasis,
        nodes[1].tag,
    );
    try testing.expectEqualStrings(
        "hyper",
        std.mem.span(nodes[1].payload.emphasis.children[0].payload.text.value),
    );
    try testing.expectEqual(ast.NodeType.text, nodes[2].tag);
}

// Unlike with star emphasis, this isn't valid
test "intraword underscore emphasis" {
    const value = "snake_case_baby";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);
    try testing.expectEqualStrings(
        "snake_case_baby",
        std.mem.span(nodes[0].payload.text.value),
    );
}

test "underscore emphasis after punctuation" {
    const value = "(_\"emphasis\"_)";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);

    try testing.expectEqual(
        ast.NodeType.emphasis,
        nodes[1].tag,
    );
    try testing.expectEqualStrings(
        "\"emphasis\"",
        std.mem.span(nodes[1].payload.emphasis.children[0].payload.text.value),
    );

    try testing.expectEqual(ast.NodeType.text, nodes[2].tag);
}

test "underscore emphasis nested unmatched" {
    const value = "_foo *bar_";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(
        ast.NodeType.emphasis,
        nodes[0].tag,
    );
    try testing.expectEqual(1, nodes[0].payload.emphasis.n_children);

    try testing.expectEqual(
        ast.NodeType.text,
        nodes[0].payload.emphasis.children[0].tag,
    );
    try testing.expectEqualStrings(
        "foo *bar",
        std.mem.span(nodes[0].payload.emphasis.children[0].payload.text.value),
    );
}

test "underscore emphasis interior sum of lengths rule" {
    // Just "_(foo)_(bar)_" with a single underscore in the middle would parse
    // as one emphasis containing "(foo)" and then "(bar)_" as text.
    //
    // Adding a second underscore in the middle means that the sum of lengths
    // rule becomes relevant. The emphasis opened by the underscore before
    // "(foo)" can't close with the underscores immediately following "(foo)",
    // because the lengths sum to three. So the interior underscores should get
    // parsed as simple text content and the emphasis should be closed with the
    // last underscore after "(bar)".
    //
    // See Commonmark example 411 for a similar test for star-delimited
    // emphasis.
    const value = "_(foo)__(bar)_";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.emphasis, nodes[0].tag);
    try testing.expectEqual(1, nodes[0].payload.emphasis.n_children);

    try testing.expectEqual(
        ast.NodeType.text,
        nodes[0].payload.emphasis.children[0].tag,
    );
    try testing.expectEqualStrings(
        "(foo)__(bar)",
        std.mem.span(nodes[0].payload.emphasis.children[0].payload.text.value),
    );
}

test "underscore strong" {
    const value = "This is __strongly emphasized__.";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);

    try testing.expectEqual(ast.NodeType.strong, nodes[1].tag);
    try testing.expectEqualStrings(
        "strongly emphasized",
        std.mem.span(nodes[1].payload.strong.children[0].payload.text.value),
    );

    try testing.expectEqual(ast.NodeType.text, nodes[2].tag);
}

test "underscore strong with nested unmatched" {
    const value = "__foo*bar__";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.strong, nodes[0].tag);
    try testing.expectEqual(1, nodes[0].payload.strong.n_children);

    try testing.expectEqual(
        ast.NodeType.text,
        nodes[0].payload.strong.children[0].tag,
    );
    try testing.expectEqualStrings(
        "foo*bar",
        std.mem.span(nodes[0].payload.strong.children[0].payload.text.value),
    );
}

test "underscore strong interior sum of lengths rule" {
    // See the "underscore emphasis interior sum of lengths rule" for a fuller
    // explanation of this test.
    const value = "__(foo)____(bar)__";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.strong, nodes[0].tag);
    try testing.expectEqual(1, nodes[0].payload.strong.n_children);

    try testing.expectEqual(
        ast.NodeType.text,
        nodes[0].payload.strong.children[0].tag,
    );
    try testing.expectEqualStrings(
        "(foo)____(bar)",
        std.mem.span(nodes[0].payload.strong.children[0].payload.text.value),
    );
}

test "triple underscore strong nested" {
    const value = "This is ___a strong in an emphasis___.";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);
    try testing.expectEqualStrings(
        "This is ",
        std.mem.span(nodes[0].payload.text.value),
    );

    try testing.expectEqual(
        ast.NodeType.emphasis,
        nodes[1].tag,
    );
    try testing.expectEqual(
        ast.NodeType.strong,
        nodes[1].payload.emphasis.children[0].tag,
    );
    try testing.expectEqualStrings(
        "a strong in an emphasis",
        std.mem.span(
            nodes[1].payload.emphasis.children[0].payload.strong.children[0].payload.text.value,
        ),
    );

    try testing.expectEqual(ast.NodeType.text, nodes[2].tag);
    try testing.expectEqualStrings(".", std.mem.span(nodes[2].payload.text.value));
}

test "unmatched nested underscore" {
    const value = "*foo _bar*";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(
        ast.NodeType.emphasis,
        nodes[0].tag,
    );
    try testing.expectEqual(1, nodes[0].payload.emphasis.n_children);

    try testing.expectEqual(
        ast.NodeType.text,
        nodes[0].payload.emphasis.children[0].tag,
    );
    try testing.expectEqualStrings(
        "foo _bar",
        std.mem.span(nodes[0].payload.emphasis.children[0].payload.text.value),
    );
}

test "interleaved emphasis" {
    // When emphasis is interleaved, first to open takes precedence.
    var value = "*_bar*_";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(2, nodes.len);

    try testing.expectEqual(ast.NodeType.emphasis, nodes[0].tag);
    try testing.expectEqual(1, nodes[0].payload.strong.n_children);
    try testing.expectEqual(
        ast.NodeType.text,
        nodes[0].payload.emphasis.children[0].tag,
    );
    try testing.expectEqualStrings(
        "_bar",
        std.mem.span(nodes[0].payload.emphasis.children[0].payload.text.value),
    );

    try testing.expectEqual(ast.NodeType.text, nodes[1].tag);
    try testing.expectEqualStrings(
        "_",
        std.mem.span(nodes[1].payload.text.value),
    );

    // Same test with symbols reversed
    value = "_*bar_*";
    const nodes2 = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes2);

    try testing.expectEqual(2, nodes2.len);

    try testing.expectEqual(ast.NodeType.emphasis, nodes2[0].tag);
    try testing.expectEqual(1, nodes2[0].payload.strong.n_children);
    try testing.expectEqual(
        ast.NodeType.text,
        nodes2[0].payload.emphasis.children[0].tag,
    );
    try testing.expectEqualStrings(
        "*bar",
        std.mem.span(nodes2[0].payload.emphasis.children[0].payload.text.value),
    );

    try testing.expectEqual(ast.NodeType.text, nodes2[1].tag);
    try testing.expectEqualStrings(
        "*",
        std.mem.span(nodes2[1].payload.text.value),
    );
}

test "nested interleaved emphasis" {
    // Surely an apparition from some deeper circle of hell?
    // This test makes sure that the rules about interleaved emphasis are
    // respected even when the closing token for the outermost emphasis comes
    // nested in several levels of emphasis.
    const value = "*_(_bar*_)_";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(2, nodes.len);

    try testing.expectEqual(ast.NodeType.emphasis, nodes[0].tag);
    try testing.expectEqual(1, nodes[0].payload.emphasis.n_children);
    try testing.expectEqual(
        ast.NodeType.text,
        nodes[0].payload.emphasis.children[0].tag,
    );
    try testing.expectEqualStrings(
        "_(_bar",
        std.mem.span(nodes[0].payload.emphasis.children[0].payload.text.value),
    );

    try testing.expectEqual(ast.NodeType.emphasis, nodes[1].tag);
    try testing.expectEqual(1, nodes[1].payload.emphasis.n_children);
    try testing.expectEqual(
        ast.NodeType.text,
        nodes[1].payload.emphasis.children[0].tag,
    );
    try testing.expectEqualStrings(
        ")",
        std.mem.span(nodes[1].payload.emphasis.children[0].payload.text.value),
    );
}

test "interleaved strong" {
    // When strong is interleaved, first to open takes precedence.
    var value = "**__bar**__";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(2, nodes.len);

    try testing.expectEqual(ast.NodeType.strong, nodes[0].tag);
    try testing.expectEqual(1, nodes[0].payload.strong.n_children);
    try testing.expectEqual(
        ast.NodeType.text,
        nodes[0].payload.strong.children[0].tag,
    );
    try testing.expectEqualStrings(
        "__bar",
        std.mem.span(nodes[0].payload.strong.children[0].payload.text.value),
    );

    try testing.expectEqual(ast.NodeType.text, nodes[1].tag);
    try testing.expectEqualStrings(
        "__",
        std.mem.span(nodes[1].payload.text.value),
    );

    // Same test with symbols reversed
    value = "__**bar__**";
    const nodes2 = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes2);

    try testing.expectEqual(2, nodes2.len);

    try testing.expectEqual(ast.NodeType.strong, nodes2[0].tag);
    try testing.expectEqual(1, nodes2[0].payload.strong.n_children);
    try testing.expectEqual(
        ast.NodeType.text,
        nodes2[0].payload.strong.children[0].tag,
    );
    try testing.expectEqualStrings(
        "**bar",
        std.mem.span(nodes2[0].payload.strong.children[0].payload.text.value),
    );

    try testing.expectEqual(ast.NodeType.text, nodes2[1].tag);
    try testing.expectEqualStrings(
        "**",
        std.mem.span(nodes2[1].payload.text.value),
    );
}

test "nested interleaved emphasis and strong" {
    // Surely an apparition from some deeper circle of hell?
    // This test makes sure that the rules about interleaved strong are
    // respected even when the closing token for the outermost strong comes
    // nested in several levels of strong.
    var value = "*__(_bar*_)__";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(2, nodes.len);

    try testing.expectEqual(ast.NodeType.emphasis, nodes[0].tag);
    try testing.expectEqual(1, nodes[0].payload.emphasis.n_children);
    try testing.expectEqual(
        ast.NodeType.text,
        nodes[0].payload.emphasis.children[0].tag,
    );
    try testing.expectEqualStrings(
        "__(_bar",
        std.mem.span(nodes[0].payload.emphasis.children[0].payload.text.value),
    );

    try testing.expectEqual(ast.NodeType.text, nodes[1].tag);
    try testing.expectEqualStrings(
        "_)__",
        std.mem.span(nodes[1].payload.text.value),
    );

    value = "_****foo_****";
    const nodes2 = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes2);

    try testing.expectEqual(2, nodes2.len);

    try testing.expectEqual(ast.NodeType.emphasis, nodes2[0].tag);
    try testing.expectEqual(1, nodes2[0].payload.emphasis.n_children);
    try testing.expectEqual(
        ast.NodeType.text,
        nodes2[0].payload.emphasis.children[0].tag,
    );
    try testing.expectEqualStrings(
        "****foo",
        std.mem.span(nodes2[0].payload.emphasis.children[0].payload.text.value),
    );

    try testing.expectEqual(ast.NodeType.text, nodes2[1].tag);
    try testing.expectEqualStrings(
        "****",
        std.mem.span(nodes2[1].payload.text.value),
    );
}

test "nesting feast of insanity" {
    const value = "**_My, __**hello**___, *what a __feast!__***";
    const nodes = try parseIntoNodes(value, .empty);
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
    try testing.expectEqual(ast.NodeType.strong, nodes[0].tag);
    try testing.expectEqual(3, nodes[0].payload.strong.n_children);

    const emph = nodes[0].payload.strong.children[0];
    try testing.expectEqual(ast.NodeType.emphasis, emph.tag);
    try testing.expectEqual(2, emph.payload.emphasis.n_children);
    {
        const child_text = emph.payload.emphasis.children[0];
        try testing.expectEqual(
            ast.NodeType.text,
            child_text.tag,
        );
        try testing.expectEqualStrings(
            "My, ",
            std.mem.span(child_text.payload.text.value),
        );

        const child_strong = emph.payload.emphasis.children[1];
        try testing.expectEqual(
            ast.NodeType.strong,
            child_strong.tag,
        );
        try testing.expectEqual(1, child_strong.payload.strong.n_children);
        const grandchild_strong = child_strong.payload.strong.children[0];
        try testing.expectEqual(
            ast.NodeType.strong,
            grandchild_strong.tag,
        );
        try testing.expectEqual(1, grandchild_strong.payload.strong.n_children);
        const ggrandchild_text = grandchild_strong.payload.strong.children[0];
        try testing.expectEqual(
            ast.NodeType.text,
            ggrandchild_text.tag,
        );
        try testing.expectEqualStrings(
            "hello",
            std.mem.span(ggrandchild_text.payload.text.value),
        );
    }

    const text = nodes[0].payload.strong.children[1];
    try testing.expectEqual(ast.NodeType.text, text.tag);
    try testing.expectEqualStrings(", ", std.mem.span(text.payload.text.value));

    const emph2 = nodes[0].payload.strong.children[2];
    try testing.expectEqual(ast.NodeType.emphasis, emph2.tag);
    try testing.expectEqual(2, emph2.payload.emphasis.n_children);
    {
        const child_text = emph2.payload.emphasis.children[0];
        try testing.expectEqual(
            ast.NodeType.text,
            child_text.tag,
        );
        try testing.expectEqualStrings(
            "what a ",
            std.mem.span(child_text.payload.text.value),
        );

        const child_strong = emph2.payload.emphasis.children[1];
        try testing.expectEqual(
            ast.NodeType.strong,
            child_strong.tag,
        );
        try testing.expectEqual(1, child_strong.payload.strong.n_children);
        const grandchild_text = child_strong.payload.strong.children[0];
        try testing.expectEqual(
            ast.NodeType.text,
            grandchild_text.tag,
        );
        try testing.expectEqualStrings(
            "feast!",
            std.mem.span(grandchild_text.payload.text.value),
        );
    }
}

test "emphasis with nonsignificant brackets" {
    const value = "[foo _bar] baz_";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(2, nodes.len);

    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);
    try testing.expectEqualStrings(
        "[foo ",
        std.mem.span(nodes[0].payload.text.value),
    );

    try testing.expectEqual(ast.NodeType.emphasis, nodes[1].tag);
    try testing.expectEqual(1, nodes[1].payload.emphasis.n_children);
    try testing.expectEqual(
        ast.NodeType.text,
        nodes[1].payload.emphasis.children[0].tag,
    );
    try testing.expectEqualStrings(
        "bar] baz",
        std.mem.span(nodes[1].payload.emphasis.children[0].payload.text.value),
    );
}

test "codespan and underscore emphasis" {
    const value = "`foo`_bim_`bar`";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);

    try testing.expectEqual(
        ast.NodeType.inline_code,
        nodes[0].tag,
    );
    try testing.expectEqualStrings(
        "foo",
        std.mem.span(nodes[0].payload.inline_code.value),
    );

    try testing.expectEqual(
        ast.NodeType.emphasis,
        nodes[1].tag,
    );
    try testing.expectEqualStrings(
        "bim",
        std.mem.span(nodes[1].payload.emphasis.children[0].payload.text.value),
    );

    try testing.expectEqual(
        ast.NodeType.inline_code,
        nodes[2].tag,
    );
    try testing.expectEqualStrings(
        "bar",
        std.mem.span(nodes[2].payload.inline_code.value),
    );
}

test "codespan strip space" {
    const value = "` ``foo`` `";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(
        ast.NodeType.inline_code,
        nodes[0].tag,
    );
    try testing.expectEqualStrings(
        "``foo``",
        std.mem.span(nodes[0].payload.inline_code.value),
    );
}

// Escaping is not allowed in code spans.
test "codespan escaped backtick" {
    const value = "``foo\\`` bar\\`";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(2, nodes.len);

    try testing.expectEqual(ast.NodeType.inline_code, nodes[0].tag);
    try testing.expectEqualStrings(
        "foo\\",
        std.mem.span(nodes[0].payload.inline_code.value),
    );

    try testing.expectEqual(ast.NodeType.text, nodes[1].tag);
    try testing.expectEqualStrings(
        " bar`",
        std.mem.span(nodes[1].payload.inline_code.value),
    );
}

test "inline link containing emphasis" {
    const value = "[*my link*]()";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(
        ast.NodeType.link,
        nodes[0].tag,
    );

    try testing.expectEqual(1, nodes[0].payload.link.n_children);
    const emph = nodes[0].payload.link.children[0];
    try testing.expectEqual(
        ast.NodeType.emphasis,
        emph.tag,
    );
    try testing.expectEqualStrings(
        "my link",
        std.mem.span(emph.payload.emphasis.children[0].payload.text.value),
    );
}

test "inline link emphasis precedence" {
    const value = "*[foo*]()";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(2, nodes.len);

    try testing.expectEqual(
        ast.NodeType.text,
        nodes[0].tag,
    );
    try testing.expectEqualStrings(
        "*",
        std.mem.span(nodes[0].payload.text.value),
    );

    const link_node = nodes[1];
    try testing.expectEqual(
        ast.NodeType.link,
        link_node.tag,
    );

    try testing.expectEqual(1, link_node.payload.link.n_children);
    try testing.expectEqual(
        ast.NodeType.text,
        link_node.payload.link.children[0].tag,
    );
    try testing.expectEqualStrings(
        "foo*",
        std.mem.span(link_node.payload.link.children[0].payload.text.value),
    );
}

test "inline link with hyphens, slashes, and equals" {
    const value = "[foo-bar](google.com/bim-bam?q=bar)";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.link, nodes[0].tag);
    try testing.expectEqualStrings(
        "google.com/bim-bam?q=bar",
        std.mem.span(nodes[0].payload.link.url),
    );

    try testing.expectEqual(1, nodes[0].payload.link.n_children);
    const text = nodes[0].payload.link.children[0];
    try testing.expectEqual(ast.NodeType.text, text.tag);
    try testing.expectEqualStrings(
        "foo-bar",
        std.mem.span(text.payload.text.value),
    );
}

test "inline link nesting not allowed" {
    const value = "[foo [bar]()]()";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);

    try testing.expectEqual(
        ast.NodeType.text,
        nodes[0].tag,
    );
    try testing.expectEqualStrings(
        "[foo ",
        std.mem.span(nodes[0].payload.text.value),
    );

    try testing.expectEqual(
        ast.NodeType.link,
        nodes[1].tag,
    );

    try testing.expectEqual(
        ast.NodeType.text,
        nodes[2].tag,
    );
    try testing.expectEqualStrings(
        "]()",
        std.mem.span(nodes[2].payload.text.value),
    );
}

test "inline link destination angle brackets" {
    const value = "[foo](<bar>)";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.link, nodes[0].tag);

    try testing.expectEqualStrings(
        "bar",
        std.mem.span(nodes[0].payload.link.url),
    );
}

test "inline link destination no angle brackets" {
    const value = "[foo](bar)";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.link, nodes[0].tag);

    try testing.expectEqualStrings(
        "bar",
        std.mem.span(nodes[0].payload.link.url),
    );
}

test "inline link with destination and title" {
    const value = "[foo](bar (baz))";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.link, nodes[0].tag);

    try testing.expectEqualStrings(
        "bar",
        std.mem.span(nodes[0].payload.link.url),
    );
    try testing.expectEqualStrings(
        "baz",
        std.mem.span(nodes[0].payload.link.title),
    );
}

test "inline link with exclamation mark" {
    const value = "[foo!](bar)";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.link, nodes[0].tag);

    try testing.expectEqualStrings(
        "bar",
        std.mem.span(nodes[0].payload.link.url),
    );

    try testing.expectEqual(1, nodes[0].payload.link.n_children);
    const text = nodes[0].payload.link.children[0];
    try testing.expectEqual(
        ast.NodeType.text,
        text.tag,
    );
    try testing.expectEqualStrings("foo!", std.mem.span(text.payload.text.value));
}

test "inline link nested emphasis with nonsignificant brackets" {
    // Makes sure we can handle square brackets that DON'T end the link text
    // within nested emphasis.
    const value = "[_[_[*foo[]]]*](/bar)";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.link, nodes[0].tag);

    const link_node = nodes[0];
    try testing.expectEqualStrings(
        "/bar",
        std.mem.span(link_node.payload.link.url),
    );
    try testing.expectEqualStrings(
        "",
        std.mem.span(link_node.payload.link.title),
    );

    try testing.expectEqual(3, link_node.payload.link.n_children);

    // first emphasis node
    try testing.expectEqual(
        ast.NodeType.emphasis,
        link_node.payload.link.children[0].tag,
    );
    {
        const emphasis_node = link_node.payload.link.children[0];
        try testing.expectEqual(1, emphasis_node.payload.emphasis.n_children);
        try testing.expectEqual(
            ast.NodeType.text,
            emphasis_node.payload.emphasis.children[0].tag,
        );
        try testing.expectEqualStrings(
            "[",
            std.mem.span(
                emphasis_node.payload.emphasis.children[0].payload.text.value
            ),
        );
    }

    // text node
    try testing.expectEqual(
        ast.NodeType.text,
        link_node.payload.link.children[1].tag,
    );
    try testing.expectEqualStrings(
        "[",
        std.mem.span(link_node.payload.link.children[1].payload.text.value),
    );

    // second emphasis node
    try testing.expectEqual(
        ast.NodeType.emphasis,
        link_node.payload.link.children[2].tag,
    );
    {
        const emphasis_node = link_node.payload.link.children[2];
        try testing.expectEqual(1, emphasis_node.payload.emphasis.n_children);
        try testing.expectEqual(
            ast.NodeType.text,
            emphasis_node.payload.emphasis.children[0].tag,
        );
        try testing.expectEqualStrings(
            "foo[]]]",
            std.mem.span(
                emphasis_node.payload.emphasis.children[0].payload.text.value
            ),
        );
    }
}

test "URI autolink" {
    const value = "<http://foo.com/bar?bim[]=baz>";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.link, nodes[0].tag);

    const link_node = nodes[0];
    try testing.expectEqualStrings(
        "http://foo.com/bar?bim%5B%5D=baz",
        std.mem.span(link_node.payload.link.url),
    );
    try testing.expectEqualStrings(
        "",
        std.mem.span(link_node.payload.link.title),
    );

    try testing.expectEqual(1, link_node.payload.link.n_children);
    try testing.expectEqual(
        ast.NodeType.text,
        link_node.payload.link.children[0].tag,
    );
    try testing.expectEqualStrings(
        "http://foo.com/bar?bim[]=baz",
        std.mem.span(link_node.payload.link.children[0].payload.text.value),
    );
}

test "email autolink" {
    const value = "<person@gmail.com>";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.link, nodes[0].tag);

    const link_node = nodes[0];
    try testing.expectEqualStrings(
        "mailto:person@gmail.com",
        std.mem.span(link_node.payload.link.url),
    );
    try testing.expectEqualStrings(
        "",
        std.mem.span(link_node.payload.link.title),
    );

    try testing.expectEqual(1, link_node.payload.link.n_children);
    try testing.expectEqual(
        ast.NodeType.text,
        link_node.payload.link.children[0].tag,
    );
    try testing.expectEqualStrings(
        "person@gmail.com",
        std.mem.span(link_node.payload.link.children[0].payload.text.value),
    );
}

test "image" {
    const value = "![foo](/bar \"bim\")";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.image, nodes[0].tag);

    const image_node = nodes[0];
    try testing.expectEqualStrings(
        "foo",
        std.mem.span(image_node.payload.image.alt),
    );
    try testing.expectEqualStrings(
        "/bar",
        std.mem.span(image_node.payload.image.url),
    );
    try testing.expectEqualStrings(
        "bim",
        std.mem.span(image_node.payload.image.title),
    );
}

test "image complicated alt text" {
    const value = "![*foo* __bim__](/bar)";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.image, nodes[0].tag);

    const image_node = nodes[0];
    try testing.expectEqualStrings(
        "foo bim",
        std.mem.span(image_node.payload.image.alt),
    );
    try testing.expectEqualStrings(
        "/bar",
        std.mem.span(image_node.payload.image.url),
    );
}

test "image inside link" {
    const value = "[![](/foo.jpg)](/bar.com/baz)";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.link, nodes[0].tag);
    const link_node = nodes[0];
    try testing.expectEqualStrings(
        "/bar.com/baz",
        std.mem.span(link_node.payload.link.url),
    );
    try testing.expectEqualStrings(
        "",
        std.mem.span(link_node.payload.link.title),
    );

    try testing.expectEqual(1, link_node.payload.link.n_children);
    try testing.expectEqual(
        ast.NodeType.image,
        link_node.payload.link.children[0].tag,
    );
    try testing.expectEqualStrings(
        "/foo.jpg",
        std.mem.span(link_node.payload.link.children[0].payload.image.url),
    );
}

test "link inside image" {
    // This parses, but doesn't really work; alt text should be empty
    const value = "![[](/bar.com/baz)](/foo.jpg)";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.image, nodes[0].tag);

    try testing.expectEqualStrings(
        "/foo.jpg",
        std.mem.span(nodes[0].payload.image.url),
    );
    try testing.expectEqualStrings(
        "",
        std.mem.span(nodes[0].payload.image.title),
    );
    try testing.expectEqualStrings(
        "",
        std.mem.span(nodes[0].payload.image.alt),
    );
}

test "full reference link" {
    const value = "[my text][foo]";

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);
    var def: ast.LinkDefinition = .{
        .url = "/bar",
        .title = "bim",
        .label = "foo",
    };
    try link_defs.add(testing.allocator, &def);

    const nodes = try parseIntoNodes(value, link_defs);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.link, nodes[0].tag);

    const link_node = nodes[0];
    try testing.expectEqualStrings(
        "/bar",
        std.mem.span(link_node.payload.link.url),
    );
    try testing.expectEqualStrings(
        "bim",
        std.mem.span(link_node.payload.link.title),
    );

    try testing.expectEqual(1, link_node.payload.link.n_children);
    const text_node = link_node.payload.link.children[0];
    try testing.expectEqual(ast.NodeType.text, text_node.tag);
    try testing.expectEqualStrings(
        "my text",
        std.mem.span(text_node.payload.text.value),
    );
}

test "collapsed reference link" {
    const value = "[my *text*][]";

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);
    var def: ast.LinkDefinition = .{
        .url = "/bar",
        .title = "bim",
        .label = "my *text*",
    };
    try link_defs.add(testing.allocator, &def);

    const nodes = try parseIntoNodes(value, link_defs);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.link, nodes[0].tag);

    const link_node = nodes[0];
    try testing.expectEqualStrings(
        "/bar",
        std.mem.span(link_node.payload.link.url),
    );
    try testing.expectEqualStrings(
        "bim",
        std.mem.span(link_node.payload.link.title),
    );

    try testing.expectEqual(2, link_node.payload.link.n_children);

    const text_node = link_node.payload.link.children[0];
    try testing.expectEqual(ast.NodeType.text, text_node.tag);
    try testing.expectEqualStrings(
        "my ",
        std.mem.span(text_node.payload.text.value),
    );

    const emph_node = link_node.payload.link.children[1];
    try testing.expectEqual(
        ast.NodeType.emphasis,
        emph_node.tag,
    );
    try testing.expectEqualStrings(
        "text",
        std.mem.span(emph_node.payload.emphasis.children[0].payload.text.value),
    );
}

test "shortcut reference link" {
    const value = "[my *text*]";

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);
    var def: ast.LinkDefinition = .{
        .url = "/bar",
        .title = "bim",
        .label = "my *text*",
    };
    try link_defs.add(testing.allocator, &def);

    const nodes = try parseIntoNodes(value, link_defs);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.link, nodes[0].tag);

    const link_node = nodes[0];
    try testing.expectEqualStrings(
        "/bar",
        std.mem.span(link_node.payload.link.url),
    );
    try testing.expectEqualStrings(
        "bim",
        std.mem.span(link_node.payload.link.title),
    );

    try testing.expectEqual(2, link_node.payload.link.n_children);

    const text_node = link_node.payload.link.children[0];
    try testing.expectEqual(ast.NodeType.text, text_node.tag);
    try testing.expectEqualStrings(
        "my ",
        std.mem.span(text_node.payload.text.value),
    );

    const emph_node = link_node.payload.link.children[1];
    try testing.expectEqual(
        ast.NodeType.emphasis,
        emph_node.tag,
    );
    try testing.expectEqualStrings(
        "text",
        std.mem.span(emph_node.payload.emphasis.children[0].payload.text.value),
    );
}

test "full reference image" {
    const value = "![my image description][foo]";

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);
    var def: ast.LinkDefinition = .{
        .url = "/image.jpg",
        .title = "bim",
        .label = "foo",
    };
    try link_defs.add(testing.allocator, &def);

    const nodes = try parseIntoNodes(value, link_defs);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.image, nodes[0].tag);

    const img_node = nodes[0];
    try testing.expectEqualStrings(
        "/image.jpg",
        std.mem.span(img_node.payload.image.url),
    );
    try testing.expectEqualStrings(
        "bim",
        std.mem.span(img_node.payload.image.title),
    );
    try testing.expectEqualStrings(
        "my image description",
        std.mem.span(img_node.payload.image.alt),
    );
}

test "collapsed reference image" {
    const value = "![foo][]";

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);
    var def: ast.LinkDefinition = .{
        .url = "/image.jpg",
        .title = "bim",
        .label = "foo",
    };
    try link_defs.add(testing.allocator, &def);

    const nodes = try parseIntoNodes(value, link_defs);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.image, nodes[0].tag);

    const img_node = nodes[0];
    try testing.expectEqualStrings(
        "/image.jpg",
        std.mem.span(img_node.payload.image.url),
    );
    try testing.expectEqualStrings(
        "bim",
        std.mem.span(img_node.payload.image.title),
    );
    try testing.expectEqualStrings(
        "foo",
        std.mem.span(img_node.payload.image.alt),
    );
}

test "shortcut reference image" {
    const value = "![foo]";

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);
    var def: ast.LinkDefinition = .{
        .url = "/image.jpg",
        .title = "bim",
        .label = "foo",
    };
    try link_defs.add(testing.allocator, &def);

    const nodes = try parseIntoNodes(value, link_defs);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.image, nodes[0].tag);

    const img_node = nodes[0];
    try testing.expectEqualStrings(
        "/image.jpg",
        std.mem.span(img_node.payload.image.url),
    );
    try testing.expectEqualStrings(
        "bim",
        std.mem.span(img_node.payload.image.title),
    );
    try testing.expectEqualStrings(
        "foo",
        std.mem.span(img_node.payload.image.alt),
    );
}

test "image nested emphasis with nonsignificant brackets" {
    // Ensures we can handle brackets within the image description
    const value = "![_[_[*foo[]]]*](/bar)";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.image, nodes[0].tag);

    const img_node = nodes[0];
    try testing.expectEqualStrings(
        "/bar",
        std.mem.span(img_node.payload.image.url),
    );
    try testing.expectEqualStrings(
        "[[foo[]]]",
        std.mem.span(img_node.payload.image.alt),
    );
    try testing.expectEqualStrings(
        "",
        std.mem.span(img_node.payload.image.title),
    );
}

test "image emphasis precedence" {
    // This is CommonMark spec example 521, but for images instead of links
    const value = "![foo *bar](baz*)";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.image, nodes[0].tag);

    const img_node = nodes[0];
    try testing.expectEqualStrings(
        "baz*",
        std.mem.span(img_node.payload.image.url),
    );
    try testing.expectEqualStrings(
        "foo *bar",
        std.mem.span(img_node.payload.image.alt),
    );
    try testing.expectEqualStrings(
        "",
        std.mem.span(img_node.payload.image.title),
    );
}

test "hard line break" {
    const value = "foo bar  \n bim bam";

    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(3, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);
    try testing.expectEqual(
        ast.NodeType.@"break",
        nodes[1].tag,
    );
    try testing.expectEqual(ast.NodeType.text, nodes[2].tag);

    try testing.expectEqualStrings(
        "foo bar",
        std.mem.span(nodes[0].payload.text.value),
    );
    try testing.expectEqualStrings(
        "bim bam",
        std.mem.span(nodes[2].payload.text.value),
    );
}

test "soft line break" {
    const value = "foo bar \n bim bam";

    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.text, nodes[0].tag);
    try testing.expectEqualStrings(
        "foo bar\nbim bam",
        std.mem.span(nodes[0].payload.text.value),
    );
}

test "html open tag" {
    const value = "<span>";

    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.html, nodes[0].tag);
    try testing.expectEqualStrings(
        "<span>",
        std.mem.span(nodes[0].payload.html.value),
    );
}

test "html open tag with empty element" {
    const value = "<foo/>";

    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.html, nodes[0].tag);
    try testing.expectEqualStrings(
        "<foo/>",
        std.mem.span(nodes[0].payload.html.value),
    );
}

test "html open tag with number in tag name" {
    const value = "<h2>";

    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.html, nodes[0].tag);
    try testing.expectEqualStrings(
        "<h2>",
        std.mem.span(nodes[0].payload.html.value),
    );
}

test "html open tag unquoted attributes" {
    const value = "<span bim class=foobar>";

    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.html, nodes[0].tag);
    try testing.expectEqualStrings(
        "<span bim class=foobar>",
        std.mem.span(nodes[0].payload.html.value),
    );
}

test "html open tag quoted attributes" {
    const value = "<span id=\"bim baz\" class='foo_bar'>";

    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.html, nodes[0].tag);
    try testing.expectEqualStrings(
        "<span id=\"bim baz\" class='foo_bar'>",
        std.mem.span(nodes[0].payload.html.value),
    );
}

// Backslash escapes don't work within HTML attributes but should work outside.
test "html open tag quoted attribute escape" {
    const value = "<span id=\"bim\\\" class='foo_bar\\'> foo\\' \\\"bar\\\"";

    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(2, nodes.len);

    try testing.expectEqual(ast.NodeType.html, nodes[0].tag);
    try testing.expectEqualStrings(
        "<span id=\"bim\\\" class='foo_bar\\'>",
        std.mem.span(nodes[0].payload.html.value),
    );

    try testing.expectEqual(ast.NodeType.text, nodes[1].tag);
    try testing.expectEqualStrings(
        " foo' \"bar\"",
        std.mem.span(nodes[1].payload.html.value),
    );
}

// Escaped backtick is allowed in quoted attribute.
test "html open tag quoted attribute escaped backtick" {
    const value = "<span class='foo_\\`bar'>";

    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);

    try testing.expectEqual(ast.NodeType.html, nodes[0].tag);
    try testing.expectEqualStrings(
        "<span class='foo_\\`bar'>",
        std.mem.span(nodes[0].payload.html.value),
    );
}

test "html open tag multiple" {
    const value = "<foo /><bar />";

    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(2, nodes.len);

    try testing.expectEqual(ast.NodeType.html, nodes[0].tag);
    try testing.expectEqualStrings(
        "<foo />",
        std.mem.span(nodes[0].payload.html.value),
    );

    try testing.expectEqual(ast.NodeType.html, nodes[1].tag);
    try testing.expectEqualStrings(
        "<bar />",
        std.mem.span(nodes[1].payload.html.value),
    );
}

test "html close tag multiple" {
    const value = "</foo></bar>";

    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(2, nodes.len);

    try testing.expectEqual(ast.NodeType.html, nodes[0].tag);
    try testing.expectEqualStrings(
        "</foo>",
        std.mem.span(nodes[0].payload.html.value),
    );

    try testing.expectEqual(ast.NodeType.html, nodes[1].tag);
    try testing.expectEqualStrings(
        "</bar>",
        std.mem.span(nodes[1].payload.html.value),
    );
}

test "html tags with hyphens" {
    const value = "<foo-bar bim-bam=zim-zap></foo-bar>";

    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(2, nodes.len);

    try testing.expectEqual(ast.NodeType.html, nodes[0].tag);
    try testing.expectEqualStrings(
        "<foo-bar bim-bam=zim-zap>",
        std.mem.span(nodes[0].payload.html.value),
    );

    try testing.expectEqual(ast.NodeType.html, nodes[1].tag);
    try testing.expectEqualStrings(
        "</foo-bar>",
        std.mem.span(nodes[1].payload.html.value),
    );
}

test "html comment" {
    const value = "<!-- I am a comment -->";

    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.html, nodes[0].tag);
    try testing.expectEqualStrings(
        "<!-- I am a comment -->",
        std.mem.span(nodes[0].payload.html.value),
    );
}

test "html/xml processing instruction" {
    const value = "<? foobar-bim zap:foo ?>";

    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.html, nodes[0].tag);
    try testing.expectEqualStrings(
        "<? foobar-bim zap:foo ?>",
        std.mem.span(nodes[0].payload.html.value),
    );
}

test "html/xml declaration" {
    const value = "<!foobar-bim zap:foo >";

    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.html, nodes[0].tag);
    try testing.expectEqualStrings(
        "<!foobar-bim zap:foo >",
        std.mem.span(nodes[0].payload.html.value),
    );
}

test "html CDATA section" {
    const value = "<![CDATA[ foo bar bim < & ]]>";

    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.html, nodes[0].tag);
    try testing.expectEqualStrings(
        "<![CDATA[ foo bar bim < & ]]>",
        std.mem.span(nodes[0].payload.html.value),
    );
}

test "html within emphasis" {
    const value = "*<foo></foo>*";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.emphasis, nodes[0].tag);
    try testing.expectEqual(2, nodes[0].payload.emphasis.n_children);
    try testing.expectEqual(
        ast.NodeType.html,
        nodes[0].payload.emphasis.children[0].tag,
    );
    try testing.expectEqual(
        ast.NodeType.html,
        nodes[0].payload.emphasis.children[1].tag,
    );
}

test "html within strong" {
    const value = "__<foo></foo>__";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.strong, nodes[0].tag);
    try testing.expectEqual(2, nodes[0].payload.strong.n_children);
    try testing.expectEqual(
        ast.NodeType.html,
        nodes[0].payload.strong.children[0].tag,
    );
    try testing.expectEqual(
        ast.NodeType.html,
        nodes[0].payload.strong.children[1].tag,
    );
}

test "html within link" {
    const value = "[<foo></foo>](foobar.com/url)";
    const nodes = try parseIntoNodes(value, .empty);
    defer freeNodes(nodes);

    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(ast.NodeType.link, nodes[0].tag);
    try testing.expectEqualStrings(
        "foobar.com/url",
        std.mem.span(nodes[0].payload.link.url),
    );
    try testing.expectEqual(2, nodes[0].payload.link.n_children);
    try testing.expectEqual(
        ast.NodeType.html,
        nodes[0].payload.link.children[0].tag,
    );
    try testing.expectEqual(
        ast.NodeType.html,
        nodes[0].payload.link.children[1].tag,
    );
}

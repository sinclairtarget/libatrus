//! Parser in the first parsing stage that handles container block parsing.
//!
//! Control flow is a little wonky:
//! * This parser does not directly read from the given tokenizer.
//! * Instead, it sets up a token stream for a LeafBlockParser.
//! * As the LeafBlockParser advances, this parser intercepts tokens that are
//!   meaningful for container-level parsing.
//! * This parser maintains a stack of open container blocks, adding parsed
//!   leaf nodes to the container topmost on the stack.
//!
//! Containers can nest arbitrarily. We support this using the following
//! approach.
//!
//! At the beginning of each new line, we ask each container in the stack,
//! starting from the bottom container, to "establish" itself. This means that
//! the container consumes tokens from the tokens stream necessary to keep that
//! container open. If this is successful, the container stays open and the
//! topmost container processes all remaining tokens in the line. If any
//! container cannot establish itself, that container and all containers above
//! it in the stack are closed.
//!
//! Only the topmost container can push new containers onto the stack.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const fmt = std.fmt;

const ast = @import("../ast.zig");
const cmark = @import("../cmark/cmark.zig");
const logging = @import("../logging.zig");
const BlockToken = @import("../lex/tokens.zig").BlockToken;
const BlockTokenType = @import("../lex/tokens.zig").BlockTokenType;
const whitespaceLen = @import("../lex/tokens.zig").whitespaceLen;
const LeafBlockParser = @import("LeafBlockParser.zig");
const LinkDefMap = @import("link_defs.zig").LinkDefMap;
const TokenIterator = @import("../lex/iterator.zig").TokenIterator;
const util = @import("../util/util.zig");

const logger = logging.logger(.container);

const Error = error{
    LineTooLong,
    ReadFailed,
    WriteFailed,
} || Allocator.Error || cmark.character_refs.CharacterReferenceError;

const TokenError = error{
    LineTooLong,
    ReadFailed,
    WriteFailed,
} || Allocator.Error;

/// Represents a container block that is open (can still have children added to
/// it) and hasn't yet been turned into an AST node.
const ContainerBlock = struct {
    children: ArrayList(*ast.Node) = .empty,
    start_line_num: usize,
    variant: union(enum) {
        root,
        blockquote: struct {
            soft_closed: bool = false,
        },
        bullet_list: struct {
            marker_token_type: BlockTokenType,
            first_blank_line_num: ?usize = null,
            last_blank_line_num: ?usize = null,
        },
        bullet_list_item: struct {
            indent: u32,
            starts_with_blank_line: bool = false,
            first_blank_line_num: ?usize = null,
            last_blank_line_num: ?usize = null,
            soft_closed: bool = false,
        },
        ordered_list: struct {
            marker_token_type: BlockTokenType,
            start: u32,
            first_blank_line_num: ?usize = null,
            last_blank_line_num: ?usize = null,
        },
        ordered_list_item: struct {
            indent: u32,
            starts_with_blank_line: bool = false,
            first_blank_line_num: ?usize = null,
            last_blank_line_num: ?usize = null,
            soft_closed: bool = false,
        },
    },

    fn name(self: ContainerBlock) []const u8 {
        return @tagName(self.variant);
    }

    fn isList(self: ContainerBlock) bool {
        return switch (self.variant) {
            .bullet_list, .ordered_list => true,
            .root, .blockquote, .bullet_list_item, .ordered_list_item => false,
        };
    }

    fn addChild(
        self: *ContainerBlock,
        scratch: Allocator,
        child: *ast.Node,
    ) !void {
        // Make sure we only ever add list items to a list.
        if (self.isList()) {
            const node_type = @as(ast.NodeType, child.*);
            std.debug.assert(node_type == .list_item);
        }

        try self.children.append(scratch, child);
    }

    fn establish(
        self: *ContainerBlock,
        scratch: Allocator,
        it: *TokenIterator(BlockTokenType),
        line_num: usize,
    ) !bool {
        const checkpoint_index = it.checkpoint();
        var did_establish = false;
        defer if (!did_establish) {
            it.backtrack(checkpoint_index);
        };

        did_establish = switch (self.variant) {
            .root => true, // always established
            .bullet_list, .ordered_list => blk: {
                const next_token = try it.peek(scratch);
                break :blk next_token != null;
            },
            .blockquote => blk: {
                if (try parseBlockquoteOpen(scratch, it, line_num)) |_| {
                    break :blk true;
                }

                break :blk false;
            },
            inline .bullet_list_item, .ordered_list_item => |*payload| blk: {
                const ws_tokens = try it.consumeWhitespaceUpTo(
                    scratch,
                    payload.indent,
                );
                if (whitespaceLen(ws_tokens) >= payload.indent) {
                    break :blk true;
                }

                if (try it.peek(scratch)) |next_token| {
                    if (next_token.token_type == .newline) {
                        if (payload.starts_with_blank_line and
                            line_num == self.start_line_num + 1)
                        {
                            // List item cannot start with more than one blank
                            // line.
                            break :blk false;
                        }

                        break :blk true;
                    }
                }

                break :blk false;
            },
        };

        return did_establish;
    }

    fn openChildContainer(
        self: ContainerBlock,
        scratch: Allocator,
        it: *TokenIterator(BlockTokenType),
        in_paragraph: bool,
        line_num: usize,
    ) !?ContainerBlock {
        // Thematic breaks take precedence over container structures.
        //
        // This is a little ugly, but we check here to see if we have a
        // thematic break. If we do, then we must let the leaf block parser
        // parse it.
        if (try peekThematicBreak(scratch, it)) {
            return null;
        }

        switch (self.variant) {
            .root, .blockquote, .bullet_list_item, .ordered_list_item => {
                return try parseAnyContainerOpen(
                    scratch,
                    it,
                    in_paragraph,
                    line_num,
                );
            },
            .bullet_list => |payload| {
                if (try parseBulletListItemOpen(
                    scratch,
                    it,
                    payload.marker_token_type,
                    line_num,
                )) |container| {
                    return container;
                }
            },
            .ordered_list => |payload| {
                if (try parseOrderedListItemOpen(
                    scratch,
                    it,
                    payload.marker_token_type,
                    line_num,
                )) |container| {
                    return container;
                }
            },
        }

        return null;
    }

    fn recordBlankLine(self: *ContainerBlock, line_num: usize) void {
        if (line_num <= self.start_line_num) {
            return;
        }

        switch (self.variant) {
            inline .bullet_list_item,
            .ordered_list_item,
            .bullet_list,
            .ordered_list,
            => |*payload| {
                if (payload.first_blank_line_num == null) {
                    payload.first_blank_line_num = line_num;
                }
                payload.last_blank_line_num = line_num;
            },
            else => {},
        }
    }

    /// Close this container block, turning it into an AST node.
    fn toNode(
        self: ContainerBlock,
        alloc: Allocator,
        line_num: usize,
    ) !*ast.Node {
        const owned_children = try alloc.dupe(*ast.Node, self.children.items);
        errdefer alloc.free(owned_children);

        const has_interior_blank_line = blk: {
            switch (self.variant) {
                inline .bullet_list_item,
                .ordered_list_item,
                .bullet_list,
                .ordered_list,
                => |payload| {
                    if (payload.first_blank_line_num) |i| {
                        if (i < line_num - 1) {
                            break :blk true;
                        }
                    }
                },
                else => {},
            }

            break :blk false;
        };

        const node = try alloc.create(ast.Node);
        switch (self.variant) {
            .root => {
                node.* = .{
                    .root = .{
                        .children = owned_children,
                    },
                };
            },
            .blockquote => {
                node.* = .{
                    .blockquote = .{
                        .children = owned_children,
                    },
                };
            },
            inline .bullet_list_item, .ordered_list_item => {
                const spread = isSpreadListItem(has_interior_blank_line);
                node.* = .{
                    .list_item = .{
                        .children = owned_children,
                        .spread = spread,
                    },
                };
            },
            .bullet_list => {
                const spread = isSpreadList(
                    owned_children,
                    has_interior_blank_line,
                );
                if (!spread) {
                    for (owned_children) |child| {
                        try unwrapParagraphs(alloc, child);
                    }
                }
                node.* = .{
                    .list = .{
                        .children = owned_children,
                        .ordered = false,
                        .spread = spread,
                    },
                };
            },
            .ordered_list => |payload| {
                const spread = isSpreadList(
                    owned_children,
                    has_interior_blank_line,
                );
                if (!spread) {
                    for (owned_children) |child| {
                        try unwrapParagraphs(alloc, child);
                    }
                }
                node.* = .{
                    .list = .{
                        .children = owned_children,
                        .ordered = true,
                        .spread = spread,
                        .start = payload.start,
                    },
                };
            },
        }

        return node;
    }
};

// Iterator that the container block parser consumes
it: *TokenIterator(BlockTokenType),
leaf_parser: ?LeafBlockParser,
container_stack: ArrayList(ContainerBlock),
unestablished_container_i: usize,
can_open_containers: bool,
override_spread: bool,
line_num: usize,

const Self = @This();

pub fn init(
    it: *TokenIterator(BlockTokenType),
    opts: struct { override_spread: bool = false },
) Self {
    return .{
        .it = it,
        .leaf_parser = null,
        .container_stack = .empty,
        .unestablished_container_i = 0,
        .can_open_containers = true,
        .override_spread = opts.override_spread,
        .line_num = 1,
    };
}

/// Parses block tokens into container blocks.
///
/// Returns the root node of the AST.
///
/// Caller owns the returned AST.
pub fn parse(
    self: *Self,
    alloc: Allocator,
    scratch: Allocator,
    link_defs: *LinkDefMap,
) Error!*ast.Node {
    try self.container_stack.append(scratch, .{
        .variant = .{ .root = {} },
        .start_line_num = 1,
    });
    self.unestablished_container_i = 0;
    self.can_open_containers = true;

    var leaf_it = self.iterator();
    for (0..util.safety.loop_bound) |_| {
        for (self.container_stack.items) |container| {
            logger.debug("[{s}]", .{container.name()});
        }

        // Some kind of handling of list containers has to go here. There could
        // be tokens still in the buffer within leaf_it. If we call
        // LeafBlockParser.parse() on this leaf_it, it will consume the token
        // before any of the logic in the iterator func below can run and we'd
        // end up adding leaf block children to a list container, which is
        // invalid.
        if (!leaf_it.is_exhausted and
            leaf_it.tokens.items.len > leaf_it.token_index and
            self.top().isList())
        {
            logger.debug(
                "Popping list container because of buffered tokens",
                .{},
            );
            try self.pop(alloc, scratch);
            continue;
        }

        if (leaf_it.is_exhausted) {
            leaf_it = self.iterator(); // reset iterator
        }

        self.leaf_parser = .{ .it = &leaf_it };
        const loop_start_stack_len = self.container_stack.items.len;

        // Internal iterator logic runs, potentially pushing onto stack
        const nodes = try self.leaf_parser.?.parse(alloc, scratch, link_defs);
        errdefer {
            for (nodes) |node| {
                node.deinit(alloc);
            }
        }
        defer alloc.free(nodes);

        const original_top = &self.container_stack.items[
            loop_start_stack_len - 1
        ];
        for (nodes) |node| {
            try original_top.addChild(scratch, node);
        }

        if (self.container_stack.items.len > loop_start_stack_len) {
            // We pushed a new container
            std.debug.assert(leaf_it.is_exhausted);
            continue;
        }

        if (self.container_stack.items.len <= 1) {
            break; // reached root
        }

        try self.pop(alloc, scratch);
    } else @panic(util.safety.loop_bound_panic_msg);

    const root = try self.top().toNode(alloc, self.line_num);
    errdefer root.deinit();

    if (self.override_spread) {
        overrideSpread(root);
    }
    return root;
}

/// Iterator for the leaf block parser to consume
fn iterator(self: *Self) TokenIterator(BlockTokenType) {
    return TokenIterator(BlockTokenType).init(self, &nextIterator);
}

/// Called by LeafBlockParser to get next token.
fn nextIterator(ctx: *anyopaque, scratch: Allocator) TokenError!?BlockToken {
    const self: *Self = @ptrCast(@alignCast(ctx));

    const maybe_token = try self.next(scratch);
    if (maybe_token) |token| {
        logger.debug("{f}", .{token});
    } else {
        logger.debug("NULL", .{});
    }

    return maybe_token;
}

fn next(self: *Self, scratch: Allocator) TokenError!?BlockToken {
    if (self.can_open_containers) {
        // We're at the beginning of the line. We need to establish any stacked
        // containers.
        if (self.unestablished_container_i == 0) {
            for (0..self.container_stack.items.len) |i| {
                const container = &self.container_stack.items[i];
                if (!try container.establish(
                    scratch,
                    self.it,
                    self.line_num,
                )) {
                    break;
                }

                self.unestablished_container_i += 1;
            }
        }

        if (self.unestablished_container_i < self.container_stack.items.len) {
            // Top container has not been established. It needs to be closed.
            const top_container = self.top();
            switch (top_container.variant) {
                .root, .bullet_list, .ordered_list => {
                    return null;
                },
                inline .blockquote,
                .bullet_list_item,
                .ordered_list_item,
                => |*payload| {
                    // Soft close.
                    if (!payload.soft_closed) {
                        payload.soft_closed = true;
                        return .{ .token_type = .close };
                    }
                },
            }
        }

        // We now look for tokens that could open new containers.
        //
        // When the top container is still open, we look to parse only those
        // containers that could be children of the top container. If we find
        // one, we push it onto the stack.
        //
        // When the top container has been soft-closed, we look to parse a
        // container that could be the child of the *parent* container (or
        // sometimes even grandparent container). If we find one, we don't push
        // it onto the stack but we do hard-close the top container.
        if (self.leaf_parser.?.interruptible) {
            const top_container = self.top();

            const checkpoint_index = self.it.checkpoint();
            const maybe_container = blk: {
                switch (top_container.variant) {
                    .root, .bullet_list, .ordered_list => {
                        break :blk try top_container.openChildContainer(
                            scratch,
                            self.it,
                            self.leaf_parser.?.in_paragraph,
                            self.line_num,
                        );
                    },
                    .blockquote => |payload| {
                        // We can rely on there being at least the root
                        // container and the blockquote container.
                        std.debug.assert(self.container_stack.items.len >= 2);

                        if (payload.soft_closed) {
                            // parent container
                            const base_container = &self.container_stack.items[
                                self.container_stack.items.len - 2
                            ];
                            break :blk try base_container.openChildContainer(
                                scratch,
                                self.it,
                                false,
                                self.line_num,
                            );
                        } else {
                            break :blk try top_container.openChildContainer(
                                scratch,
                                self.it,
                                self.leaf_parser.?.in_paragraph,
                                self.line_num,
                            );
                        }
                    },
                    inline .bullet_list_item, .ordered_list_item => |payload| {
                        // We can rely on there being at least the root
                        // container, the list container, and the list item
                        // container.
                        std.debug.assert(self.container_stack.items.len >= 3);

                        if (payload.soft_closed) {
                            // parent container (list)
                            var base_container = &self.container_stack.items[
                                self.container_stack.items.len - 2
                            ];
                            if (try base_container.openChildContainer(
                                scratch,
                                self.it,
                                false,
                                self.line_num,
                            )) |container| {
                                break :blk container;
                            }

                            // grandparent container
                            base_container = &self.container_stack.items[
                                self.container_stack.items.len - 3
                            ];
                            break :blk try base_container.openChildContainer(
                                scratch,
                                self.it,
                                false,
                                self.line_num,
                            );
                        } else {
                            break :blk try top_container.openChildContainer(
                                scratch,
                                self.it,
                                self.leaf_parser.?.in_paragraph,
                                self.line_num,
                            );
                        }
                    },
                }
            };

            if (maybe_container) |container| {
                switch (top_container.variant) {
                    .root, .bullet_list, .ordered_list => {},
                    inline .blockquote,
                    .bullet_list_item,
                    .ordered_list_item,
                    => |payload| {
                        if (payload.soft_closed) {
                            // Time to hard-close this container. We found
                            // another container that can be opened.
                            self.it.backtrack(checkpoint_index);
                            return null;
                        }
                    },
                }

                try self.push(scratch, container);

                // Pushing a new container onto the stack should coincide with
                // ending the token stream for the current top container.
                return null;
            }

            // Record a blank line if this is one
            if (try peekBlankLine(scratch, self.it)) {
                self.top().recordBlankLine(self.line_num);
            }
        }
    }

    const next_token = try self.it.peek(scratch) orelse return null;
    if (next_token.token_type == .newline) {
        // End of the current line! Reset everything.
        self.unestablished_container_i = 0;
        self.can_open_containers = true;

        for (0..self.container_stack.items.len) |i| {
            const container = &self.container_stack.items[i];
            switch (container.variant) {
                .root, .bullet_list, .ordered_list => {},
                inline else => |*payload| {
                    payload.soft_closed = false;
                },
            }
        }

        _ = try self.it.consume(scratch, &.{.newline});
        self.line_num += 1;
        return next_token;
    }

    if (self.top().isList()) {
        // If we get to this point, we have a list container at the top of our
        // stack but no list items to add to it. Pop it off.
        return null;
    }

    // We've established all our containers and handled whether to open any new
    // ones. We're now looking at tokens that should get passed to the leaf
    // block parser.
    self.can_open_containers = false;

    _ = try self.it.consume(scratch, &.{next_token.token_type});
    return next_token;
}

/// Returns pointer to last container in stack.
///
/// Be careful holding on to this pointer. Could be invalidated by the stack
/// growing or shrinking.
///
/// TODO: Maybe the ArrayList should hold pointers to the containers and not
/// the containers themselves.
fn top(self: *Self) *ContainerBlock {
    std.debug.assert(self.container_stack.items.len > 0);
    return &self.container_stack.items[
        self.container_stack.items.len - 1
    ];
}

fn push(self: *Self, scratch: Allocator, container: ContainerBlock) !void {
    try self.container_stack.append(scratch, container);
    self.unestablished_container_i += 1;
}

fn pop(self: *Self, alloc: Allocator, scratch: Allocator) !void {
    const popped = self.container_stack.pop() orelse unreachable;

    const top_container = self.top();
    switch (top_container.variant) {
        inline .bullet_list, .ordered_list => {
            switch (popped.variant) {
                inline .bullet_list_item, .ordered_list_item => |item| {
                    if (item.last_blank_line_num) |i| {
                        if (i >= self.line_num - 1) {
                            top_container.recordBlankLine(i);
                        }
                    }
                },
                else => unreachable,
            }
        },
        inline .bullet_list_item, .ordered_list_item => {
            switch (popped.variant) {
                inline .bullet_list, .ordered_list => |list| {
                    if (list.last_blank_line_num) |i| {
                        if (i >= self.line_num - 1) {
                            top_container.recordBlankLine(i);
                        }
                    }
                },
                else => {},
            }
        },
        else => {},
    }

    const node = try popped.toNode(alloc, self.line_num);
    errdefer node.deinit(alloc);
    try top_container.addChild(scratch, node);
}

fn parseBlockquoteOpen(
    scratch: Allocator,
    it: *TokenIterator(BlockTokenType),
    line_num: usize,
) !?ContainerBlock {
    const checkpoint_index = it.checkpoint();
    var did_parse = false;
    defer if (!did_parse) {
        it.backtrack(checkpoint_index);
    };

    // Up to 3 leading spaces allowed before '>'
    _ = try it.consumeWhitespaceUpTo(scratch, 3);
    _ = try it.consume(scratch, &.{.r_angle_bracket}) orelse return null;

    _ = try it.consumeWhitespaceUpTo(scratch, 1);

    did_parse = true;
    return .{
        .variant = .{
            .blockquote = .{},
        },
        .start_line_num = line_num,
    };
}

fn parseBulletListOpen(
    scratch: Allocator,
    it: *TokenIterator(BlockTokenType),
    in_paragraph: bool,
    line_num: usize,
) !?ContainerBlock {
    const checkpoint_index = it.checkpoint();
    defer it.backtrack(checkpoint_index); // always backtrack

    // Up to 3 leading spaces allowed before marker token
    _ = try it.consumeWhitespaceUpTo(scratch, 3);

    const marker_token = try it.consume(scratch, &.{
        .star,
        .hyphen,
        .plus,
    }) orelse return null;

    // Must be followed by at least one space or a newline
    const blank_token = try it.consume(scratch, &.{
        .tab,
        .space,
        .newline,
    }) orelse return null;

    const starts_with_blank_line = blk: {
        // blank line could be either
        // 1. an immediate newline
        if (blank_token.token_type == .newline) {
            break :blk true;
        }

        // 2. whitespace followed by a newline
        _ = try it.consumeWhitespace(scratch);
        if (try it.consume(scratch, &.{.newline})) |_| {
            break :blk true;
        }

        break :blk false;
    };

    if (in_paragraph and starts_with_blank_line) {
        // Can't interrupt a paragraph if the list starts with a blank line
        return null;
    }

    return .{
        .variant = .{
            .bullet_list = .{
                .marker_token_type = marker_token.token_type,
            },
        },
        .start_line_num = line_num,
    };
}

fn parseBulletListItemOpen(
    scratch: Allocator,
    it: *TokenIterator(BlockTokenType),
    marker_token_type: BlockTokenType,
    line_num: usize,
) !?ContainerBlock {
    std.debug.assert(marker_token_type == .star or
        marker_token_type == .hyphen or
        marker_token_type == .plus);

    const checkpoint_index = it.checkpoint();
    var did_parse = false;
    defer if (!did_parse) {
        it.backtrack(checkpoint_index);
    };

    // Up to 3 leading spaces allowed before marker token
    const leading_ws_tokens = try it.consumeWhitespaceUpTo(scratch, 3);

    _ = try it.consume(scratch, &.{marker_token_type}) orelse return null;

    // Handle whitespace following marker token.
    //
    // We must have one following whitespace. After that, if we have up to 3
    // spaces, those should be consumed and counted toward the indent for this
    // list item. If we have more than 3, then the spaces should NOT be
    // consumed as they mark an indented code block.
    //
    // If the marker token is followed by a blank line, that's okay
    // too. We treat it as if we had just a single space.
    const space_tokens = try it.consumeWhitespaceUpTo(scratch, 1);
    if (whitespaceLen(space_tokens) < 1) {
        const next_token = try it.peek(scratch) orelse return null;
        if (next_token.token_type != .newline) {
            return null;
        }
    }

    const following_ws_checkpoint_index = it.checkpoint();
    var following_ws_tokens = try it.consumeWhitespace(scratch);
    if (whitespaceLen(following_ws_tokens) > 3) {
        it.backtrack(following_ws_checkpoint_index);
        following_ws_tokens = &.{};
    }

    var starts_with_blank_line = false;
    const indent = blk: {
        const next_token = try it.peek(scratch) orelse return null;
        if (next_token.token_type == .newline) {
            starts_with_blank_line = true;
            break :blk whitespaceLen(leading_ws_tokens) + 2;
        }

        break :blk whitespaceLen(leading_ws_tokens) + 2 +
            whitespaceLen(following_ws_tokens);
    };

    did_parse = true;
    return .{
        .variant = .{
            .bullet_list_item = .{
                .indent = indent,
                .starts_with_blank_line = starts_with_blank_line,
            },
        },
        .start_line_num = line_num,
    };
}

fn parseOrderedListOpen(
    scratch: Allocator,
    it: *TokenIterator(BlockTokenType),
    in_paragraph: bool,
    line_num: usize,
) !?ContainerBlock {
    const checkpoint_index = it.checkpoint();
    defer it.backtrack(checkpoint_index); // always backtrack

    // Up to 3 leading spaces allowed before marker token
    _ = try it.consumeWhitespaceUpTo(scratch, 3);

    const numeral_token = try it.consume(scratch, &.{.text}) orelse
        return null;
    const marker_token = try it.consume(scratch, &.{
        .period,
        .r_paren,
    }) orelse return null;

    // Must be followed by at least one space or newline
    const blank_token = try it.consume(scratch, &.{
        .tab,
        .space,
        .newline,
    }) orelse return null;

    const starts_with_blank_line = blk: {
        // blank line could be either
        // 1. an immediate newline
        if (blank_token.token_type == .newline) {
            break :blk true;
        }

        // 2. whitespace followed by a newline
        _ = try it.consumeWhitespace(scratch);
        if (try it.consume(scratch, &.{.newline})) |_| {
            break :blk true;
        }

        break :blk false;
    };

    const start = cmark.parseOrderedListNumber(numeral_token.lexeme) catch
        return null;

    if (in_paragraph and (starts_with_blank_line or start > 1)) {
        // Can't interrupt a paragraph if the list starts with a blank line
        // Can't interrupt a paragraph if the start number is not 1
        return null;
    }

    return .{
        .variant = .{
            .ordered_list = .{
                .marker_token_type = marker_token.token_type,
                .start = start,
            },
        },
        .start_line_num = line_num,
    };
}

fn parseOrderedListItemOpen(
    scratch: Allocator,
    it: *TokenIterator(BlockTokenType),
    marker_token_type: BlockTokenType,
    line_num: usize,
) !?ContainerBlock {
    std.debug.assert(marker_token_type == .period or
        marker_token_type == .r_paren);

    const checkpoint_index = it.checkpoint();
    var did_parse = false;
    defer if (!did_parse) {
        it.backtrack(checkpoint_index);
    };

    // Up to 3 leading spaces allowed before numeral token
    const leading_ws_tokens = try it.consumeWhitespaceUpTo(scratch, 3);

    const numeral_token = try it.consume(scratch, &.{.text}) orelse
        return null;
    _ = try it.consume(scratch, &.{marker_token_type}) orelse return null;

    // Handle whitespace following marker token.
    //
    // We must have one following whitespace. After that, if we have up to 3
    // spaces, those should be consumed and counted toward the indent for this
    // list item. If we have more than 3, then the spaces should NOT be
    // consumed as they mark an indented code block.
    //
    // If the marker token is followed by a blank line, that's okay
    // too. We treat it as if we had just a single space.
    const space_tokens = try it.consumeWhitespaceUpTo(scratch, 1);
    if (whitespaceLen(space_tokens) < 1) {
        const next_token = try it.peek(scratch) orelse return null;
        if (next_token.token_type != .newline) {
            return null;
        }
    }

    const following_ws_checkpoint_index = it.checkpoint();
    var following_ws_tokens = try it.consumeWhitespace(scratch);
    if (whitespaceLen(following_ws_tokens) > 3) {
        it.backtrack(following_ws_checkpoint_index);
        following_ws_tokens = &.{};
    }

    _ = cmark.parseOrderedListNumber(numeral_token.lexeme) catch return null;

    var starts_with_blank_line = false;
    const numeral_len: u32 = @intCast(numeral_token.lexeme.len);
    const indent = blk: {
        const next_token = try it.peek(scratch) orelse return null;
        if (next_token.token_type == .newline) {
            starts_with_blank_line = true;
            break :blk whitespaceLen(leading_ws_tokens) + numeral_len + 2;
        }

        break :blk whitespaceLen(leading_ws_tokens) + numeral_len + 2 +
            whitespaceLen(following_ws_tokens);
    };

    did_parse = true;
    return .{
        .variant = .{
            .ordered_list_item = .{
                .indent = indent,
                .starts_with_blank_line = starts_with_blank_line,
            },
        },
        .start_line_num = line_num,
    };
}

fn parseAnyContainerOpen(
    scratch: Allocator,
    it: *TokenIterator(BlockTokenType),
    in_paragraph: bool,
    line_num: usize,
) !?ContainerBlock {
    if (try parseBlockquoteOpen(scratch, it, line_num)) |container| {
        return container;
    }

    if (try parseBulletListOpen(
        scratch,
        it,
        in_paragraph,
        line_num,
    )) |container| {
        return container;
    }

    if (try parseOrderedListOpen(
        scratch,
        it,
        in_paragraph,
        line_num,
    )) |container| {
        return container;
    }

    return null;
}

fn peekThematicBreak(
    scratch: Allocator,
    it: *TokenIterator(BlockTokenType),
) !bool {
    const checkpoint_index = it.checkpoint();
    defer it.backtrack(checkpoint_index); // always backtrack

    _ = try it.consumeWhitespaceUpTo(scratch, 3);

    const start_token = try it.peek(scratch) orelse return false;
    if (start_token.token_type == .rule_underline) {
        _ = try it.consume(scratch, &.{.rule_underline});
        _ = try it.consumeWhitespace(scratch);
        _ = try it.consume(scratch, &.{.newline}) orelse return false;
    } else {
        var count: u8 = 0;
        while (try it.peek(scratch)) |token| {
            switch (token.token_type) {
                .hyphen, .star => |t| {
                    if (t != start_token.token_type) {
                        return false;
                    }

                    count += 1;
                    _ = try it.consume(scratch, &.{t});
                },
                .space, .tab => |t| {
                    _ = try it.consume(scratch, &.{t});
                },
                .newline => break,
                else => return false,
            }
        }

        if (count < 3) {
            return false;
        }
        _ = try it.consume(scratch, &.{.newline}) orelse return false;
    }

    return true;
}

fn peekBlankLine(
    scratch: Allocator,
    it: *TokenIterator(BlockTokenType),
) !bool {
    const checkpoint_index = it.checkpoint();
    defer it.backtrack(checkpoint_index); // always backtrack

    _ = try it.consumeWhitespace(scratch);
    return (try it.consume(scratch, &.{.newline})) != null;
}

fn isSpreadListItem(has_interior_blank_line: bool) bool {
    return has_interior_blank_line;
}

fn isSpreadList(
    list_items: []const *ast.Node,
    has_interior_blank_line: bool,
) bool {
    if (has_interior_blank_line) {
        return true;
    }

    for (list_items) |child| {
        if (child.list_item.spread) {
            return true;
        }
    }

    return false;
}

/// For tight lists, we want to make sure paragraphs are unwrapped.
fn unwrapParagraphs(alloc: Allocator, item: *ast.Node) !void {
    var i = item.list_item.children.len;
    while (i > 0) {
        i -= 1;

        const child = item.list_item.children[i];
        if (@as(ast.NodeType, child.*) == .paragraph) {
            // Here we replace the existing list item's children with a new
            // slice made up of the item's other children and the paragraph's
            // children.
            defer alloc.destroy(child);
            defer alloc.free(child.paragraph.children);

            var new_children = try alloc.alloc(
                *ast.Node,
                item.list_item.children.len - 1 + child.paragraph.children.len,
            );
            @memcpy(new_children[0..i], item.list_item.children[0..i]);
            @memcpy(
                new_children[i .. i + child.paragraph.children.len],
                child.paragraph.children,
            );
            @memcpy(
                new_children[i + child.paragraph.children.len ..],
                item.list_item.children[i + 1 ..],
            );

            alloc.free(item.list_item.children);
            item.list_item.children = new_children;
        }
    }
}

/// The MyST 0.0.5 spec tests seem to expect all list items to have spread set
/// to true and all lists to have spread set to false.
///
/// This doesn't make much sense and seems likely to change in subsequent
/// versions of the spec, so we ensure compliance here with a little post-hoc
/// transformation.
fn overrideSpread(node: *ast.Node) void {
    switch (node.allowedChildren()) {
        .yes => |branch_node| {
            switch (branch_node) {
                .list => |n| {
                    n.spread = false;
                    for (n.children) |child| {
                        overrideSpread(child);
                    }
                },
                .list_item => |n| {
                    n.spread = true;
                    for (n.children) |child| {
                        overrideSpread(child);
                    }
                },
                inline else => |n| {
                    for (n.children) |child| {
                        overrideSpread(child);
                    }
                },
            }
        },
        .no => {},
    }
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;
const LineReader = @import("../lex/LineReader.zig");
const BlockTokenizer = @import("../lex/BlockTokenizer.zig");

fn parseBlocks(md: []const u8) !*ast.Node {
    var reader: Io.Reader = .fixed(md);
    var line_buf: [512]u8 = undefined;
    const line_reader: LineReader = .{ .in = &reader, .buf = &line_buf };
    var tokenizer = BlockTokenizer.init(line_reader);
    var it = tokenizer.iterator();
    var parser = Self.init(&it, .{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(testing.allocator);

    const root = try parser.parse(testing.allocator, scratch, &link_defs);
    return root;
}

test "empty document" {
    const md = "";

    const root = try parseBlocks(md);
    defer root.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try testing.expectEqual(0, root.root.children.len);
}

test "simple paragraph" {
    const md =
        \\This is a paragraph. It goes on for
        \\multiple lines.
        \\
    ;

    const root = try parseBlocks(md);
    defer root.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try testing.expectEqual(1, root.root.children.len);

    const p = root.root.children[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));

    const txt = p.paragraph.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, txt.*));
    try testing.expectEqualStrings(
        "This is a paragraph. It goes on for\nmultiple lines.",
        txt.text.value,
    );
}

test "blockquote" {
    const md =
        \\>This is a block-quoted paragraph. It goes on for
        \\>multiple lines.
        \\
        \\This is a regular paragraph. It goes on for
        \\multiple lines.
        \\
    ;

    const root = try parseBlocks(md);
    defer root.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try testing.expectEqual(2, root.root.children.len);

    const bq = root.root.children[0];
    try testing.expectEqual(.blockquote, @as(ast.NodeType, bq.*));
    try testing.expectEqual(1, bq.blockquote.children.len);
    {
        const p = bq.blockquote.children[0];
        try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));
        try testing.expectEqual(1, p.paragraph.children.len);

        const txt = p.paragraph.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, txt.*));
        try testing.expectEqualStrings(
            "This is a block-quoted paragraph. It goes on for\nmultiple lines.",
            txt.text.value,
        );
    }

    const p = root.root.children[1];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));
}

test "blockquote lazy continuation" {
    const md =
        \\>This should
        \\run on
        \\for multiple lines.
        \\
        \\>foo
        \\# bar
        \\
        \\> foo
        \\bar
        \\> bam
        \\
        \\> foo
        \\bar
        \\> # bam
        \\
    ;

    const root = try parseBlocks(md);
    defer root.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try testing.expectEqual(5, root.root.children.len);

    const bq1 = root.root.children[0];
    try testing.expectEqual(.blockquote, @as(ast.NodeType, bq1.*));
    try testing.expectEqual(1, bq1.blockquote.children.len);
    {
        const p = bq1.blockquote.children[0];
        try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));
        try testing.expectEqual(1, p.paragraph.children.len);

        const txt = p.paragraph.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, txt.*));
        try testing.expectEqualStrings(
            "This should\nrun on\nfor multiple lines.",
            txt.text.value,
        );
    }

    const bq2 = root.root.children[1];
    try testing.expectEqual(.blockquote, @as(ast.NodeType, bq2.*));

    const h = root.root.children[2];
    try testing.expectEqual(.heading, @as(ast.NodeType, h.*));

    const bq3 = root.root.children[3];
    try testing.expectEqual(.blockquote, @as(ast.NodeType, bq3.*));
    try testing.expectEqual(1, bq3.blockquote.children.len);
    {
        const p = bq3.blockquote.children[0];
        try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));
        try testing.expectEqual(1, p.paragraph.children.len);

        const txt = p.paragraph.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, txt.*));
        try testing.expectEqualStrings(
            "foo\nbar\nbam",
            txt.text.value,
        );
    }

    const bq4 = root.root.children[4];
    try testing.expectEqual(.blockquote, @as(ast.NodeType, bq4.*));
    try testing.expectEqual(2, bq4.blockquote.children.len);
    {
        const p = bq4.blockquote.children[0];
        try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));
        try testing.expectEqual(1, p.paragraph.children.len);

        const txt = p.paragraph.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, txt.*));
        try testing.expectEqualStrings(
            "foo\nbar",
            txt.text.value,
        );

        const bq4_h = bq4.blockquote.children[1];
        try testing.expectEqual(.heading, @as(ast.NodeType, bq4_h.*));
    }
}

test "blockquote after paragraph" {
    const md =
        \\This is a paragraph outside the blockquote.
        \\>This is a paragraph inside the blockquote.
        \\
    ;

    const root = try parseBlocks(md);
    defer root.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try testing.expectEqual(2, root.root.children.len);

    const p = root.root.children[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));

    const bq = root.root.children[1];
    try testing.expectEqual(.blockquote, @as(ast.NodeType, bq.*));
    try testing.expectEqual(1, bq.blockquote.children.len);
    {
        const bq_p = bq.blockquote.children[0];
        try testing.expectEqual(.paragraph, @as(ast.NodeType, bq_p.*));

        const bq_txt = bq_p.paragraph.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, bq_txt.*));
        try testing.expectEqualStrings(
            "This is a paragraph inside the blockquote.",
            bq_txt.text.value,
        );
    }
}

test "whitespace blockquote" {
    const md =
        \\> This is a paragraph inside the blockquote.
        \\>So is this line.
        \\ > And this line.
        \\
    ;

    const root = try parseBlocks(md);
    defer root.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try testing.expectEqual(1, root.root.children.len);

    const bq = root.root.children[0];
    try testing.expectEqual(.blockquote, @as(ast.NodeType, bq.*));
    try testing.expectEqual(1, bq.blockquote.children.len);
    {
        const bq_p = bq.blockquote.children[0];
        try testing.expectEqual(.paragraph, @as(ast.NodeType, bq_p.*));

        const bq_txt = bq_p.paragraph.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, bq_txt.*));
        try testing.expectEqualStrings(
            \\This is a paragraph inside the blockquote.
            \\So is this line.
            \\And this line.
        ,
            bq_txt.text.value,
        );
    }
}

test "blockquote with tab indent" {
    //>foo
    //
    //>\tfoo
    //
    //>\t foo
    //
    //>\t    foo
    //
    //>\t\tfoo
    const md = ">foo\n\n>\tfoo\n\n>\t foo\n\n>\t    foo\n\n>\t\tfoo\n";

    const root = try parseBlocks(md);
    defer root.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try testing.expectEqual(5, root.root.children.len);

    // First three should parse as paragraphs
    for (0..3) |i| {
        const bq_node = root.root.children[i];
        try testing.expectEqual(.blockquote, @as(ast.NodeType, bq_node.*));
        try testing.expectEqual(1, bq_node.blockquote.children.len);

        const p_node = bq_node.blockquote.children[0];
        try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));
    }

    // Last two should parse as indented code
    for (3..5) |i| {
        const bq_node = root.root.children[i];
        try testing.expectEqual(.blockquote, @as(ast.NodeType, bq_node.*));
        try testing.expectEqual(1, bq_node.blockquote.children.len);

        const code_node = bq_node.blockquote.children[0];
        try testing.expectEqual(.code, @as(ast.NodeType, code_node.*));
        try testing.expectEqualStrings("  foo", code_node.code.value);
    }
}

test "blockquote with nested blocks" {
    const md =
        \\># Heading
        \\>Paragraph text.
        \\>```python
        \\>def foo():
        \\>    pass
        \\>```
        \\
    ;

    const root = try parseBlocks(md);
    defer root.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try testing.expectEqual(1, root.root.children.len);

    const bq = root.root.children[0];
    try testing.expectEqual(.blockquote, @as(ast.NodeType, bq.*));
    try testing.expectEqual(3, bq.blockquote.children.len);
    {
        const bq_h = bq.blockquote.children[0];
        try testing.expectEqual(.heading, @as(ast.NodeType, bq_h.*));

        const h_txt = bq_h.heading.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, h_txt.*));
        try testing.expectEqualStrings(
            "Heading",
            h_txt.text.value,
        );

        const bq_p = bq.blockquote.children[1];
        try testing.expectEqual(.paragraph, @as(ast.NodeType, bq_p.*));

        const p_txt = bq_p.paragraph.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, p_txt.*));
        try testing.expectEqualStrings(
            "Paragraph text.",
            p_txt.text.value,
        );

        const bq_code = bq.blockquote.children[2];
        try testing.expectEqual(.code, @as(ast.NodeType, bq_code.*));
    }
}

test "double blockquote" {
    const md =
        \\This is a paragraph.
        \\
        \\> This is blockquoted.
        \\> > This is double-blockquoted.
        \\> Still double-blockquoted (lazy).
        \\>
        \\> This is single blockquoted again.
        \\
        \\This is another regular paragraph.
        \\
    ;

    const root = try parseBlocks(md);
    defer root.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try testing.expectEqual(3, root.root.children.len);

    {
        const p = root.root.children[0];
        try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));
        const p_txt = p.paragraph.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, p_txt.*));
        try testing.expectEqualStrings(
            "This is a paragraph.",
            p_txt.text.value,
        );
    }

    const bq_outer = root.root.children[1];
    try testing.expectEqual(.blockquote, @as(ast.NodeType, bq_outer.*));
    try testing.expectEqual(3, bq_outer.blockquote.children.len);
    {
        const p1 = bq_outer.blockquote.children[0];
        try testing.expectEqual(.paragraph, @as(ast.NodeType, p1.*));
        try testing.expectEqual(1, p1.paragraph.children.len);
        const p1_txt = p1.paragraph.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, p1_txt.*));
        try testing.expectEqualStrings(
            "This is blockquoted.",
            p1_txt.text.value,
        );

        const bq_inner = bq_outer.blockquote.children[1];
        try testing.expectEqual(.blockquote, @as(ast.NodeType, bq_inner.*));
        try testing.expectEqual(1, bq_inner.blockquote.children.len);
        const bq_inner_p = bq_inner.blockquote.children[0];
        try testing.expectEqual(.paragraph, @as(ast.NodeType, bq_inner_p.*));
        try testing.expectEqual(1, bq_inner_p.paragraph.children.len);
        const bq_inner_p_txt = bq_inner_p.paragraph.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, bq_inner_p_txt.*));
        try testing.expectEqualStrings(
            "This is double-blockquoted.\nStill double-blockquoted (lazy).",
            bq_inner_p_txt.text.value,
        );

        const p2 = bq_outer.blockquote.children[2];
        try testing.expectEqual(.paragraph, @as(ast.NodeType, p2.*));
        try testing.expectEqual(1, p2.paragraph.children.len);
        const p2_txt = p2.paragraph.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, p2_txt.*));
        try testing.expectEqualStrings(
            "This is single blockquoted again.",
            p2_txt.text.value,
        );
    }

    {
        const p = root.root.children[2];
        try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));
        const p_txt = p.paragraph.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, p_txt.*));
        try testing.expectEqualStrings(
            "This is another regular paragraph.",
            p_txt.text.value,
        );
    }
}

test "angle brackets in fenced code block" {
    const md =
        \\```md
        \\> foo
        \\```
        \\
    ;

    const root = try parseBlocks(md);
    defer root.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try testing.expectEqual(1, root.root.children.len);

    const code = root.root.children[0];
    try testing.expectEqual(.code, @as(ast.NodeType, code.*));
    try testing.expectEqualStrings(
        "> foo",
        code.code.value,
    );
}

test "simple bullet list" {
    const md =
        \\* First
        \\* Second
        \\* Third
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
    try testing.expectEqual(1, root_node.root.children.len);

    const list_node = root_node.root.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
    try testing.expectEqual(false, list_node.list.ordered);
    try testing.expectEqual(false, list_node.list.spread);
    try testing.expectEqual(3, list_node.list.children.len);

    for (0..3) |i| {
        const list_item_node = list_node.list.children[i];
        try testing.expectEqual(
            .list_item,
            @as(ast.NodeType, list_item_node.*),
        );
        try testing.expectEqual(false, list_item_node.list_item.spread);
        try testing.expectEqual(1, list_item_node.list_item.children.len);

        const txt_node = list_item_node.list_item.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, txt_node.*));
    }
}

test "bullet list markers" {
    const md =
        \\+ First
        \\+ Second
        \\- First
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
    try testing.expectEqual(2, root_node.root.children.len);

    const list_node_1 = root_node.root.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node_1.*));
    try testing.expectEqual(false, list_node_1.list.ordered);
    try testing.expectEqual(false, list_node_1.list.spread);
    try testing.expectEqual(2, list_node_1.list.children.len);

    const list_node_2 = root_node.root.children[1];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node_2.*));
    try testing.expectEqual(false, list_node_2.list.ordered);
    try testing.expectEqual(false, list_node_2.list.spread);
    try testing.expectEqual(1, list_node_2.list.children.len);
}

test "bullet list spread item" {
    const md =
        \\* This contains a blank line.
        \\
        \\  Blank line above.
        \\* Second
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
    try testing.expectEqual(1, root_node.root.children.len);

    const list_node = root_node.root.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
    try testing.expectEqual(false, list_node.list.ordered);
    try testing.expectEqual(true, list_node.list.spread);
    try testing.expectEqual(2, list_node.list.children.len);

    const list_item_node_1 = list_node.list.children[0];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_1.*));
    try testing.expectEqual(true, list_item_node_1.list_item.spread);
    try testing.expectEqual(2, list_item_node_1.list_item.children.len);

    const list_item_node_2 = list_node.list.children[1];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_2.*));
    try testing.expectEqual(false, list_item_node_2.list_item.spread);
    try testing.expectEqual(1, list_item_node_2.list_item.children.len);

    const p_node_2 = list_item_node_2.list_item.children[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node_2.*));
    try testing.expectEqual(1, p_node_2.paragraph.children.len);
    const txt_node_2 = p_node_2.paragraph.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, txt_node_2.*));
    try testing.expectEqualStrings("Second", txt_node_2.text.value);
}

test "bullet list spread list" {
    const md =
        \\* First
        \\
        \\* Second
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
    try testing.expectEqual(1, root_node.root.children.len);

    const list_node = root_node.root.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
    try testing.expectEqual(false, list_node.list.ordered);
    try testing.expectEqual(true, list_node.list.spread);
    try testing.expectEqual(2, list_node.list.children.len);

    const list_item_node_1 = list_node.list.children[0];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_1.*));
    try testing.expectEqual(false, list_item_node_1.list_item.spread);
    try testing.expectEqual(1, list_item_node_1.list_item.children.len);

    const p_node_1 = list_item_node_1.list_item.children[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node_1.*));
    try testing.expectEqual(1, p_node_1.paragraph.children.len);
    const txt_node_1 = p_node_1.paragraph.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, txt_node_1.*));
    try testing.expectEqualStrings("First", txt_node_1.text.value);

    const list_item_node_2 = list_node.list.children[1];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_2.*));
    try testing.expectEqual(false, list_item_node_2.list_item.spread);

    const p_node_2 = list_item_node_2.list_item.children[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node_2.*));
    try testing.expectEqual(1, p_node_2.paragraph.children.len);
    const txt_node_2 = p_node_2.paragraph.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, txt_node_2.*));
    try testing.expectEqualStrings("Second", txt_node_2.text.value);
}

// This list should be tight. The trailing blank lines are after the list.
test "bullet list trailing blank lines" {
    const md =
        \\* First
        \\* Second
        \\
        \\This is a paragraph.
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
    try testing.expectEqual(2, root_node.root.children.len);

    const list_node = root_node.root.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
    try testing.expectEqual(false, list_node.list.spread);
    try testing.expectEqual(2, list_node.list.children.len);

    {
        const child = list_node.list.children[0];
        try testing.expectEqual(.list_item, @as(ast.NodeType, child.*));
        try testing.expectEqual(false, child.list_item.spread);
        try testing.expectEqual(1, child.list_item.children.len);

        const txt_node = child.list_item.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, txt_node.*));
    }

    {
        const child = list_node.list.children[1];
        try testing.expectEqual(.list_item, @as(ast.NodeType, child.*));
        try testing.expectEqual(false, child.list_item.spread);
        try testing.expectEqual(1, child.list_item.children.len);

        const txt_node = child.list_item.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, txt_node.*));
    }
}

test "bullet list match indent" {
    const md =
        \\*    First
        \\
        \\     Still first!
        \\
        \\  No longer in list.
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
    try testing.expectEqual(2, root_node.root.children.len);

    const list_node = root_node.root.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
    try testing.expectEqual(false, list_node.list.ordered);
    try testing.expectEqual(true, list_node.list.spread);
    try testing.expectEqual(1, list_node.list.children.len);

    const list_item_node = list_node.list.children[0];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node.*));
    try testing.expectEqual(true, list_item_node.list_item.spread);
    try testing.expectEqual(2, list_item_node.list_item.children.len);

    const item_p_node_1 = list_item_node.list_item.children[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, item_p_node_1.*));
    try testing.expectEqualStrings(
        "First",
        item_p_node_1.paragraph.children[0].text.value,
    );

    const item_p_node_2 = list_item_node.list_item.children[1];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, item_p_node_2.*));
    try testing.expectEqualStrings(
        "Still first!",
        item_p_node_2.paragraph.children[0].text.value,
    );

    const p_node = root_node.root.children[1];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));
}

test "indented bullet list items" {
    const md =
        \\   * foo
        \\  * foo
        \\* foo
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));

    const list_node = root_node.root.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
    try testing.expectEqual(3, list_node.list.children.len);

    for (0..3) |i| {
        const item_node = list_node.list.children[i];
        try testing.expectEqual(.list_item, @as(ast.NodeType, item_node.*));
        try testing.expectEqual(1, item_node.list_item.children.len);

        const txt_node = item_node.list_item.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, txt_node.*));
        try testing.expectEqualStrings("foo", txt_node.text.value);
    }
}

test "not a thematic break" {
    const md =
        \\- * * * a
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));

    // -
    const l1 = root_node.root.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, l1.*));
    try testing.expectEqual(1, l1.list.children.len);

    const li1 = l1.list.children[0];
    try testing.expectEqual(.list_item, @as(ast.NodeType, li1.*));
    try testing.expectEqual(1, li1.list_item.children.len);

    // *
    const l2 = li1.list_item.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, l2.*));
    try testing.expectEqual(1, l2.list.children.len);

    const li2 = l2.list.children[0];
    try testing.expectEqual(.list_item, @as(ast.NodeType, li2.*));
    try testing.expectEqual(1, li2.list_item.children.len);

    // *
    const l3 = li2.list_item.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, l3.*));
    try testing.expectEqual(1, l3.list.children.len);

    const li3 = l3.list.children[0];
    try testing.expectEqual(.list_item, @as(ast.NodeType, li3.*));
    try testing.expectEqual(1, li3.list_item.children.len);

    // *
    const l4 = li3.list_item.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, l4.*));
    try testing.expectEqual(1, l4.list.children.len);

    const li4 = l4.list.children[0];
    try testing.expectEqual(.list_item, @as(ast.NodeType, li4.*));
    try testing.expectEqual(1, li4.list_item.children.len);

    // a
    const text = li4.list_item.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, text.*));
    try testing.expectEqualStrings("a", text.text.value);
}

test "interleave blockquote and bullet list" {
    const md =
        \\> * The following is the first nested blockquote:
        \\>
        \\>   > Here it is.
        \\> * > This is the second.
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));

    const bq_node = root_node.root.children[0];
    try testing.expectEqual(.blockquote, @as(ast.NodeType, bq_node.*));
    try testing.expectEqual(1, bq_node.blockquote.children.len);

    const list_node = bq_node.blockquote.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
    try testing.expectEqual(2, list_node.list.children.len);

    {
        const item_node = list_node.list.children[0];
        try testing.expectEqual(.list_item, @as(ast.NodeType, item_node.*));
        try testing.expectEqual(true, item_node.list_item.spread);
        try testing.expectEqual(2, item_node.list_item.children.len);

        const nested_bq_node = item_node.list_item.children[1];
        try testing.expectEqual(.blockquote, @as(
            ast.NodeType,
            nested_bq_node.*,
        ));

        const p_node = nested_bq_node.blockquote.children[0];
        try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));
    }

    {
        const item_node = list_node.list.children[1];
        try testing.expectEqual(.list_item, @as(ast.NodeType, item_node.*));
        try testing.expectEqual(false, item_node.list_item.spread);
        try testing.expectEqual(1, item_node.list_item.children.len);

        const nested_bq_node = item_node.list_item.children[0];
        try testing.expectEqual(.blockquote, @as(
            ast.NodeType,
            nested_bq_node.*,
        ));

        const p_node = nested_bq_node.blockquote.children[0];
        try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));
    }
}

test "simple ordered list" {
    const md =
        \\1. First
        \\2. Second
        \\3. Third
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
    try testing.expectEqual(1, root_node.root.children.len);

    const list_node = root_node.root.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
    try testing.expectEqual(true, list_node.list.ordered);
    try testing.expectEqual(false, list_node.list.spread);
    try testing.expectEqual(3, list_node.list.children.len);
    try testing.expectEqual(1, list_node.list.start);

    for (0..3) |i| {
        const list_item_node = list_node.list.children[i];
        try testing.expectEqual(
            .list_item,
            @as(ast.NodeType, list_item_node.*),
        );
        try testing.expectEqual(false, list_item_node.list_item.spread);
        try testing.expectEqual(1, list_item_node.list_item.children.len);

        const txt_node = list_item_node.list_item.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, txt_node.*));
    }
}

test "ordered list different start" {
    const md =
        \\2. First
        \\3. Second
        \\4. Third
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
    try testing.expectEqual(1, root_node.root.children.len);

    const list_node = root_node.root.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
    try testing.expectEqual(true, list_node.list.ordered);
    try testing.expectEqual(false, list_node.list.spread);
    try testing.expectEqual(3, list_node.list.children.len);
    try testing.expectEqual(2, list_node.list.start);
}

test "ordered list invalid number not at start" {
    const md =
        \\1. First
        \\1234567890. Second
        \\3. Third
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
    try testing.expectEqual(1, root_node.root.children.len);

    const list_node = root_node.root.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
    try testing.expectEqual(true, list_node.list.ordered);
    try testing.expectEqual(false, list_node.list.spread);
    try testing.expectEqual(2, list_node.list.children.len);
    try testing.expectEqual(1, list_node.list.start);

    const list_item_node = list_node.list.children[0];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node.*));
    try testing.expectEqual(false, list_item_node.list_item.spread);
    try testing.expectEqual(1, list_item_node.list_item.children.len);

    const txt_node = list_item_node.list_item.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, txt_node.*));
    try testing.expectEqualStrings(
        "First\n1234567890. Second",
        txt_node.text.value,
    );
}

test "ordered list spread item" {
    const md =
        \\1. This contains a blank line.
        \\
        \\   Blank line above.
        \\2. Second
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
    try testing.expectEqual(1, root_node.root.children.len);

    const list_node = root_node.root.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
    try testing.expectEqual(true, list_node.list.ordered);
    try testing.expectEqual(true, list_node.list.spread);
    try testing.expectEqual(2, list_node.list.children.len);

    const list_item_node_1 = list_node.list.children[0];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_1.*));
    try testing.expectEqual(true, list_item_node_1.list_item.spread);
    try testing.expectEqual(2, list_item_node_1.list_item.children.len);

    const list_item_node_2 = list_node.list.children[1];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_2.*));
    try testing.expectEqual(false, list_item_node_2.list_item.spread);

    const p_node_2 = list_item_node_2.list_item.children[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node_2.*));
    try testing.expectEqual(1, p_node_2.paragraph.children.len);
    const txt_node_2 = p_node_2.paragraph.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, txt_node_2.*));
    try testing.expectEqualStrings("Second", txt_node_2.text.value);
}

test "ordered list spread list" {
    const md =
        \\1. First
        \\
        \\2. Second
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
    try testing.expectEqual(1, root_node.root.children.len);

    const list_node = root_node.root.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
    try testing.expectEqual(true, list_node.list.ordered);
    try testing.expectEqual(true, list_node.list.spread);
    try testing.expectEqual(2, list_node.list.children.len);

    const list_item_node_1 = list_node.list.children[0];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_1.*));
    try testing.expectEqual(false, list_item_node_1.list_item.spread);

    const p_node_1 = list_item_node_1.list_item.children[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node_1.*));
    try testing.expectEqual(1, p_node_1.paragraph.children.len);
    const txt_node_1 = p_node_1.paragraph.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, txt_node_1.*));
    try testing.expectEqualStrings("First", txt_node_1.text.value);

    const list_item_node_2 = list_node.list.children[1];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_2.*));
    try testing.expectEqual(false, list_item_node_2.list_item.spread);

    const p_node_2 = list_item_node_2.list_item.children[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node_2.*));
    try testing.expectEqual(1, p_node_2.paragraph.children.len);
    const txt_node_2 = p_node_2.paragraph.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, txt_node_2.*));
    try testing.expectEqualStrings("Second", txt_node_2.text.value);
}

// This list should be tight. The trailing blank lines are after the list.
test "ordered list trailing blank lines" {
    const md =
        \\1. First
        \\2. Second
        \\
        \\This is a paragraph.
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
    try testing.expectEqual(2, root_node.root.children.len);

    const list_node = root_node.root.children[0];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
    try testing.expectEqual(false, list_node.list.spread);
    try testing.expectEqual(2, list_node.list.children.len);

    {
        const child = list_node.list.children[0];
        try testing.expectEqual(.list_item, @as(ast.NodeType, child.*));
        try testing.expectEqual(false, child.list_item.spread);
        try testing.expectEqual(1, child.list_item.children.len);

        const txt_node = child.list_item.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, txt_node.*));
    }

    {
        const child = list_node.list.children[1];
        try testing.expectEqual(.list_item, @as(ast.NodeType, child.*));
        try testing.expectEqual(false, child.list_item.spread);
        try testing.expectEqual(1, child.list_item.children.len);

        const txt_node = child.list_item.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, txt_node.*));
    }
}

test "paragraph interruption" {
    const md =
        \\Foo
        \\*
        \\
        \\> Foo
        \\*
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
    try testing.expectEqual(3, root_node.root.children.len);

    const p_node = root_node.root.children[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));

    const bq_node = root_node.root.children[1];
    try testing.expectEqual(.blockquote, @as(ast.NodeType, bq_node.*));

    const list_node = root_node.root.children[2];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
    try testing.expectEqual(1, list_node.list.children.len);
    const list_item_node = list_node.list.children[0];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node.*));
    try testing.expectEqual(0, list_item_node.list_item.children.len);
}

test "setext lazy continuation" {
    const md =
        \\Foo
        \\==
        \\
        \\> Bar
        \\==
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
    try testing.expectEqual(2, root_node.root.children.len);

    const h_node = root_node.root.children[0];
    try testing.expectEqual(.heading, @as(ast.NodeType, h_node.*));

    const bq_node = root_node.root.children[1];
    try testing.expectEqual(.blockquote, @as(ast.NodeType, bq_node.*));
    try testing.expectEqual(1, bq_node.blockquote.children.len);

    const p_node = bq_node.blockquote.children[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));
}

test "hyphens after blockquote" {
    // These should parse as:
    // 1. Blockquote followed by empty list item.
    // 2. Blockquote, containing setext underline parsed as regular paragraph
    //    text.
    // 3. Blockquote, followed by a thematic break.
    const md =
        \\> Foo
        \\-
        \\
        \\> Foo
        \\--
        \\
        \\> Foo
        \\---
        \\
    ;

    const root_node = try parseBlocks(md);
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
    try testing.expectEqual(5, root_node.root.children.len);

    const bq1_node = root_node.root.children[0];
    try testing.expectEqual(.blockquote, @as(ast.NodeType, bq1_node.*));
    const list_node = root_node.root.children[1];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));

    const bq2_node = root_node.root.children[2];
    try testing.expectEqual(.blockquote, @as(ast.NodeType, bq2_node.*));

    const bq3_node = root_node.root.children[3];
    try testing.expectEqual(.blockquote, @as(ast.NodeType, bq3_node.*));
    const break_node = root_node.root.children[4];
    try testing.expectEqual(.thematic_break, @as(ast.NodeType, break_node.*));
}

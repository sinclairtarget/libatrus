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
const BlockToken = @import("../lex/tokens.zig").BlockToken;
const BlockTokenType = @import("../lex/tokens.zig").BlockTokenType;
const whitespaceLen = @import("../lex/tokens.zig").whitespaceLen;
const LeafBlockParser = @import("LeafBlockParser.zig");
const LinkDefMap = @import("link_defs.zig").LinkDefMap;
const TokenIterator = @import("../lex/iterator.zig").TokenIterator;
const util = @import("../util/util.zig");

const Error = error{
    LineTooLong,
    ReadFailed,
    WriteFailed,
} || Allocator.Error;

/// Represents a container block that is open (can still have children added to
/// it) and hasn't yet been turned into an AST node.
const ContainerBlock = struct {
    children: ArrayList(*ast.Node) = .empty,
    variant: union(enum) {
        root,
        blockquote: struct {
            soft_closed: bool = false,
        },
        bullet_list: struct {
            marker_token_type: BlockTokenType,
        },
        bullet_list_item: struct {
            indent: u32,
            starts_with_blank_line: bool = false,
            saw_blank_line: bool = false,
            soft_closed: bool = false,
        },
        ordered_list: struct {
            marker_token_type: BlockTokenType,
            start: u32,
        },
        ordered_list_item: struct {
            indent: u32,
            starts_with_blank_line: bool = false,
            saw_blank_line: bool = false,
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
    ) !bool {
        const checkpoint_index = it.checkpoint();
        var did_establish = false;
        defer if (!did_establish) {
            it.backtrack(checkpoint_index);
        };

        did_establish = switch (self.variant) {
            .root, .bullet_list, .ordered_list => true, // always established
            .blockquote => blk: {
                if (try parseBlockquoteOpen(scratch, it)) |_| {
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
                            self.children.items.len == 0)
                        {
                            // List item cannot start with more than one blank
                            // line.
                            break :blk false;
                        }

                        payload.saw_blank_line = true;
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
    ) !?ContainerBlock {
        switch (self.variant) {
            .root, .blockquote, .bullet_list_item, .ordered_list_item => {
                return try parseAnyContainerOpen(scratch, it);
            },
            .bullet_list => |payload| {
                if (try parseBulletListItemOpen(
                    scratch,
                    it,
                    payload.marker_token_type,
                )) |container| {
                    return container;
                }
            },
            .ordered_list => |payload| {
                if (try parseOrderedListItemOpen(
                    scratch,
                    it,
                    payload.marker_token_type,
                )) |container| {
                    return container;
                }
            },
        }

        return null;
    }

    /// Close this container block, turning it into an AST node.
    fn toNode(self: ContainerBlock, alloc: Allocator) !*ast.Node {
        const owned_children = try alloc.dupe(*ast.Node, self.children.items);
        errdefer alloc.free(owned_children);

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
            inline .bullet_list_item, .ordered_list_item => |payload| {
                node.* = .{
                    .list_item = .{
                        .children = owned_children,
                        .spread = payload.saw_blank_line or
                            payload.starts_with_blank_line,
                    },
                };
            },
            .bullet_list => {
                _ = tightenListChildren(alloc, owned_children);
                node.* = .{
                    .list = .{
                        .children = owned_children,
                        .ordered = false,
                        .spread = false, // Always false for MyST 0.0.5 tests
                    },
                };
            },
            .ordered_list => |payload| {
                _ = tightenListChildren(alloc, owned_children);
                node.* = .{
                    .list = .{
                        .children = owned_children,
                        .ordered = true,
                        .spread = false, // Always false for MyST 0.0.5 tests
                        .start = payload.start,
                    },
                };
            },
        }

        return node;
    }
};

// Set to true to print tokens sent to leaf block parser.
const debug_stream = false;

// Iterator that the container block parser consumes
it: *TokenIterator(BlockTokenType),
leaf_parser: ?LeafBlockParser,
container_stack: ArrayList(ContainerBlock),
unestablished_container_i: usize,
can_open_containers: bool,

const Self = @This();

pub fn init(it: *TokenIterator(BlockTokenType)) Self {
    return .{
        .it = it,
        .leaf_parser = null,
        .container_stack = .empty,
        .unestablished_container_i = 0,
        .can_open_containers = true,
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
    });
    self.unestablished_container_i = 0;
    self.can_open_containers = true;

    var leaf_it = self.iterator();
    for (0..util.safety.loop_bound) |_| {
        if (debug_stream) {
            for (self.container_stack.items) |container| {
                std.debug.print("[{s}] ", .{container.name()});
            }
            std.debug.print("\n", .{});
        }

        // Some kind of handling of list containers has to go here. There could
        // be tokens still in the buffer within leaf_it. If we call
        // LeafBlockParser.parse() on this leaf_it, it will consume the token
        // before any of the logic in the iterator func below can run and we'd
        // end up adding leaf block children to a list container, which is
        // invalid.
        if (!self.can_open_containers and self.top().isList()) {
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

    return try self.top().toNode(alloc);
}

/// Iterator for the leaf block parser to consume
fn iterator(self: *Self) TokenIterator(BlockTokenType) {
    return TokenIterator(BlockTokenType).init(self, &nextIterator);
}

/// Called by LeafBlockParser to get next token.
fn nextIterator(ctx: *anyopaque, scratch: Allocator) Error!?BlockToken {
    const self: *Self = @ptrCast(@alignCast(ctx));

    const maybe_token = try self.next(scratch);
    if (debug_stream) {
        if (maybe_token) |token| {
            std.debug.print("{f}\n", .{token});
        } else {
            std.debug.print("NULL\n", .{});
        }
    }

    return maybe_token;
}

fn next(self: *Self, scratch: Allocator) Error!?BlockToken {
    if (self.can_open_containers) {
        // We're at the beginning of the line. We need to establish any stacked
        // containers.
        if (self.unestablished_container_i == 0) {
            for (0..self.container_stack.items.len) |i| {
                const container = &self.container_stack.items[i];
                if (!try container.establish(scratch, self.it)) {
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
                inline else => |*payload| {
                    // Soft close.
                    if (!payload.soft_closed) {
                        payload.soft_closed = true;
                        return .{ .token_type = .close };
                    }
                },
            }
        }

        // We now look for tokens that could open new containers. Pushing a new
        // container should coincide with ending the token stream for the
        // current container.
        if (self.leaf_parser.?.interruptible) {
            const top_container = self.top();
            const maybe_container = try top_container.openChildContainer(
                scratch,
                self.it,
            );

            if (maybe_container) |container| {
                switch (top_container.variant) {
                    .root, .bullet_list, .ordered_list => {},
                    inline else => |payload| {
                        if (payload.soft_closed) {
                            // Time to hard-close this container. We can't be
                            // adding new child containers to already-closed
                            // containers.
                            return null;
                        }
                    },
                }

                try self.push(scratch, container);
                return null;
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
    const node = try popped.toNode(alloc);
    errdefer node.deinit(alloc);
    try self.top().addChild(scratch, node);
}

fn parseBlockquoteOpen(
    scratch: Allocator,
    it: *TokenIterator(BlockTokenType),
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
    };
}

fn parseBulletListOpen(
    scratch: Allocator,
    it: *TokenIterator(BlockTokenType),
) !?ContainerBlock {
    const checkpoint_index = it.checkpoint();
    defer it.backtrack(checkpoint_index); // always backtrack

    // Up to 3 leading spaces allowed before marker token
    _ = try it.consumeWhitespaceUpTo(scratch, 3);

    const marker_token_type = blk: {
        const marker_token = try it.consume(scratch, &.{
            .star,
            .hyphen,
            .plus,
            .rule_dash,
        }) orelse return null;

        if (marker_token.token_type == .rule_dash) {
            if (marker_token.lexeme.len == 1) {
                break :blk .hyphen;
            }

            return null;
        }

        break :blk marker_token.token_type;
    };

    // Must be followed by at least one space or a newline
    _ = try it.consume(scratch, &.{ .tab, .space, .newline }) orelse
        return null;

    return .{
        .variant = .{
            .bullet_list = .{
                .marker_token_type = marker_token_type,
            },
        },
    };
}

fn parseBulletListItemOpen(
    scratch: Allocator,
    it: *TokenIterator(BlockTokenType),
    marker_token_type: BlockTokenType,
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

    _ = try it.consume(scratch, &.{marker_token_type}) orelse {
        if (marker_token_type != .hyphen) {
            return null;
        }

        const rule = try it.consume(scratch, &.{.rule_dash}) orelse
            return null;
        if (rule.lexeme.len > 1) {
            return null;
        }
    };

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
    };
}

fn parseOrderedListOpen(
    scratch: Allocator,
    it: *TokenIterator(BlockTokenType),
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

    // Must be followed by at least one space
    _ = try it.consume(scratch, &.{ .tab, .space }) orelse return null;

    const start = parseOrderedListNumber(numeral_token.lexeme) catch
        return null;

    return .{
        .variant = .{
            .ordered_list = .{
                .marker_token_type = marker_token.token_type,
                .start = start,
            },
        },
    };
}

fn parseOrderedListItemOpen(
    scratch: Allocator,
    it: *TokenIterator(BlockTokenType),
    marker_token_type: BlockTokenType,
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

    _ = parseOrderedListNumber(numeral_token.lexeme) catch return null;

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
    };
}

fn parseAnyContainerOpen(
    scratch: Allocator,
    it: *TokenIterator(BlockTokenType),
) !?ContainerBlock {
    if (try parseBlockquoteOpen(scratch, it)) |container| {
        return container;
    }

    if (try parseBulletListOpen(scratch, it)) |container| {
        return container;
    }

    if (try parseOrderedListOpen(scratch, it)) |container| {
        return container;
    }

    return null;
}

/// Handles list tightness/looseness of list children.
///
/// Marks list children sparse or not based on the tightness of the overall
/// list. Also handles removing redundant paragraph descendants for tight
/// lists.
fn tightenListChildren(alloc: Allocator, list_items: []*ast.Node) bool {
    // find index of last spread child
    var maybe_last_spread_i: ?usize = null;
    for (list_items, 0..) |child, i| {
        if (child.list_item.spread) {
            maybe_last_spread_i = i;
        }
    }

    const is_tight_list: bool = blk: {
        if (maybe_last_spread_i) |last_spread_i| {
            if (last_spread_i < list_items.len - 1) {
                // Spread item that isn't the last child, definitely loose
                break :blk false;
            }

            // Only spread item is the last item in the list.
            // We are a tight list if the last item has no more than one
            // child (the spread would have come from trailing blank
            // lines). Otherwise we are loose.
            const last_item = list_items[last_spread_i];
            break :blk last_item.list_item.children.len <= 1;
        } else {
            // No spread children, so we must be a tight list.
            break :blk true;
        }
    };

    if (is_tight_list) {
        // Eliminate redundant paragraph nodes in tight list
        for (list_items) |child| {
            unwrapTightListItem(alloc, child);
        }
    }

    // If we have a loose list, or a tight list with just one list item, we
    // need to mark all list items as "spread" according to the MyST 0.0.5
    // tests.
    //
    // This is quite confusing! Unclear why the list item should be marked
    // "spread" in the single-list-item case.
    if (!is_tight_list or list_items.len == 1) {
        // Make sure all list items are marked spread
        for (list_items) |child| {
            child.list_item.spread = true;
        }
    }

    return is_tight_list;
}

/// For tight lists, we want list items to have a single text node child rather
/// than a single paragraph node child containing a text node.
fn unwrapTightListItem(alloc: Allocator, item: *ast.Node) void {
    const children = item.list_item.children;
    if (children.len == 1 and @as(ast.NodeType, children[0].*) == .paragraph) {
        const p_node = children[0];
        defer alloc.destroy(p_node);
        defer alloc.free(children);

        item.list_item.children = p_node.paragraph.children;
    }
}

/// Sequence of 1 to 9 arabic digits. Can begin with 0s.
fn parseOrderedListNumber(s: []const u8) !u32 {
    if (s.len > 9) {
        return error.TooManyDigits;
    }

    for (s) |c| {
        if (!std.ascii.isDigit(c)) {
            return error.ContainedNonDigit;
        }
    }

    return try fmt.parseInt(u32, s, 10);
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
    var parser = Self.init(&it);

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
    try testing.expectEqual(false, list_node.list.spread);
    try testing.expectEqual(2, list_node.list.children.len);

    const list_item_node_1 = list_node.list.children[0];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_1.*));
    try testing.expectEqual(true, list_item_node_1.list_item.spread);
    try testing.expectEqual(2, list_item_node_1.list_item.children.len);

    const list_item_node_2 = list_node.list.children[1];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_2.*));
    try testing.expectEqual(true, list_item_node_2.list_item.spread);
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
    try testing.expectEqual(false, list_node.list.spread);
    try testing.expectEqual(2, list_node.list.children.len);

    const list_item_node_1 = list_node.list.children[0];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_1.*));
    try testing.expectEqual(true, list_item_node_1.list_item.spread);
    try testing.expectEqual(1, list_item_node_1.list_item.children.len);

    const p_node_1 = list_item_node_1.list_item.children[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node_1.*));
    try testing.expectEqual(1, p_node_1.paragraph.children.len);
    const txt_node_1 = p_node_1.paragraph.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, txt_node_1.*));
    try testing.expectEqualStrings("First", txt_node_1.text.value);

    const list_item_node_2 = list_node.list.children[1];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_2.*));
    try testing.expectEqual(true, list_item_node_2.list_item.spread);

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
        try testing.expectEqual(true, child.list_item.spread);
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
    try testing.expectEqual(false, list_node.list.spread);
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
        try testing.expectEqual(true, item_node.list_item.spread);
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
    try testing.expectEqual(false, list_node.list.spread);
    try testing.expectEqual(2, list_node.list.children.len);

    const list_item_node_1 = list_node.list.children[0];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_1.*));
    try testing.expectEqual(true, list_item_node_1.list_item.spread);
    try testing.expectEqual(2, list_item_node_1.list_item.children.len);

    const list_item_node_2 = list_node.list.children[1];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_2.*));
    try testing.expectEqual(true, list_item_node_2.list_item.spread);

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
    try testing.expectEqual(false, list_node.list.spread);
    try testing.expectEqual(2, list_node.list.children.len);

    const list_item_node_1 = list_node.list.children[0];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_1.*));
    try testing.expectEqual(true, list_item_node_1.list_item.spread);

    const p_node_1 = list_item_node_1.list_item.children[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node_1.*));
    try testing.expectEqual(1, p_node_1.paragraph.children.len);
    const txt_node_1 = p_node_1.paragraph.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, txt_node_1.*));
    try testing.expectEqualStrings("First", txt_node_1.text.value);

    const list_item_node_2 = list_node.list.children[1];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_2.*));
    try testing.expectEqual(true, list_item_node_2.list_item.spread);

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
        try testing.expectEqual(true, child.list_item.spread);
        try testing.expectEqual(1, child.list_item.children.len);

        const txt_node = child.list_item.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, txt_node.*));
    }
}

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
//! This is a predictive parser with no backtracking.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const ast = @import("../ast.zig");
const BlockToken = @import("../lex/tokens.zig").BlockToken;
const BlockTokenType = @import("../lex/tokens.zig").BlockTokenType;
const LeafBlockParser = @import("LeafBlockParser.zig");
const LinkDefMap = @import("link_defs.zig").LinkDefMap;
const TokenIterator = @import("../lex/iterator.zig").TokenIterator;
const util = @import("../util/util.zig");

const Error = error{
    LineTooLong,
    ReadFailed,
    WriteFailed,
} || Allocator.Error;

/// Where we are in the current line.
const LineState = enum {
    start,
    trailing,
};

/// The result of handling the next token using the current open container.
///
/// A few different things can happen depending on the token.
///
/// 1. The token might not be meaningful to the container block parser, in
///    which case it gets returned in the `token` field to be parsed by a
///    leaf block parser.
/// 2. The token could open a new container, in which case the new container
///    should be returned in the `container` field.
/// 3. The token might result in the closing of the current container, in which
///    case `send_close` should be true.
const NextResult = struct {
    token: ?BlockToken,
    line_state: LineState,
    container: ?OpenContainer = null,
    send_close: bool = false,
};

/// Represents a container block that is open (can still have children added to
/// it).
const OpenContainer = union(enum) {
    root: OpenRoot,
    blockquote: OpenBlockquote,
    bullet_list: OpenBulletList,
    bullet_list_item: OpenBulletListItem,

    pub fn add(
        self: *OpenContainer,
        scratch: Allocator,
        child: *ast.Node,
    ) !void {
        switch (self.*) {
            inline else => |*payload| {
                try payload.children.append(scratch, child);
            },
        }
    }

    /// Handle the next token.
    ///
    /// The `interruptible` param determines whether a new open container is
    /// allowed in the current context. (No containers can open in the middle
    /// of a code block, for example.)
    pub fn next(
        self: *OpenContainer,
        scratch: Allocator,
        it: *TokenIterator(BlockTokenType),
        line_state: LineState,
        interruptible: bool,
    ) !NextResult {
        // This case is the same for all containers, so handle it here
        if (line_state == .trailing) {
            const token = try it.peek(scratch) orelse return .{
                .token = null,
                .line_state = .start,
            };
            _ = try it.consume(scratch, &.{token.token_type});

            switch (token.token_type) {
                .newline => {
                    return .{
                        .token = token,
                        .line_state = .start,
                    };
                },
                else => {
                    return .{
                        .token = token,
                        .line_state = .trailing,
                    };
                },
            }
        }

        switch (self.*) {
            inline else => |*payload| {
                return try payload.next(scratch, it, interruptible);
            },
        }
    }

    /// Close this container block, turning it into an AST node.
    pub fn toNode(self: OpenContainer, alloc: Allocator) !*ast.Node {
        switch (self) {
            inline else => |payload| return payload.toNode(alloc),
        }
    }
};

/// Root container.
const OpenRoot = struct {
    children: ArrayList(*ast.Node),

    pub const empty: OpenRoot = .{ .children = .empty };

    pub fn next(
        self: *OpenRoot,
        scratch: Allocator,
        it: *TokenIterator(BlockTokenType),
        interruptible: bool,
    ) !NextResult {
        _ = self;

        if (interruptible) {
            if (try OpenBlockquote.peekBlockquote(scratch, it)) {
                // open new blockquote
                return .{
                    .token = null,
                    .line_state = .start,
                    .container = .{
                        .blockquote = OpenBlockquote.init(1),
                    },
                };
            }

            if (try OpenBulletList.peekBulletList(
                scratch,
                it,
            )) |marker_token| {
                // open new bullet list
                return .{
                    .token = null,
                    .line_state = .start,
                    .container = .{
                        .bullet_list = OpenBulletList.init(marker_token),
                    },
                };
            }
        }

        const token = try it.peek(scratch) orelse return .{
            .token = null,
            .line_state = .start,
        };
        switch (token.token_type) {
            .newline => {
                _ = try it.consume(scratch, &.{.newline});
                return .{
                    .token = token,
                    .line_state = .start,
                };
            },
            else => {
                _ = try it.consume(scratch, &.{token.token_type});
                return .{
                    .token = token,
                    .line_state = .trailing,
                };
            },
        }
    }

    pub fn toNode(self: OpenRoot, alloc: Allocator) !*ast.Node {
        const children = try alloc.dupe(*ast.Node, self.children.items);
        errdefer alloc.free(children);

        const node = try alloc.create(ast.Node);
        node.* = .{
            .root = .{
                .children = children,
            },
        };
        return node;
    }
};

/// Blockquote container.
const OpenBlockquote = struct {
    children: ArrayList(*ast.Node),
    depth: usize,

    pub fn init(depth: usize) OpenBlockquote {
        return .{
            .children = .empty,
            .depth = depth,
        };
    }

    /// Returns true if the next sequence of tokens can open a blockquote.
    fn peekBlockquote(
        scratch: Allocator,
        it: *TokenIterator(BlockTokenType),
    ) !bool {
        const checkpoint_index = it.checkpoint();
        defer it.backtrack(checkpoint_index);

        _ = try consumeWhitespaceUpTo(scratch, it, 3);
        _ = try it.consume(scratch, &.{.r_angle_bracket}) orelse return false;
        return true;
    }

    pub fn next(
        self: *OpenBlockquote,
        scratch: Allocator,
        it: *TokenIterator(BlockTokenType),
        interruptible: bool,
    ) !NextResult {
        const eof: NextResult = .{
            .token = null,
            .line_state = .start,
        };

        // Consume leading '>' tokens
        const checkpoint_index = it.checkpoint();
        const maybe_next_token = try it.peekAhead(scratch, 2);
        if (maybe_next_token) |next_token| {
            if (next_token.token_type == .r_angle_bracket) {
                // Up to 3 leading spaces allowed before first '>'
                _ = try consumeWhitespaceUpTo(scratch, it, 3);
            }
        }
        const met_depth = for (0..self.depth) |_| {
            if (try it.consume(scratch, &.{.r_angle_bracket})) |_| {
                // Trailing space allowed after each '>', up to four spaces
                _ = try consumeWhitespaceUpTo(scratch, it, 4);
            } else {
                break false;
            }
        } else true;

        if (met_depth) {
            const token = try it.peek(scratch) orelse return eof;
            switch (token.token_type) {
                .r_angle_bracket => {
                    if (!interruptible) {
                        // Just pass on the token
                        _ = try it.consume(scratch, &.{token.token_type});
                        return .{
                            .token = token,
                            .line_state = .trailing,
                        };
                    }

                    // Another level of blockquote! We backtrack and let the
                    // new blockquote container parse the whole line.
                    it.backtrack(checkpoint_index);
                    return .{
                        .token = null,
                        .line_state = .start,
                        .container = .{
                            .blockquote = OpenBlockquote.init(self.depth + 1),
                        },
                    };
                },
                .newline => {
                    // Blank line after '>'
                    _ = try it.consume(scratch, &.{.newline});
                    return .{
                        .token = token,
                        .line_state = .start,
                    };
                },
                .whitespace => {
                    // Enough whitespace following the '>' to be significant
                    // We need to trim one allowed space from the token
                    _ = try it.consume(scratch, &.{.whitespace});
                    return .{
                        .token = .{
                            .token_type = .whitespace,
                            .lexeme = try scratch.dupe(u8, token.lexeme[1..]),
                        },
                        .line_state = .start,
                    };
                },
                else => {
                    // Beginning of line proper
                    _ = try it.consume(scratch, &.{token.token_type});
                    return .{
                        .token = token,
                        .line_state = .trailing,
                    };
                },
            }
        } else {
            const token = try it.peek(scratch) orelse return eof;
            switch (token.token_type) {
                .newline => {
                    // Blank line
                    _ = try it.consume(scratch, &.{.newline});
                    return .{
                        .token = token,
                        .send_close = true,
                        .line_state = .start,
                    };
                },
                else => {
                    // Line starting without enough leading >
                    _ = try it.consume(scratch, &.{token.token_type});
                    return .{
                        .token = token,
                        .send_close = true,
                        .line_state = .trailing,
                    };
                },
            }
        }
    }

    pub fn toNode(self: OpenBlockquote, alloc: Allocator) !*ast.Node {
        const children = try alloc.dupe(*ast.Node, self.children.items);
        errdefer alloc.free(children);

        const node = try alloc.create(ast.Node);
        node.* = .{
            .blockquote = .{
                .children = children,
            },
        };
        return node;
    }
};

/// Bullet list container.
const OpenBulletList = struct {
    children: ArrayList(*ast.Node),
    marker_token: BlockToken,

    fn init(marker_token: BlockToken) OpenBulletList {
        // TODO: Use enum subset?
        std.debug.assert(marker_token.token_type == .star or
            marker_token.token_type == .hyphen or
            marker_token.token_type == .plus);

        return .{
            .children = .empty,
            .marker_token = marker_token,
        };
    }

    /// Returns the marker token if the next sequence of tokens can open a
    /// bullet list.
    ///
    /// Returns null otherwise.
    fn peekBulletList(
        scratch: Allocator,
        it: *TokenIterator(BlockTokenType),
    ) !?BlockToken {
        const checkpoint_index = it.checkpoint();
        defer it.backtrack(checkpoint_index);

        _ = try consumeWhitespaceUpTo(scratch, it, 3);
        const marker_token = try it.consume(
            scratch,
            &.{ .hyphen, .star, .plus },
        ) orelse
            return null;
        _ = try it.consume(scratch, &.{.whitespace}) orelse return null;

        return marker_token;
    }

    fn next(
        self: *OpenBulletList,
        scratch: Allocator,
        it: *TokenIterator(BlockTokenType),
        interruptible: bool,
    ) !NextResult {
        // If the leaf parser is parsing something that cannot be interrupted,
        // then we should be in a list item or different kind of container.
        std.debug.assert(interruptible == true);

        const eof: NextResult = .{
            .token = null,
            .line_state = .start,
        };

        if (try OpenBulletListItem.peekBulletListItem(
            scratch,
            it,
            self.marker_token.token_type,
        )) {
            // Open new bullet list item
            return .{
                .token = null,
                .line_state = .start,
                .container = .{
                    .bullet_list_item = OpenBulletListItem.init(
                        self.marker_token,
                    ),
                },
            };
        }

        const token = try it.peek(scratch) orelse return eof;
        switch (token.token_type) {
            .star, .hyphen, .plus => {
                // It's the start of a new list, so close the container
                return .{
                    .token = null,
                    .line_state = .start,
                };
            },
            else => {
                // end of list
                _ = try it.consume(scratch, &.{token.token_type});
                return .{
                    .token = token,
                    .send_close = true,
                    .line_state = .trailing,
                };
            },
        }
    }

    fn toNode(self: OpenBulletList, alloc: Allocator) !*ast.Node {
        const children = try alloc.dupe(*ast.Node, self.children.items);
        errdefer alloc.free(children);

        const node = try alloc.create(ast.Node);
        node.* = .{
            .list = .{
                .children = children,
                .ordered = false,
            },
        };
        return node;
    }
};

/// Bullet list item container.
const OpenBulletListItem = struct {
    children: ArrayList(*ast.Node),
    marker_token: BlockToken,
    indent: usize,

    fn init(marker_token: BlockToken) OpenBulletListItem {
        return .{
            .children = .empty,
            .marker_token = marker_token,
            .indent = 0,
        };
    }

    /// Returns true if the next sequence of tokens can open a bullet list
    /// item.
    fn peekBulletListItem(
        scratch: Allocator,
        it: *TokenIterator(BlockTokenType),
        marker_token_type: BlockTokenType,
    ) !bool {
        const checkpoint_index = it.checkpoint();
        defer it.backtrack(checkpoint_index);

        _ = try consumeWhitespaceUpTo(scratch, it, 3);
        _ = try it.consume(scratch, &.{marker_token_type}) orelse
            return false;
        _ = try it.consume(scratch, &.{.whitespace}) orelse return false;
        return true;
    }

    fn next(
        self: *OpenBulletListItem,
        scratch: Allocator,
        it: *TokenIterator(BlockTokenType),
        interruptible: bool,
    ) !NextResult {
        const eof: NextResult = .{
            .token = null,
            .line_state = .start,
        };

        if (self.indent == 0) {
            // Handle first line
            const leading_ws_len = try consumeWhitespaceUpTo(scratch, it, 3);
            _ = try it.consume(
                scratch,
                &.{self.marker_token.token_type},
            ) orelse
                @panic("bullet list item created with wrong marker token");
            const following_ws_len = try consumeWhitespaceUpTo(scratch, it, 4);
            self.indent = leading_ws_len + 1 + following_ws_len;
        } else {
            const start_token = try it.peek(scratch) orelse return eof;
            switch (start_token.token_type) {
                .whitespace => {
                    if (start_token.lexeme.len < self.indent) {
                        // Not indented enough; end list item
                        return .{
                            .token = null,
                            .line_state = .start,
                        };
                    }

                    _ = try it.consume(scratch, &.{.whitespace});
                },
                .newline => {
                    // Blank line; allowed in list item
                    _ = try it.consume(scratch, &.{.newline});
                    return .{
                        .token = start_token,
                        .line_state = .start,
                    };
                },
                else => {
                    // End list item
                    return .{
                        .token = null,
                        .line_state = .start,
                    };
                },
            }
        }

        const token = try it.peek(scratch) orelse return eof;
        switch (token.token_type) {
            .star, .hyphen, .plus => {
                if (!interruptible) {
                    // Just pass on the token
                    return .{
                        .token = token,
                        .line_state = .trailing,
                    };
                }

                // Can't yet nest lists
                return .{
                    .token = null,
                    .line_state = .start,
                };
            },
            else => {
                _ = try it.consume(scratch, &.{token.token_type});
                return .{
                    .token = token,
                    .line_state = .trailing,
                };
            },
        }
    }

    fn toNode(self: OpenBulletListItem, alloc: Allocator) !*ast.Node {
        // If we have just a single paragraph, unwrap it.
        // In the 0.0.5 MyST spec test cases, this is required. But as of June
        // 2026 the online MyST sandbox does NOT do this unwrapping.
        //
        // In CommonMark, this kind of unwrapping is expected by the spec but
        // appears (in the online CommonMark sandbox) to be implemented in the
        // HTML renderer.
        const children = blk: {
            if (self.children.items.len == 1 and
                @as(ast.NodeType, self.children.items[0].*) == .paragraph)
            {
                const p_node = self.children.items[0];
                defer alloc.destroy(p_node);

                break :blk p_node.paragraph.children;
            }

            break :blk try alloc.dupe(*ast.Node, self.children.items);
        };
        errdefer alloc.free(children);

        const node = try alloc.create(ast.Node);
        node.* = .{
            .list_item = .{
                .children = children,
            },
        };
        return node;
    }
};

// Set to true to print tokens sent to leaf block parser.
const debug_stream = false;

// Iterator that the container block parser consumes
it: *TokenIterator(BlockTokenType),
container_stack: ArrayList(OpenContainer),
line_state: LineState,
maybe_staged_token: ?BlockToken, // next token to be consumed by leaf parser
leaf_parser: ?LeafBlockParser,

const Self = @This();

pub fn init(it: *TokenIterator(BlockTokenType)) Self {
    return .{
        .it = it,
        .container_stack = .empty,
        .line_state = .start,
        .maybe_staged_token = null,
        .leaf_parser = null,
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
        .root = OpenRoot.empty,
    });

    var leaf_it = self.iterator();
    for (0..util.safety.loop_bound) |_| {
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
            try original_top.add(scratch, node);
        }

        if (self.container_stack.items.len > loop_start_stack_len) {
            // We pushed a new container
            std.debug.assert(leaf_it.is_exhausted);
            continue;
        }

        // Pop top container, unless we're at root
        if (self.container_stack.items.len > 1) {
            const popped = self.container_stack.pop() orelse unreachable;
            const node = try popped.toNode(alloc);
            errdefer node.deinit(alloc);
            try self.top().add(scratch, node);
        } else {
            break;
        }
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
    if (self.maybe_staged_token) |staged_token| {
        self.maybe_staged_token = null;
        return staged_token;
    }

    const result = try self.top().next(
        scratch,
        self.it,
        self.line_state,
        self.leaf_parser.?.interruptible,
    );

    self.line_state = result.line_state;
    if (result.container) |container| {
        // Pushing a new container should coincide with ending the token stream
        std.debug.assert(result.token == null);
        std.debug.assert(!result.send_close);

        try self.container_stack.append(scratch, container);
    }

    if (result.send_close) {
        self.maybe_staged_token = result.token;
        return .{ .token_type = .close };
    }

    return result.token;
}

/// Returns pointer to last container in stack.
///
/// Be careful holding on to this pointer. Could be invalidated by the stack
/// growing or shrinking.
///
/// TODO: Maybe the ArrayList should hold pointers to the containers and not
/// the containers themselves.
fn top(self: *Self) *OpenContainer {
    std.debug.assert(self.container_stack.items.len > 0);
    return &self.container_stack.items[
        self.container_stack.items.len - 1
    ];
}

/// Consumes a whitespace token, but only if it's no longer than the given len
/// (in spaces). Returns the length of the consumed token (or zero).
fn consumeWhitespaceUpTo(
    scratch: Allocator,
    it: *TokenIterator(BlockTokenType),
    len: usize,
) !usize {
    const token = try it.peek(scratch) orelse return 0;
    if (token.token_type != .whitespace) {
        return 0;
    }

    if (util.strings.whitespaceIndentLen(token.lexeme) > len) {
        return 0;
    }

    const ws_token = try it.consume(scratch, &.{.whitespace}) orelse
        unreachable;
    return ws_token.lexeme.len;
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
    ;

    const root = try parseBlocks(md);
    defer root.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
    try testing.expectEqual(3, root.root.children.len);

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
    try testing.expectEqual(3, list_node.list.children.len);

    for (0..3) |i| {
        const list_item_node = list_node.list.children[i];
        try testing.expectEqual(
            .list_item,
            @as(ast.NodeType, list_item_node.*),
        );
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
    try testing.expectEqual(2, list_node_1.list.children.len);

    const list_node_2 = root_node.root.children[1];
    try testing.expectEqual(.list, @as(ast.NodeType, list_node_2.*));
    try testing.expectEqual(false, list_node_2.list.ordered);
    try testing.expectEqual(1, list_node_2.list.children.len);
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
    try testing.expectEqual(1, list_node.list.children.len);

    const list_item_node = list_node.list.children[0];
    try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node.*));
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

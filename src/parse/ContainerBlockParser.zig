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

const ast = @import("ast.zig");
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

const LineState = enum {
    start,
    trailing,
};

const NextResult = struct {
    token: ?BlockToken,
    line_state: LineState,
    container: ?OpenContainer = null,
    send_close: bool = false,
};

/// Generic open container block.
const OpenContainer = union(enum) {
    root: OpenRoot,
    blockquote: OpenBlockquote,

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

    pub fn next(
        self: *OpenContainer,
        scratch: Allocator,
        it: *TokenIterator(BlockTokenType),
        line_state: LineState,
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
                return try payload.next(scratch, it);
            },
        }
    }

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
    ) !NextResult {
        _ = self;

        const token = try it.peek(scratch) orelse return .{
            .token = null,
            .line_state = .start,
        };
        switch (token.token_type) {
            .r_angle_bracket => {
                return .{
                    .token = null,
                    .line_state = .start,
                    .container = .{
                        .blockquote = OpenBlockquote.init(1),
                    },
                };
            },
            .newline => {
                _ = try it.consume(scratch, &.{.newline});
                return .{
                    .token = token,
                    .line_state = .start,
                };
            },
            .whitespace => {
                if (try it.peekAhead(scratch, 2)) |next_token| {
                    if (next_token.token_type == .r_angle_bracket) {
                        return .{
                            .token = null,
                            .line_state = .start,
                            .container = .{
                                .blockquote = OpenBlockquote.init(1),
                            },
                        };
                    }
                }

                _ = try it.consume(scratch, &.{.whitespace});
                return .{
                    .token = token,
                    .line_state = .trailing,
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

    pub fn next(
        self: *OpenBlockquote,
        scratch: Allocator,
        it: *TokenIterator(BlockTokenType),
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
                 // Leading space allowed before first '>'
                _ = try it.consume(scratch, &.{.whitespace});
            }
        }
        const met_depth = for (0..self.depth) |_| {
            if (try it.consume(scratch, &.{.r_angle_bracket})) |_| {
                // Trailing space allowed after each '>'
                _ = try it.consume(scratch, &.{.whitespace});
            } else {
                break false;
            }
        } else true;

        if (met_depth) {
            const token = try it.peek(scratch) orelse return eof;
            switch (token.token_type) {
                .r_angle_bracket => {
                    // Another level of blockquote! We backtrack and let the new
                    // blockquote container parse the whole line.
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
                    // Line starting without a leading >
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

// Set to true to print tokens sent to leaf block parser.
const debug_stream = false;

it: *TokenIterator(BlockTokenType), // Iterator that the container block parser consumes
container_stack: ArrayList(OpenContainer),
line_state: LineState,
maybe_staged_token: ?BlockToken,

const Self = @This();

pub fn init(it: *TokenIterator(BlockTokenType)) Self {
    return .{
        .it = it,
        .container_stack = .empty,
        .line_state = .start,
        .maybe_staged_token = null
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
        var leaf_parser: LeafBlockParser = .{ .it = &leaf_it };
        const original_top = self.top();

        // Internal iterator logic runs, potentially pushing onto stack
        const nodes = try leaf_parser.parse(alloc, scratch, link_defs);
        errdefer {
            for (nodes) |node| {
                node.deinit(alloc);
            }
        }
        defer alloc.free(nodes);

        for (nodes) |node| {
            try original_top.add(scratch, node);
        }

        if (self.top() != original_top) {
            // We pushed a new container
            std.debug.assert(leaf_it.is_exhausted);
            leaf_it = self.iterator(); // reset iterator
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

    const result = try self.top().next(scratch, self.it, self.line_state);

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

fn top(self: *Self) *OpenContainer {
    std.debug.assert(self.container_stack.items.len > 0);
    return &self.container_stack.items[
        self.container_stack.items.len - 1
    ];
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
        try testing.expectEqualStrings("Heading", h_txt.text.value);

        const bq_p = bq.blockquote.children[1];
        try testing.expectEqual(.paragraph, @as(ast.NodeType, bq_p.*));

        const p_txt = bq_p.paragraph.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, p_txt.*));
        try testing.expectEqualStrings("Paragraph text.", p_txt.text.value);

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

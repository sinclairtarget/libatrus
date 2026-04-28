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

        const token = try it.peek(scratch) orelse return .{
            .token = null,
            .line_state = .start,
        };
        swtch: switch (token.token_type) {
            .r_angle_bracket => {
                if (!interruptible) {
                    break :swtch;
                }
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
                if (
                    util.strings.whitespaceIndentLen(token.lexeme) >= 4
                    or !interruptible
                ) {
                    break :swtch;
                }

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
            },
            else => {},
        }

        // Fallback case
        _ = try it.consume(scratch, &.{token.token_type});
        return .{
            .token = token,
            .line_state = .trailing,
        };
    }

    pub fn toNode(self: OpenRoot, alloc: Allocator) !*ast.Node {
        const children = try alloc.dupe(*ast.Node, self.children.items);
        errdefer alloc.free(children);

        const node = try alloc.create(ast.Node);
        node.* = .{
            .tag = .root,
            .payload = .{
                .root = .{
                    .children = children.ptr,
                    .n_children = @intCast(children.len),
                },
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
            .tag = .blockquote,
            .payload = .{
                .blockquote = .{
                    .children = children.ptr,
                    .n_children = @intCast(children.len),
                },
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
/// (in spaces).
fn consumeWhitespaceUpTo(
    scratch: Allocator,
    it: *TokenIterator(BlockTokenType),
    len: usize,
) !void {
    const token = try it.peek(scratch) orelse return;
    if (token.token_type != .whitespace) {
        return;
    }

    if (util.strings.whitespaceIndentLen(token.lexeme) > len) {
        return;
    }

    _ = try it.consume(scratch, &.{.whitespace});
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

    try testing.expectEqual(.root, root.tag);
    try testing.expectEqual(0, root.payload.root.n_children);
}

test "simple paragraph" {
    const md =
        \\This is a paragraph. It goes on for
        \\multiple lines.
        \\
    ;

    const root = try parseBlocks(md);
    defer root.deinit(testing.allocator);

    try testing.expectEqual(.root, root.tag);
    try testing.expectEqual(1, root.payload.root.n_children);

    const p = root.payload.root.children[0];
    try testing.expectEqual(.paragraph, p.tag);

    const txt = p.payload.paragraph.children[0];
    try testing.expectEqual(.text, txt.tag);
    try testing.expectEqualStrings(
        "This is a paragraph. It goes on for\nmultiple lines.",
        std.mem.span(txt.payload.text.value),
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

    try testing.expectEqual(.root, root.tag);
    try testing.expectEqual(2, root.payload.root.n_children);

    const bq = root.payload.root.children[0];
    try testing.expectEqual(.blockquote, bq.tag);
    try testing.expectEqual(1, bq.payload.blockquote.n_children);
    {
        const p = bq.payload.blockquote.children[0];
        try testing.expectEqual(.paragraph, p.tag);
        try testing.expectEqual(1, p.payload.paragraph.n_children);

        const txt = p.payload.paragraph.children[0];
        try testing.expectEqual(.text, txt.tag);
        try testing.expectEqualStrings(
            "This is a block-quoted paragraph. It goes on for\nmultiple lines.",
            std.mem.span(txt.payload.text.value),
        );
    }

    const p = root.payload.root.children[1];
    try testing.expectEqual(.paragraph, p.tag);
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

    try testing.expectEqual(.root, root.tag);
    try testing.expectEqual(3, root.payload.root.n_children);

    const bq1 = root.payload.root.children[0];
    try testing.expectEqual(.blockquote, bq1.tag);
    try testing.expectEqual(1, bq1.payload.blockquote.n_children);
    {
        const p = bq1.payload.blockquote.children[0];
        try testing.expectEqual(.paragraph, p.tag);
        try testing.expectEqual(1, p.payload.paragraph.n_children);

        const txt = p.payload.paragraph.children[0];
        try testing.expectEqual(.text, txt.tag);
        try testing.expectEqualStrings(
            "This should\nrun on\nfor multiple lines.",
            std.mem.span(txt.payload.text.value),
        );
    }

    const bq2 = root.payload.root.children[1];
    try testing.expectEqual(.blockquote, bq2.tag);

    const h = root.payload.root.children[2];
    try testing.expectEqual(.heading, h.tag);
}

test "blockquote after paragraph" {
    const md =
        \\This is a paragraph outside the blockquote.
        \\>This is a paragraph inside the blockquote.
        \\
    ;

    const root = try parseBlocks(md);
    defer root.deinit(testing.allocator);

    try testing.expectEqual(.root, root.tag);
    try testing.expectEqual(2, root.payload.root.n_children);

    const p = root.payload.root.children[0];
    try testing.expectEqual(.paragraph, p.tag);

    const bq = root.payload.root.children[1];
    try testing.expectEqual(.blockquote, bq.tag);
    try testing.expectEqual(1, bq.payload.blockquote.n_children);
    {
        const bq_p = bq.payload.blockquote.children[0];
        try testing.expectEqual(.paragraph, bq_p.tag);

        const bq_txt = bq_p.payload.paragraph.children[0];
        try testing.expectEqual(.text, bq_txt.tag);
        try testing.expectEqualStrings(
            "This is a paragraph inside the blockquote.",
            std.mem.span(bq_txt.payload.text.value),
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

    try testing.expectEqual(.root, root.tag);
    try testing.expectEqual(1, root.payload.root.n_children);

    const bq = root.payload.root.children[0];
    try testing.expectEqual(.blockquote, bq.tag);
    try testing.expectEqual(1, bq.payload.blockquote.n_children);
    {
        const bq_p = bq.payload.blockquote.children[0];
        try testing.expectEqual(.paragraph, bq_p.tag);

        const bq_txt = bq_p.payload.paragraph.children[0];
        try testing.expectEqual(.text, bq_txt.tag);
        try testing.expectEqualStrings(
            \\This is a paragraph inside the blockquote.
            \\So is this line.
            \\And this line.
            ,
            std.mem.span(bq_txt.payload.text.value),
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

    try testing.expectEqual(.root, root.tag);
    try testing.expectEqual(1, root.payload.root.n_children);

    const bq = root.payload.root.children[0];
    try testing.expectEqual(.blockquote, bq.tag);
    try testing.expectEqual(3, bq.payload.blockquote.n_children);
    {
        const bq_h = bq.payload.blockquote.children[0];
        try testing.expectEqual(.heading, bq_h.tag);

        const h_txt = bq_h.payload.heading.children[0];
        try testing.expectEqual(.text, h_txt.tag);
        try testing.expectEqualStrings(
            "Heading",
            std.mem.span(h_txt.payload.text.value),
        );

        const bq_p = bq.payload.blockquote.children[1];
        try testing.expectEqual(.paragraph, bq_p.tag);

        const p_txt = bq_p.payload.paragraph.children[0];
        try testing.expectEqual(.text, p_txt.tag);
        try testing.expectEqualStrings(
            "Paragraph text.",
            std.mem.span(p_txt.payload.text.value),
        );

        const bq_code = bq.payload.blockquote.children[2];
        try testing.expectEqual(.code, bq_code.tag);
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

    try testing.expectEqual(.root, root.tag);
    try testing.expectEqual(3, root.payload.root.n_children);

    {
        const p = root.payload.root.children[0];
        try testing.expectEqual(.paragraph, p.tag);
        const p_txt = p.payload.paragraph.children[0];
        try testing.expectEqual(.text, p_txt.tag);
        try testing.expectEqualStrings(
            "This is a paragraph.",
            std.mem.span(p_txt.payload.text.value),
        );
    }

    const bq_outer = root.payload.root.children[1];
    try testing.expectEqual(.blockquote, bq_outer.tag);
    try testing.expectEqual(3, bq_outer.payload.blockquote.n_children);
    {
        const p1 = bq_outer.payload.blockquote.children[0];
        try testing.expectEqual(.paragraph, p1.tag);
        try testing.expectEqual(1, p1.payload.paragraph.n_children);
        const p1_txt = p1.payload.paragraph.children[0];
        try testing.expectEqual(.text, p1_txt.tag);
        try testing.expectEqualStrings(
            "This is blockquoted.",
            std.mem.span(p1_txt.payload.text.value),
        );

        const bq_inner = bq_outer.payload.blockquote.children[1];
        try testing.expectEqual(.blockquote, bq_inner.tag);
        try testing.expectEqual(1, bq_inner.payload.blockquote.n_children);
        const bq_inner_p = bq_inner.payload.blockquote.children[0];
        try testing.expectEqual(.paragraph, bq_inner_p.tag);
        try testing.expectEqual(1, bq_inner_p.payload.paragraph.n_children);
        const bq_inner_p_txt = bq_inner_p.payload.paragraph.children[0];
        try testing.expectEqual(.text, bq_inner_p_txt.tag);
        try testing.expectEqualStrings(
            "This is double-blockquoted.\nStill double-blockquoted (lazy).",
            std.mem.span(bq_inner_p_txt.payload.text.value),
        );

        const p2 = bq_outer.payload.blockquote.children[2];
        try testing.expectEqual(.paragraph, p2.tag);
        try testing.expectEqual(1, p2.payload.paragraph.n_children);
        const p2_txt = p2.payload.paragraph.children[0];
        try testing.expectEqual(.text, p2_txt.tag);
        try testing.expectEqualStrings(
            "This is single blockquoted again.",
            std.mem.span(p2_txt.payload.text.value),
        );
    }

    {
        const p = root.payload.root.children[2];
        try testing.expectEqual(.paragraph, p.tag);
        const p_txt = p.payload.paragraph.children[0];
        try testing.expectEqual(.text, p_txt.tag);
        try testing.expectEqualStrings(
            "This is another regular paragraph.",
            std.mem.span(p_txt.payload.text.value),
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

    try testing.expectEqual(.root, root.tag);
    try testing.expectEqual(1, root.payload.root.n_children);

    const code = root.payload.root.children[0];
    try testing.expectEqual(.code, code.tag);
    try testing.expectEqualStrings(
        "> foo",
        std.mem.span(code.payload.code.value),
    );
}

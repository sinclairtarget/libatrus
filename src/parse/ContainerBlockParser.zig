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
/// it).
const Container = struct {
    children: ArrayList(*ast.Node) = .empty,
    closed: bool = false,
    container_type: union(enum) {
        root: Root,
        blockquote: Blockquote,
        //     bullet_list: BulletList,
        //     bullet_list_item: BulletListItem,
        //     ordered_list: OrderedList,
        //     ordered_list_item: OrderedListItem,
    },

    fn addChild(
        self: *Container,
        scratch: Allocator,
        child: *ast.Node,
    ) !void {
        try self.children.append(scratch, child);
    }

    fn establish(
        self: Container,
        scratch: Allocator,
        it: *TokenIterator(BlockTokenType),
    ) !bool {
        switch (self.container_type) {
            inline else => |payload| {
                return try payload.establish(scratch, it);
            },
        }
    }

    /// Close this container block, turning it into an AST node.
    fn toNode(self: Container, alloc: Allocator) !*ast.Node {
        switch (self.container_type) {
            inline else => |payload| {
                return payload.toNode(alloc, self.children.items);
            },
        }
    }
};

/// Root container.
const Root = struct {
    fn establish(
        self: Root,
        scratch: Allocator,
        it: *TokenIterator(BlockTokenType),
    ) !bool {
        _ = self;
        _ = scratch;
        _ = it;

        // Root container is by definition always established.
        return true;
    }

    fn toNode(
        self: Root,
        alloc: Allocator,
        children: []*ast.Node,
    ) !*ast.Node {
        _ = self;

        const owned_children = try alloc.dupe(*ast.Node, children);
        errdefer alloc.free(owned_children);

        const node = try alloc.create(ast.Node);
        node.* = .{
            .root = .{
                .children = owned_children,
            },
        };
        return node;
    }
};

/// Blockquote container.
const Blockquote = struct {
    fn establish(
        self: Blockquote,
        scratch: Allocator,
        it: *TokenIterator(BlockTokenType),
    ) !bool {
        _ = self;

        if (try parseBlockquote(scratch, it)) |_| {
            return true;
        }

        return false;
    }

    fn toNode(
        self: Blockquote,
        alloc: Allocator,
        children: []*ast.Node,
    ) !*ast.Node {
        _ = self;

        const owned_children = try alloc.dupe(*ast.Node, children);
        errdefer alloc.free(owned_children);

        const node = try alloc.create(ast.Node);
        node.* = .{
            .blockquote = .{
                .children = owned_children,
            },
        };
        return node;
    }
};

// Set to true to print tokens sent to leaf block parser.
const debug_stream = false;

// Iterator that the container block parser consumes
it: *TokenIterator(BlockTokenType),
leaf_parser: ?LeafBlockParser,
container_stack: ArrayList(Container),
unestablished_container_i: usize,
can_open_containers: bool,
maybe_staged_token: ?BlockToken,

const Self = @This();

pub fn init(it: *TokenIterator(BlockTokenType)) Self {
    return .{
        .it = it,
        .leaf_parser = null,
        .container_stack = .empty,
        .unestablished_container_i = 0,
        .can_open_containers = true,
        .maybe_staged_token = null,
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
        .container_type = .{ .root = .{} },
    });
    self.unestablished_container_i = 0;
    self.can_open_containers = true;

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
            try original_top.addChild(scratch, node);
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
            try self.top().addChild(scratch, node);
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

    if (self.unestablished_container_i == 0) {
        for (self.container_stack.items) |container| {
            if (!try container.establish(scratch, self.it)) {
                break;
            }

            self.unestablished_container_i += 1;
        }
    }

    if (self.unestablished_container_i < self.container_stack.items.len) {
        const top_container = self.top();
        if (!top_container.closed) {
            top_container.closed = true;
            return .{ .token_type = .close };
        }
    }

    // Handle opening new containers.
    // Pushing a new container should coincide with ending the token stream for
    // the current container.
    if (self.can_open_containers and self.leaf_parser.?.interruptible) {
        const maybe_container: ?Container = blk: {
            if (try parseBlockquote(scratch, self.it)) |container| {
                break :blk container;
            }

            break :blk null;
        };

        if (maybe_container) |container| {
            try self.container_stack.append(scratch, container);
            self.unestablished_container_i += 1;
            return null;
        }
    }

    self.can_open_containers = false;

    const next_token = try self.it.peek(scratch) orelse return null;
    if (next_token.token_type == .newline) {
        self.unestablished_container_i = 0;
        self.can_open_containers = true;
    }

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
fn top(self: *Self) *Container {
    std.debug.assert(self.container_stack.items.len > 0);
    return &self.container_stack.items[
        self.container_stack.items.len - 1
    ];
}

fn parseBlockquote(
    scratch: Allocator,
    it: *TokenIterator(BlockTokenType),
) !?Container {
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
        .container_type = .{
            .blockquote = .{},
        },
    };
}

fn handleListTightness(alloc: Allocator, list_items: []*ast.Node) void {
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
            // lines).
            // Otherwise we are loose.
            const last_item = list_items[last_spread_i];
            break :blk last_item.list_item.children.len <= 1;
        } else {
            // No spread children, so we must be a tight list
            break :blk true;
        }
    };

    if (is_tight_list) {
        // Eliminate redundant paragraph nodes in tight list
        for (list_items) |child| {
            unwrapTightListItem(alloc, child);
        }
    } else {
        // Make sure all list items are marked spread
        for (list_items) |child| {
            child.list_item.spread = true;
        }
    }
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

//
// test "simple bullet list" {
//     const md =
//         \\* First
//         \\* Second
//         \\* Third
//         \\
//     ;
//
//     const root_node = try parseBlocks(md);
//     defer root_node.deinit(testing.allocator);
//
//     try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
//     try testing.expectEqual(1, root_node.root.children.len);
//
//     const list_node = root_node.root.children[0];
//     try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
//     try testing.expectEqual(false, list_node.list.ordered);
//     try testing.expectEqual(false, list_node.list.spread);
//     try testing.expectEqual(3, list_node.list.children.len);
//
//     for (0..3) |i| {
//         const list_item_node = list_node.list.children[i];
//         try testing.expectEqual(
//             .list_item,
//             @as(ast.NodeType, list_item_node.*),
//         );
//         try testing.expectEqual(false, list_item_node.list_item.spread);
//         try testing.expectEqual(1, list_item_node.list_item.children.len);
//
//         const txt_node = list_item_node.list_item.children[0];
//         try testing.expectEqual(.text, @as(ast.NodeType, txt_node.*));
//     }
// }
//
// test "bullet list markers" {
//     const md =
//         \\+ First
//         \\+ Second
//         \\- First
//         \\
//     ;
//
//     const root_node = try parseBlocks(md);
//     defer root_node.deinit(testing.allocator);
//
//     try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
//     try testing.expectEqual(2, root_node.root.children.len);
//
//     const list_node_1 = root_node.root.children[0];
//     try testing.expectEqual(.list, @as(ast.NodeType, list_node_1.*));
//     try testing.expectEqual(false, list_node_1.list.ordered);
//     try testing.expectEqual(false, list_node_1.list.spread);
//     try testing.expectEqual(2, list_node_1.list.children.len);
//
//     const list_node_2 = root_node.root.children[1];
//     try testing.expectEqual(.list, @as(ast.NodeType, list_node_2.*));
//     try testing.expectEqual(false, list_node_2.list.ordered);
//     try testing.expectEqual(false, list_node_2.list.spread);
//     try testing.expectEqual(1, list_node_2.list.children.len);
// }
//
// test "bullet list spread item" {
//     const md =
//         \\* This contains a blank line.
//         \\
//         \\  Blank line above.
//         \\* Second
//         \\
//     ;
//
//     const root_node = try parseBlocks(md);
//     defer root_node.deinit(testing.allocator);
//
//     try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
//     try testing.expectEqual(1, root_node.root.children.len);
//
//     const list_node = root_node.root.children[0];
//     try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
//     try testing.expectEqual(false, list_node.list.ordered);
//     try testing.expectEqual(false, list_node.list.spread);
//     try testing.expectEqual(2, list_node.list.children.len);
//
//     const list_item_node_1 = list_node.list.children[0];
//     try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_1.*));
//     try testing.expectEqual(true, list_item_node_1.list_item.spread);
//     try testing.expectEqual(2, list_item_node_1.list_item.children.len);
//
//     const list_item_node_2 = list_node.list.children[1];
//     try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_2.*));
//     try testing.expectEqual(true, list_item_node_2.list_item.spread);
//     try testing.expectEqual(1, list_item_node_2.list_item.children.len);
//
//     const p_node_2 = list_item_node_2.list_item.children[0];
//     try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node_2.*));
//     try testing.expectEqual(1, p_node_2.paragraph.children.len);
//     const txt_node_2 = p_node_2.paragraph.children[0];
//     try testing.expectEqual(.text, @as(ast.NodeType, txt_node_2.*));
//     try testing.expectEqualStrings("Second", txt_node_2.text.value);
// }
//
// test "bullet list spread list" {
//     const md =
//         \\* First
//         \\
//         \\* Second
//         \\
//     ;
//
//     const root_node = try parseBlocks(md);
//     defer root_node.deinit(testing.allocator);
//
//     try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
//     try testing.expectEqual(1, root_node.root.children.len);
//
//     const list_node = root_node.root.children[0];
//     try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
//     try testing.expectEqual(false, list_node.list.ordered);
//     try testing.expectEqual(false, list_node.list.spread);
//     try testing.expectEqual(2, list_node.list.children.len);
//
//     const list_item_node_1 = list_node.list.children[0];
//     try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_1.*));
//     try testing.expectEqual(true, list_item_node_1.list_item.spread);
//     try testing.expectEqual(1, list_item_node_1.list_item.children.len);
//
//     const p_node_1 = list_item_node_1.list_item.children[0];
//     try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node_1.*));
//     try testing.expectEqual(1, p_node_1.paragraph.children.len);
//     const txt_node_1 = p_node_1.paragraph.children[0];
//     try testing.expectEqual(.text, @as(ast.NodeType, txt_node_1.*));
//     try testing.expectEqualStrings("First", txt_node_1.text.value);
//
//     const list_item_node_2 = list_node.list.children[1];
//     try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_2.*));
//     try testing.expectEqual(true, list_item_node_2.list_item.spread);
//
//     const p_node_2 = list_item_node_2.list_item.children[0];
//     try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node_2.*));
//     try testing.expectEqual(1, p_node_2.paragraph.children.len);
//     const txt_node_2 = p_node_2.paragraph.children[0];
//     try testing.expectEqual(.text, @as(ast.NodeType, txt_node_2.*));
//     try testing.expectEqualStrings("Second", txt_node_2.text.value);
// }
//
// // This list should be tight. The trailing blank lines are after the list.
// test "bullet list trailing blank lines" {
//     const md =
//         \\* First
//         \\* Second
//         \\
//         \\This is a paragraph.
//         \\
//     ;
//
//     const root_node = try parseBlocks(md);
//     defer root_node.deinit(testing.allocator);
//
//     try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
//     try testing.expectEqual(2, root_node.root.children.len);
//
//     const list_node = root_node.root.children[0];
//     try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
//     try testing.expectEqual(false, list_node.list.spread);
//     try testing.expectEqual(2, list_node.list.children.len);
//
//     {
//         const child = list_node.list.children[0];
//         try testing.expectEqual(.list_item, @as(ast.NodeType, child.*));
//         try testing.expectEqual(false, child.list_item.spread);
//         try testing.expectEqual(1, child.list_item.children.len);
//
//         const txt_node = child.list_item.children[0];
//         try testing.expectEqual(.text, @as(ast.NodeType, txt_node.*));
//     }
//
//     {
//         const child = list_node.list.children[1];
//         try testing.expectEqual(.list_item, @as(ast.NodeType, child.*));
//         try testing.expectEqual(true, child.list_item.spread);
//         try testing.expectEqual(1, child.list_item.children.len);
//
//         const txt_node = child.list_item.children[0];
//         try testing.expectEqual(.text, @as(ast.NodeType, txt_node.*));
//     }
// }
//
// test "bullet list match indent" {
//     const md =
//         \\*    First
//         \\
//         \\     Still first!
//         \\
//         \\  No longer in list.
//         \\
//     ;
//
//     const root_node = try parseBlocks(md);
//     defer root_node.deinit(testing.allocator);
//
//     try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
//     try testing.expectEqual(2, root_node.root.children.len);
//
//     const list_node = root_node.root.children[0];
//     try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
//     try testing.expectEqual(false, list_node.list.ordered);
//     try testing.expectEqual(false, list_node.list.spread);
//     try testing.expectEqual(1, list_node.list.children.len);
//
//     const list_item_node = list_node.list.children[0];
//     try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node.*));
//     try testing.expectEqual(true, list_item_node.list_item.spread);
//     try testing.expectEqual(2, list_item_node.list_item.children.len);
//
//     const item_p_node_1 = list_item_node.list_item.children[0];
//     try testing.expectEqual(.paragraph, @as(ast.NodeType, item_p_node_1.*));
//     try testing.expectEqualStrings(
//         "First",
//         item_p_node_1.paragraph.children[0].text.value,
//     );
//
//     const item_p_node_2 = list_item_node.list_item.children[1];
//     try testing.expectEqual(.paragraph, @as(ast.NodeType, item_p_node_2.*));
//     try testing.expectEqualStrings(
//         "Still first!",
//         item_p_node_2.paragraph.children[0].text.value,
//     );
//
//     const p_node = root_node.root.children[1];
//     try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));
// }
//
// test "simple ordered list" {
//     const md =
//         \\1. First
//         \\2. Second
//         \\3. Third
//         \\
//     ;
//
//     const root_node = try parseBlocks(md);
//     defer root_node.deinit(testing.allocator);
//
//     try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
//     try testing.expectEqual(1, root_node.root.children.len);
//
//     const list_node = root_node.root.children[0];
//     try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
//     try testing.expectEqual(true, list_node.list.ordered);
//     try testing.expectEqual(false, list_node.list.spread);
//     try testing.expectEqual(3, list_node.list.children.len);
//     try testing.expectEqual(1, list_node.list.start);
//
//     for (0..3) |i| {
//         const list_item_node = list_node.list.children[i];
//         try testing.expectEqual(
//             .list_item,
//             @as(ast.NodeType, list_item_node.*),
//         );
//         try testing.expectEqual(false, list_item_node.list_item.spread);
//         try testing.expectEqual(1, list_item_node.list_item.children.len);
//
//         const txt_node = list_item_node.list_item.children[0];
//         try testing.expectEqual(.text, @as(ast.NodeType, txt_node.*));
//     }
// }
//
// test "ordered list different start" {
//     const md =
//         \\2. First
//         \\3. Second
//         \\4. Third
//         \\
//     ;
//
//     const root_node = try parseBlocks(md);
//     defer root_node.deinit(testing.allocator);
//
//     try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
//     try testing.expectEqual(1, root_node.root.children.len);
//
//     const list_node = root_node.root.children[0];
//     try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
//     try testing.expectEqual(true, list_node.list.ordered);
//     try testing.expectEqual(false, list_node.list.spread);
//     try testing.expectEqual(3, list_node.list.children.len);
//     try testing.expectEqual(2, list_node.list.start);
// }
//
// test "ordered list invalid number not at start" {
//     const md =
//         \\1. First
//         \\1234567890. Second
//         \\3. Third
//         \\
//     ;
//
//     const root_node = try parseBlocks(md);
//     defer root_node.deinit(testing.allocator);
//
//     try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
//     try testing.expect(root_node.root.children.len != 1);
//
//     // TODO: Expand this test when we can handle lazy continuation lines in
//     // list items.
// }
//
// test "ordered list spread item" {
//     const md =
//         \\1. This contains a blank line.
//         \\
//         \\   Blank line above.
//         \\2. Second
//         \\
//     ;
//
//     const root_node = try parseBlocks(md);
//     defer root_node.deinit(testing.allocator);
//
//     try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
//     try testing.expectEqual(1, root_node.root.children.len);
//
//     const list_node = root_node.root.children[0];
//     try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
//     try testing.expectEqual(true, list_node.list.ordered);
//     try testing.expectEqual(false, list_node.list.spread);
//     try testing.expectEqual(2, list_node.list.children.len);
//
//     const list_item_node_1 = list_node.list.children[0];
//     try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_1.*));
//     try testing.expectEqual(true, list_item_node_1.list_item.spread);
//     try testing.expectEqual(2, list_item_node_1.list_item.children.len);
//
//     const list_item_node_2 = list_node.list.children[1];
//     try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_2.*));
//     try testing.expectEqual(true, list_item_node_2.list_item.spread);
//
//     const p_node_2 = list_item_node_2.list_item.children[0];
//     try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node_2.*));
//     try testing.expectEqual(1, p_node_2.paragraph.children.len);
//     const txt_node_2 = p_node_2.paragraph.children[0];
//     try testing.expectEqual(.text, @as(ast.NodeType, txt_node_2.*));
//     try testing.expectEqualStrings("Second", txt_node_2.text.value);
// }
//
// test "ordered list spread list" {
//     const md =
//         \\1. First
//         \\
//         \\2. Second
//         \\
//     ;
//
//     const root_node = try parseBlocks(md);
//     defer root_node.deinit(testing.allocator);
//
//     try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
//     try testing.expectEqual(1, root_node.root.children.len);
//
//     const list_node = root_node.root.children[0];
//     try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
//     try testing.expectEqual(true, list_node.list.ordered);
//     try testing.expectEqual(false, list_node.list.spread);
//     try testing.expectEqual(2, list_node.list.children.len);
//
//     const list_item_node_1 = list_node.list.children[0];
//     try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_1.*));
//     try testing.expectEqual(true, list_item_node_1.list_item.spread);
//
//     const p_node_1 = list_item_node_1.list_item.children[0];
//     try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node_1.*));
//     try testing.expectEqual(1, p_node_1.paragraph.children.len);
//     const txt_node_1 = p_node_1.paragraph.children[0];
//     try testing.expectEqual(.text, @as(ast.NodeType, txt_node_1.*));
//     try testing.expectEqualStrings("First", txt_node_1.text.value);
//
//     const list_item_node_2 = list_node.list.children[1];
//     try testing.expectEqual(.list_item, @as(ast.NodeType, list_item_node_2.*));
//     try testing.expectEqual(true, list_item_node_2.list_item.spread);
//
//     const p_node_2 = list_item_node_2.list_item.children[0];
//     try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node_2.*));
//     try testing.expectEqual(1, p_node_2.paragraph.children.len);
//     const txt_node_2 = p_node_2.paragraph.children[0];
//     try testing.expectEqual(.text, @as(ast.NodeType, txt_node_2.*));
//     try testing.expectEqualStrings("Second", txt_node_2.text.value);
// }
//
// // This list should be tight. The trailing blank lines are after the list.
// test "ordered list trailing blank lines" {
//     const md =
//         \\1. First
//         \\2. Second
//         \\
//         \\This is a paragraph.
//         \\
//     ;
//
//     const root_node = try parseBlocks(md);
//     defer root_node.deinit(testing.allocator);
//
//     try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
//     try testing.expectEqual(2, root_node.root.children.len);
//
//     const list_node = root_node.root.children[0];
//     try testing.expectEqual(.list, @as(ast.NodeType, list_node.*));
//     try testing.expectEqual(false, list_node.list.spread);
//     try testing.expectEqual(2, list_node.list.children.len);
//
//     {
//         const child = list_node.list.children[0];
//         try testing.expectEqual(.list_item, @as(ast.NodeType, child.*));
//         try testing.expectEqual(false, child.list_item.spread);
//         try testing.expectEqual(1, child.list_item.children.len);
//
//         const txt_node = child.list_item.children[0];
//         try testing.expectEqual(.text, @as(ast.NodeType, txt_node.*));
//     }
//
//     {
//         const child = list_node.list.children[1];
//         try testing.expectEqual(.list_item, @as(ast.NodeType, child.*));
//         try testing.expectEqual(true, child.list_item.spread);
//         try testing.expectEqual(1, child.list_item.children.len);
//
//         const txt_node = child.list_item.children[0];
//         try testing.expectEqual(.text, @as(ast.NodeType, txt_node.*));
//     }
// }
//
// /// Bullet list container.
// ///
// /// As of version 0.0.5 of the MyST spec, if a list is loose according to the
// /// CommonMark definition of "loose", then all list items must have `spread =
// /// true` while the containing list always has `spread = false`.
// const BulletList = struct {
//     children: ArrayList(*ast.Node),
//     marker_token: BlockToken,
//
//     const OpenResult = struct {
//         marker_token: BlockToken,
//     };
//
//     fn init(marker_token: BlockToken) BulletList {
//         // TODO: Use enum subset?
//         std.debug.assert(marker_token.token_type == .star or
//             marker_token.token_type == .hyphen or
//             marker_token.token_type == .plus);
//
//         return .{
//             .children = .empty,
//             .marker_token = marker_token,
//         };
//     }
//
//     /// Returns the marker token if the next sequence of tokens can open a
//     /// bullet list. Returns null otherwise.
//     fn canOpen(
//         scratch: Allocator,
//         it: *TokenIterator(BlockTokenType),
//     ) !?OpenResult {
//         const checkpoint_index = it.checkpoint();
//         defer it.backtrack(checkpoint_index);
//
//         _ = try it.consumeWhitespaceUpTo(scratch, 3);
//         const marker_token = try it.consume(
//             scratch,
//             &.{ .hyphen, .star, .plus },
//         ) orelse
//             return null;
//         _ = try it.consume(scratch, &.{.whitespace}) orelse return null;
//
//         return .{
//             .marker_token = marker_token,
//         };
//     }
//
//     fn next(
//         self: *BulletList,
//         scratch: Allocator,
//         it: *TokenIterator(BlockTokenType),
//         interruptible: bool,
//     ) !NextResult {
//         // If the leaf parser is parsing something that cannot be interrupted,
//         // then we should be in a list item or different kind of container.
//         std.debug.assert(interruptible == true);
//
//         const eof: NextResult = .{
//             .token = null,
//             .line_state = .start,
//         };
//
//         if (try BulletListItem.canOpen(
//             scratch,
//             it,
//             self.marker_token.token_type,
//         )) |_| {
//             // Open new bullet list item
//             return .{
//                 .token = null,
//                 .line_state = .start,
//                 .container = .{
//                     .bullet_list_item = BulletListItem.init(
//                         self.marker_token,
//                     ),
//                 },
//             };
//         }
//
//         const token = try it.peek(scratch) orelse return eof;
//         switch (token.token_type) {
//             .star, .hyphen, .plus => {
//                 // It's the start of a new list, so close the container
//                 return .{
//                     .token = null,
//                     .line_state = .start,
//                 };
//             },
//             else => {
//                 // end of list
//                 _ = try it.consume(scratch, &.{token.token_type});
//                 return .{
//                     .token = token,
//                     .send_close = true,
//                     .line_state = .trailing,
//                 };
//             },
//         }
//     }
//
//     fn toNode(self: BulletList, alloc: Allocator) !*ast.Node {
//         handleListTightness(alloc, self.children.items);
//
//         const children = try alloc.dupe(*ast.Node, self.children.items);
//         errdefer alloc.free(children);
//
//         const node = try alloc.create(ast.Node);
//         node.* = .{
//             .list = .{
//                 .children = children,
//                 .ordered = false,
//                 .spread = false,
//             },
//         };
//         return node;
//     }
// };
//
// /// Bullet list item container.
// const BulletListItem = struct {
//     children: ArrayList(*ast.Node),
//     marker_token: BlockToken,
//     indent: usize,
//     saw_blank_line: bool,
//
//     const OpenResult = struct {};
//
//     fn init(marker_token: BlockToken) BulletListItem {
//         return .{
//             .children = .empty,
//             .marker_token = marker_token,
//             .indent = 0,
//             .saw_blank_line = false,
//         };
//     }
//
//     /// Returns an empty open result if the next tokens can open a list item,
//     /// otherwise null.
//     fn canOpen(
//         scratch: Allocator,
//         it: *TokenIterator(BlockTokenType),
//         marker_token_type: BlockTokenType,
//     ) !?OpenResult {
//         const checkpoint_index = it.checkpoint();
//         defer it.backtrack(checkpoint_index);
//
//         _ = try it.consumeWhitespaceUpTo(scratch, 3);
//         _ = try it.consume(scratch, &.{marker_token_type}) orelse
//             return null;
//         _ = try it.consume(scratch, &.{.whitespace}) orelse return null;
//         return .{};
//     }
//
//     fn next(
//         self: *BulletListItem,
//         scratch: Allocator,
//         it: *TokenIterator(BlockTokenType),
//         interruptible: bool,
//     ) !NextResult {
//         const end: NextResult = .{
//             .token = null,
//             .line_state = .start,
//         };
//
//         if (self.indent == 0) {
//             // Handle first line
//             const leading_ws_len = try it.consumeWhitespaceUpTo(scratch, 3);
//             _ = try it.consume(
//                 scratch,
//                 &.{self.marker_token.token_type},
//             ) orelse
//                 @panic("bullet list item created with wrong marker token");
//             const following_ws_len = try consumeWhitespaceUpTo(scratch, it, 4);
//             self.indent = leading_ws_len + 1 + following_ws_len;
//         } else {
//             const start_token = try it.peek(scratch) orelse return end;
//             switch (start_token.token_type) {
//                 .whitespace => {
//                     if (start_token.lexeme.len < self.indent) {
//                         // Not indented enough; end list item
//                         return end;
//                     }
//
//                     _ = try it.consume(scratch, &.{.whitespace});
//                 },
//                 .newline => {
//                     // Blank line; allowed in list item
//                     _ = try it.consume(scratch, &.{.newline});
//                     self.saw_blank_line = true;
//                     return .{
//                         .token = start_token,
//                         .line_state = .start,
//                     };
//                 },
//                 else => {
//                     // End list item
//                     return end;
//                 },
//             }
//         }
//
//         const token = try it.peek(scratch) orelse return end;
//         switch (token.token_type) {
//             .star, .hyphen, .plus => {
//                 if (!interruptible) {
//                     // Just pass on the token
//                     return .{
//                         .token = token,
//                         .line_state = .trailing,
//                     };
//                 }
//
//                 // Can't yet nest lists
//                 return end;
//             },
//             .newline => {
//                 _ = try it.consume(scratch, &.{.newline});
//                 self.saw_blank_line = true;
//                 return .{
//                     .token = token,
//                     .line_state = .start,
//                 };
//             },
//             else => {
//                 _ = try it.consume(scratch, &.{token.token_type});
//                 return .{
//                     .token = token,
//                     .line_state = .trailing,
//                 };
//             },
//         }
//     }
//
//     fn toNode(self: BulletListItem, alloc: Allocator) !*ast.Node {
//         const children = try alloc.dupe(*ast.Node, self.children.items);
//         errdefer alloc.free(children);
//
//         const node = try alloc.create(ast.Node);
//         node.* = .{
//             .list_item = .{
//                 .children = children,
//                 .spread = self.saw_blank_line,
//             },
//         };
//         return node;
//     }
// };
//
// /// Container for a numbered list.
// ///
// /// As of version 0.0.5 of the MyST spec, if a list is loose according to the
// /// CommonMark definition of "loose", then all list items must have `spread =
// /// true` while the containing list always has `spread = false`.
// const OrderedList = struct {
//     children: ArrayList(*ast.Node),
//     marker_token: BlockToken,
//     start: u32,
//
//     const OpenResult = struct {
//         marker_token: BlockToken,
//         start: u32,
//     };
//
//     fn init(marker_token: BlockToken, start: u32) OrderedList {
//         std.debug.assert(marker_token.token_type == .period or
//             marker_token.token_type == .r_paren);
//
//         return .{
//             .children = .empty,
//             .marker_token = marker_token,
//             .start = start,
//         };
//     }
//
//     // Returns the ordered list container that would result if the next
//     // sequence of tokens opens an ordered list.
//     //
//     // Returns null otherwise.
//     fn canOpen(
//         scratch: Allocator,
//         it: *TokenIterator(BlockTokenType),
//     ) !?OpenResult {
//         const checkpoint_index = it.checkpoint();
//         defer it.backtrack(checkpoint_index);
//
//         _ = try it.consumeWhitespaceUpTo(scratch, 3);
//         const numeral_token = try it.consume(scratch, &.{.text}) orelse
//             return null;
//         const marker_token = try it.consume(
//             scratch,
//             &.{ .period, .r_paren },
//         ) orelse return null;
//         _ = try it.consume(scratch, &.{.whitespace}) orelse return null;
//
//         const start = parseOrderedListNumber(
//             numeral_token.lexeme,
//         ) catch return null;
//
//         return .{
//             .marker_token = marker_token,
//             .start = start,
//         };
//     }
//
//     fn next(
//         self: *OrderedList,
//         scratch: Allocator,
//         it: *TokenIterator(BlockTokenType),
//         interruptible: bool,
//     ) !NextResult {
//         _ = self;
//
//         // If the leaf parser is parsing something that cannot be interrupted,
//         // then we should be in a list item or different kind of container.
//         std.debug.assert(interruptible == true);
//
//         const eof: NextResult = .{
//             .token = null,
//             .line_state = .start,
//         };
//
//         if (try OrderedListItem.canOpen(scratch, it)) |_| {
//             // Open new ordered list item
//             return .{
//                 .token = null,
//                 .line_state = .start,
//                 .container = .{
//                     .ordered_list_item = OrderedListItem.init(),
//                 },
//             };
//         }
//
//         const token = try it.peek(scratch) orelse return eof;
//         switch (token.token_type) {
//             .star, .hyphen, .plus => {
//                 // It's the start of a new bullet list, so close the container
//                 return .{
//                     .token = null,
//                     .line_state = .start,
//                 };
//             },
//             else => {
//                 // end of list
//                 _ = try it.consume(scratch, &.{token.token_type});
//                 return .{
//                     .token = token,
//                     .send_close = true,
//                     .line_state = .trailing,
//                 };
//             },
//         }
//     }
//
//     fn toNode(self: OrderedList, alloc: Allocator) !*ast.Node {
//         handleListTightness(alloc, self.children.items);
//
//         const children = try alloc.dupe(*ast.Node, self.children.items);
//         errdefer alloc.free(children);
//
//         const node = try alloc.create(ast.Node);
//         node.* = .{
//             .list = .{
//                 .children = children,
//                 .ordered = true,
//                 .spread = false,
//                 .start = self.start,
//             },
//         };
//         return node;
//     }
// };
//
// const OrderedListItem = struct {
//     children: ArrayList(*ast.Node),
//     indent: usize,
//     saw_blank_line: bool,
//
//     const OpenResult = struct {};
//
//     fn init() OrderedListItem {
//         return .{
//             .children = .empty,
//             .indent = 0,
//             .saw_blank_line = false,
//         };
//     }
//
//     fn canOpen(
//         scratch: Allocator,
//         it: *TokenIterator(BlockTokenType),
//     ) !?OpenResult {
//         const checkpoint_index = it.checkpoint();
//         defer it.backtrack(checkpoint_index);
//
//         _ = try it.consumeWhitespaceUpTo(scratch, 3);
//         const numeral_token = try it.consume(scratch, &.{.text}) orelse
//             return null;
//         _ = try it.consume(
//             scratch,
//             &.{ .period, .r_paren },
//         ) orelse return null;
//         _ = try it.consume(scratch, &.{.whitespace}) orelse return null;
//
//         _ = parseOrderedListNumber(numeral_token.lexeme) catch return null;
//         return .{};
//     }
//
//     fn next(
//         self: *OrderedListItem,
//         scratch: Allocator,
//         it: *TokenIterator(BlockTokenType),
//         interruptible: bool,
//     ) !NextResult {
//         const eof: NextResult = .{
//             .token = null,
//             .line_state = .start,
//         };
//
//         if (self.indent == 0) {
//             // Handle first line
//             const leading_ws_len = try it.consumeWhitespaceUpTo(scratch, 3);
//             const text_token = try it.consume(scratch, &.{.text}) orelse
//                 unreachable;
//             _ = try it.consume(scratch, &.{ .period, .r_paren }) orelse
//                 unreachable;
//             const following_ws_len = try consumeWhitespaceUpTo(scratch, it, 4);
//             self.indent = leading_ws_len + text_token.lexeme.len + 1 +
//                 following_ws_len;
//         } else {
//             const start_token = try it.peek(scratch) orelse return eof;
//             switch (start_token.token_type) {
//                 .whitespace => {
//                     if (start_token.lexeme.len < self.indent) {
//                         // Not indented enough; end list item
//                         return .{
//                             .token = null,
//                             .line_state = .start,
//                         };
//                     }
//
//                     _ = try it.consume(scratch, &.{.whitespace});
//                 },
//                 .newline => {
//                     // Blank line; allowed in list item
//                     _ = try it.consume(scratch, &.{.newline});
//                     self.saw_blank_line = true;
//                     return .{
//                         .token = start_token,
//                         .line_state = .start,
//                     };
//                 },
//                 else => {
//                     // End list item
//                     return .{
//                         .token = null,
//                         .line_state = .start,
//                     };
//                 },
//             }
//         }
//
//         const token = try it.peek(scratch) orelse return eof;
//         switch (token.token_type) {
//             .star, .hyphen, .plus => {
//                 if (!interruptible) {
//                     // Just pass on the token
//                     return .{
//                         .token = token,
//                         .line_state = .trailing,
//                     };
//                 }
//
//                 // Can't yet nest lists
//                 return .{
//                     .token = null,
//                     .line_state = .start,
//                 };
//             },
//             .newline => {
//                 // Blank line; allowed in list item
//                 _ = try it.consume(scratch, &.{.newline});
//                 self.saw_blank_line = true;
//                 return .{
//                     .token = token,
//                     .line_state = .start,
//                 };
//             },
//             else => {
//                 _ = try it.consume(scratch, &.{token.token_type});
//                 return .{
//                     .token = token,
//                     .line_state = .trailing,
//                 };
//             },
//         }
//     }
//
//     fn toNode(self: OrderedListItem, alloc: Allocator) !*ast.Node {
//         const children = try alloc.dupe(*ast.Node, self.children.items);
//         errdefer alloc.free(children);
//
//         const node = try alloc.create(ast.Node);
//         node.* = .{
//             .list_item = .{
//                 .children = children,
//                 .spread = self.saw_blank_line,
//             },
//         };
//         return node;
//     }
// };
//

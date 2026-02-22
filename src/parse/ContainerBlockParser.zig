//! Parser in the first parsing stage that handles container block parsing.
//!
//! Control flow is a little wonky:
//! * This parser does not directly read from the given tokenizer.
//! * Instead, it sets up a token stream for a LeafBlockParser.
//! * As the LeafBlockParser advances, this parser intercepts tokens that are
//!   meaningful for container-level parsing.
//! * The state of this parser is adjusted so that the parsed leaf blocks are
//!   added to the appropriate container.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const ast = @import("ast.zig");
const BlockToken = @import("../lex/tokens.zig").BlockToken;
const BlockTokenType = @import("../lex/tokens.zig").BlockTokenType;
const BlockTokenizer = @import("../lex/BlockTokenizer.zig");
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
        tokenizer: *BlockTokenizer,
        line_state: LineState,
    ) !NextResult {
        // This case is the same for all containers, so handle it here
        if (line_state == .trailing) {
            const token = try tokenizer.next(scratch) orelse return .{
                .token = null,
                .line_state = .start,
            };

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
                return try payload.next(scratch, tokenizer);
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
        tokenizer: *BlockTokenizer,
    ) !NextResult {
        _ = self;

        const token = try tokenizer.next(scratch) orelse return .{
            .token = null,
            .line_state = .start,
        };
        switch (token.token_type) {
            .r_angle_bracket => {
                const next_token = try tokenizer.next(scratch);
                return .{
                    .token = next_token,
                    .line_state = .trailing,
                    .container = .{
                        .blockquote = OpenBlockquote.init(1),
                    },
                };
            },
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
        tokenizer: *BlockTokenizer,
    ) !NextResult {
        _ = self;

        const token = try tokenizer.next(scratch) orelse return .{
            .token = null,
            .line_state = .start,
        };
        switch (token.token_type) {
            .r_angle_bracket => {
                const next_token = try tokenizer.next(scratch);
                return .{
                    .token = next_token,
                    .line_state = .trailing,
                };
            },
            .newline => {
                return .{
                    .token = token,
                    .send_close = true,
                    .line_state = .start,
                };
            },
            else => {
                return .{
                    .token = token,
                    .send_close = true,
                    .line_state = .trailing,
                };
            },
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

tokenizer: *BlockTokenizer,
container_stack: ArrayList(OpenContainer),
line_state: LineState,
saved_next_token: ?BlockToken,

const Self = @This();

pub fn init(tokenizer: *BlockTokenizer) Self {
    return .{
        .tokenizer = tokenizer,
        .container_stack = .empty,
        .line_state = .start,
        .saved_next_token = null,
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

    var it = self.iterator();
    for (0..util.safety.loop_bound) |_| {
        var leaf_parser: LeafBlockParser = .{ .it = &it };
        const nodes = try leaf_parser.parse(alloc, scratch, link_defs);
        errdefer {
            for (nodes) |node| {
                node.deinit(alloc);
            }
        }
        defer alloc.free(nodes);

        for (nodes) |node| {
            try self.top().add(scratch, node);
        }

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

fn iterator(self: *Self) TokenIterator(BlockTokenType) {
    return TokenIterator(BlockTokenType).init(self, &next);
}

/// Called by LeafBlockParser to get next token.
fn next(ctx: *anyopaque, scratch: Allocator) Error!?BlockToken {
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (self.saved_next_token) |token| {
        self.saved_next_token = null;
        return token;
    }

    const result = try self.top().next(
        scratch,
        self.tokenizer,
        self.line_state,
    );

    self.line_state = result.line_state;
    if (result.container) |container| {
        try self.container_stack.append(scratch, container);
    }

    if (result.send_close) {
        self.saved_next_token = result.token;
        return .{ .token_type = .close };
    } else {
        return result.token;
    }
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

fn parseBlocks(md: []const u8) !*ast.Node {
    var reader: Io.Reader = .fixed(md);
    var line_buf: [512]u8 = undefined;
    const line_reader: LineReader = .{ .in = &reader, .buf = &line_buf };
    var tokenizer = BlockTokenizer.init(line_reader);
    var parser = Self.init(&tokenizer);

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

//test "blockquote after paragraph" {
//    const md =
//        \\This is a paragraph outside the blockquote.
//        \\>This is a paragraph inside the blockquote.
//        \\
//    ;
//
//    const root = try parseBlocks(md);
//    defer root.deinit(testing.allocator);
//
//    try testing.expectEqual(.root, @as(ast.NodeType, root.*));
//    try testing.expectEqual(2, root.root.children.len);
//
//    const p = root.root.children[0];
//    try testing.expectEqual(.paragraph, @as(ast.NodeType, p.*));
//
//    const bq = root.root.children[1];
//    try testing.expectEqual(.blockquote, @as(ast.NodeType, bq.*));
//    try testing.expectEqual(1, bq.blockquote.children.len);
//    {
//        const bq_p = bq.blockquote.children[0];
//        try testing.expectEqual(.paragraph, @as(ast.NodeType, bq_p.*));
//
//        const bq_txt = bq_p.paragraph.children[0];
//        try testing.expectEqual(.text, @as(ast.NodeType, bq_txt.*));
//        try testing.expectEqualStrings(
//            "This is a paragraph inside the blockquote.",
//            bq_txt.text.value,
//        );
//    }
//}

// test "double blockquote" {
//     const md =
//         \\>> This is a paragraph. It goes on for
//         \\>> multiple lines.
//         \\
//     ;
// }

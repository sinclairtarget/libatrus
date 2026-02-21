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
const Io = std.Io;

const ast = @import("ast.zig");
const BlockToken = @import("../lex/tokens.zig").BlockToken;
const BlockTokenizer = @import("../lex/BlockTokenizer.zig");
const LeafBlockParser = @import("LeafBlockParser.zig");
const LinkDefMap = @import("link_defs.zig").LinkDefMap;
const TokenIterator = @import("../lex/iterator.zig").TokenIterator;

const Error = error{
    LineTooLong,
    ReadFailed,
    WriteFailed,
} || Allocator.Error;

tokenizer: *BlockTokenizer,

const Self = @This();

pub fn init(tokenizer: *BlockTokenizer) Self {
    return .{
        .tokenizer = tokenizer,
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
    var leaf_parser = LeafBlockParser.init(self.iterator());
    const nodes = try leaf_parser.parse(alloc, scratch, link_defs);
    errdefer {
        for (nodes) |node| {
            node.deinit(alloc);
        }
        alloc.free(nodes);
    }

    const root = try alloc.create(ast.Node);
    root.* = .{
        .root = .{
            .children = nodes,
        },
    };
    return root;
}

fn iterator(self: *Self) TokenIterator(BlockToken) {
    return .{
        .ctx = self,
        .nextFn = &next,
    };
}

fn next(ctx: *anyopaque, scratch: Allocator) Error!?BlockToken {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return try self.tokenizer.next(scratch);
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
    const p1 = root.root.children[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p1.*));
}

// test "blockquote" {
//     const md =
//         \\> This is a paragraph. It goes on for
//         \\> multiple lines.
//         \\
//     ;
// }
//
// test "double blockquote" {
//     const md =
//         \\>> This is a paragraph. It goes on for
//         \\>> multiple lines.
//         \\
//     ;
// }

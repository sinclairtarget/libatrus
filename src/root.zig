//! libatrus parses MyST-flavored markdown into the MyST AST.
//!
//! It can also "render" the AST to JSON or HTML.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;

const LineReader = @import("lex/LineReader.zig");
const BlockTokenizer = @import("lex/BlockTokenizer.zig");
const BlockParser = @import("parse/BlockParser.zig");
const InlineParser = @import("parse/InlineParser.zig");
const transform = @import("transform/transform.zig");
const json = @import("render/json.zig");
const html = @import("render/html.zig");

const logger = @import("logging.zig").logger;

// Maximum allowed length for a single line in a Markdown document.
const max_line_len = 4096; // bytes

// The below `pub` variable and function declarations define the public
// interface of libatrus.

pub const ast = @import("parse/ast.zig");
pub const version = config.version;

pub const ParseError = error{
    ReadFailed,
    LineTooLong,
    UnrecognizedBlockToken,
} || InlineParser.Error || Allocator.Error || Io.Writer.Error;

pub const ParseOptions = struct {
    parse_level: enum {
        block, // Only parse blocks
        pre,   // Parse blocks and inline content
        post,  // Resolve internal references, finalize AST etc.
    } = .post,
};

/// Parses the input string (containing MyST markdown) into a MyST AST. Returns
/// a pointer to the root node.
///
/// The caller is responsible for freeing the memory used by the AST nodes.
pub fn parse(
    alloc: Allocator,
    in: []const u8,
    options: ParseOptions,
) ParseError!*ast.Node {
    var reader: Io.Reader = .fixed(in);

    var line_buf: [max_line_len]u8 = undefined;
    const line_reader: LineReader = .{ .in = &reader, .buf = &line_buf };

    // first stage; parse into blocks
    logger.debug("Beginning block parsing...", .{});
    var block_tokenizer = BlockTokenizer.init(line_reader);
    var block_parser = BlockParser.init(&block_tokenizer);
    var root = try block_parser.parse(alloc);
    if (options.parse_level == .block) {
        return root;
    }

    errdefer root.deinit(alloc);

    // second stage; parse inline elements
    logger.debug("Beginning inline parsing...", .{});
    root = try transform.parseInline(alloc, root);
    if (options.parse_level == .pre) {
        return root;
    }

    // third stage; MyST-specific transforms
    logger.debug("Beginning post-processing...", .{});
    root = try transform.postProcess(alloc, root);
    return root;
}

/// Parses the input string (containing a MyST AST in JSON form) into a MYST
/// AST. Returns a pointer to the root node.
///
/// The caller is responsible for freeing the memory used by the AST nodes.
pub fn parseJSON(alloc: Allocator, in: []const u8) !*ast.Node {
    _ = alloc;
    _ = in;
    return error.NotImplemented;
}

pub const JSONOptions = json.Options;

pub const RenderJSONError = error{
    WriteFailed,
    OutOfMemory,
};

/// Renders the AST as JSON, writing to a string.
///
/// The caller is responsible for freeing the returned string.
pub fn renderJSONString(
    alloc: Allocator,
    root: *ast.Node,
    options: JSONOptions,
) RenderJSONError![]const u8 {
    var buf = Io.Writer.Allocating.init(alloc);
    try renderJSON(&buf.writer, root, options);
    return buf.toOwnedSlice();
}

/// Renders the AST as JSON, writing to the given writer.
pub fn renderJSON(
    writer: *Io.Writer,
    root: *ast.Node,
    options: JSONOptions,
) RenderJSONError!void {
    try json.render(writer, root, options);
}

pub const RenderHTMLError = error{
    WriteFailed,
    OutOfMemory,
    NotPostProcessed,
};

/// Renders the AST as HTML, writing to a string.
///
/// The caller is responsible for freeing the returned string.
pub fn renderHTMLString(
    alloc: Allocator,
    root: *ast.Node,
) RenderHTMLError![]const u8 {
    var buf = Io.Writer.Allocating.init(alloc);
    try renderHTML(&buf.writer, root);
    return buf.toOwnedSlice();
}

/// Renders the AST as HTML, writing to the given writer.
pub fn renderHTML(
    writer: *Io.Writer,
    root: *ast.Node,
) RenderHTMLError!void {
    if (!root.root.is_post_processed) {
        return RenderHTMLError.NotPostProcessed;
    }

    try html.render(root, writer);
}

// Tokenization is part of the public interface of the library only in debug
// mode.
pub const lex =
    if (builtin.mode == .Debug)
        struct {
            pub const BlockTokenizer = @import("lex/BlockTokenizer.zig");
            pub const InlineTokenizer = @import("lex/InlineTokenizer.zig");
            pub const LineReader = @import("lex/LineReader.zig");
        }
    else
        @compileError("tokenziation is only supported in the debug release mode");

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
test {
    // Ensures all unit tests are reachable even when filtering only for tests
    // in imported structs/namespaces and not in this file.
    _ = @import("lex/LineReader.zig");
    _ = @import("lex/BlockTokenizer.zig");
    _ = @import("lex/InlineTokenizer.zig");
    _ = @import("parse/BlockParser.zig");
    _ = @import("parse/InlineParser.zig");
}

test renderHTMLString {
    const md =
        \\# I am a heading
        \\I am a paragraph containing *emphasis*.
        \\
    ;
    const expected =
        \\<h1>I am a heading</h1>
        \\<p>I am a paragraph containing <em>emphasis</em>.</p>
        \\
    ;

    const root = try parse(std.testing.allocator, md, .{});
    defer root.deinit(std.testing.allocator);

    const result = try renderHTMLString(std.testing.allocator, root);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "emphasis" {
    const md =
        \\I am a paragraph containing *emphasis*.
        \\
    ;
    const expected =
        \\<p>I am a paragraph containing <em>emphasis</em>.</p>
        \\
    ;

    const root = try parse(std.testing.allocator, md, .{});
    defer root.deinit(std.testing.allocator);

    const result = try renderHTMLString(std.testing.allocator, root);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

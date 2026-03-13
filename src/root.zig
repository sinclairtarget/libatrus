//! libatrus parses MyST-flavored markdown into the MyST AST.
//!
//! It can also "render" the AST to JSON or HTML.
//!
//! This file defines the Zig interface of libatrus. For the C-ABI-compatible
//! interface, see atrus.h.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const ArrayList = std.ArrayList;
const time = std.time;

const LineReader = @import("lex/LineReader.zig");
const BlockTokenizer = @import("lex/BlockTokenizer.zig");
const ContainerBlockParser = @import("parse/ContainerBlockParser.zig");
const LinkDefMap = @import("parse/link_defs.zig").LinkDefMap;
const InlineParser = @import("parse/InlineParser.zig");
const transform = @import("transform/transform.zig");
const json = @import("render/json.zig");
const html = @import("render/html.zig");

const logger = @import("logging.zig").logger;

// Maximum allowed length for a single line in a Markdown document.
// TODO: Do we need this?
const max_line_len = 4096; // bytes

// The below `pub` variable and function declarations define the public
// interface of libatrus.

pub const version = config.version;
pub const ast = @import("ast.zig");

pub const ParseError = error{
    ReadFailed,
    LineTooLong,
    UnrecognizedBlockToken,
} || InlineParser.Error || Allocator.Error || Io.Writer.Error;

pub const ParseOptions = extern struct {
    parse_level: enum(c_uint) {
        /// Only parse blocks.
        block,
        /// Parse blocks and inline content.
        pre,
        /// Parse everything, but also resolve internal references, finalize
        /// AST etc.
        post,
    } = .post,
};

/// Parses the input (containing MyST markdown) into a MyST AST. Returns
/// a pointer to the root node.
///
/// The caller is responsible for freeing the memory used by the AST nodes.
pub fn parse(
    alloc: Allocator,
    in: *Io.Reader,
    options: ParseOptions,
) ParseError!*ast.Node {
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();

    var line_buf: [max_line_len]u8 = undefined;
    const line_reader: LineReader = .{ .in = in, .buf = &line_buf };

    var link_defs: LinkDefMap = .empty;
    defer link_defs.deinit(alloc);

    // first pass; parse into blocks
    var timer = time.Timer.start() catch { @panic("timer unsupported"); };
    logger.debug("Beginning block parsing...", .{});
    var block_tokenizer = BlockTokenizer.init(line_reader);
    var iterator = block_tokenizer.iterator();
    var block_parser = ContainerBlockParser.init(&iterator);
    var root = try block_parser.parse(alloc, scratch, &link_defs);
    logger.debug("Done in {D}.", .{timer.read()});

    if (options.parse_level == .block) {
        return root;
    }

    errdefer root.deinit(alloc);
    _ = arena.reset(.retain_capacity);

    // second pass; parse inline elements
    timer.reset();
    logger.debug("Beginning inline parsing...", .{});
    root = try transform.parseInlines(alloc, &arena, root, link_defs);
    logger.debug("Done in {D}.", .{timer.read()});

    if (options.parse_level == .pre) {
        return root;
    }

    _ = arena.reset(.retain_capacity);

    // third pass; MyST-specific transforms
    timer.reset();
    logger.debug("Beginning post-processing...", .{});
    root = try transform.postProcess(alloc, root);
    logger.debug("Done in {D}.", .{timer.read()});

    return root;
}

pub const HTMLOptions = struct {}; // No options (yet!)

pub const RenderHTMLError = error{
    WriteFailed,
    OutOfMemory,
    NotPostProcessed,
};

/// Renders the AST as HTML, writing to the given writer.
pub fn renderHTML(
    root: *ast.Node,
    out: *Io.Writer,
    options: HTMLOptions,
) RenderHTMLError!void {
    _ = options;
    try html.render(root, out);
}

pub const JSONOptions = json.Options;

pub const RenderJSONError = error{
    WriteFailed,
    OutOfMemory,
};

/// Renders the AST as JSON, writing to the given writer.
pub fn renderJSON(
    root: *ast.Node,
    out: *Io.Writer,
    options: JSONOptions,
) RenderJSONError!void {
    try json.render(root, out, options);
}

/// Parses the input string (containing a MyST AST in JSON form) into a MYST
/// AST. Returns a pointer to the root node.
///
/// The caller is responsible for freeing the memory used by the AST nodes.
pub fn loadJSON(alloc: Allocator, in: *Io.Reader) !*ast.Node {
    _ = alloc;
    _ = in;
    return error.NotImplemented;
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
        @compileError("tokenziation is only supported in debug release mode");

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

test {
    // Ensures all unit tests are reachable even when filtering only for tests
    // in imported structs/namespaces and not in this file.
    _ = @import("lex/LineReader.zig");
    _ = @import("lex/BlockTokenizer.zig");
    _ = @import("lex/InlineTokenizer.zig");
    _ = @import("parse/LeafBlockParser.zig");
    _ = @import("parse/ContainerBlockParser.zig");
    _ = @import("parse/escape.zig");
    _ = @import("parse/InlineParser.zig");
    _ = @import("cmark/cmark.zig");
    _ = @import("util/util.zig");
}

test parse {
    const md =
        \\# I am a heading
        \\I am a paragraph containing *emphasis*.
        \\
    ;

    var in: Io.Reader = .fixed(md);
    const root = try parse(testing.allocator, &in, .{});
    defer root.deinit(testing.allocator);

    try testing.expectEqual(.root, root.tag);
}

test renderHTML {
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

    var in: Io.Reader = .fixed(md);
    const root = try parse(testing.allocator, &in, .{});
    defer root.deinit(testing.allocator);

    var buf = Io.Writer.Allocating.init(testing.allocator);
    try renderHTML(root, &buf.writer, .{});
    const result = try buf.toOwnedSlice();
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test renderJSON {
    const md =
        \\I am a paragraph containing *emphasis*.
        \\
    ;

    const expected =
        \\{
        \\  "type": "root",
        \\  "children": [
        \\    {
        \\      "type": "block",
        \\      "children": [
        \\        {
        \\          "type": "paragraph",
        \\          "children": [
        \\            {
        \\              "type": "text",
        \\              "value": "I am a paragraph containing "
        \\            },
        \\            {
        \\              "type": "emphasis",
        \\              "children": [
        \\                {
        \\                  "type": "text",
        \\                  "value": "emphasis"
        \\                }
        \\              ]
        \\            },
        \\            {
        \\              "type": "text",
        \\              "value": "."
        \\            }
        \\          ]
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var in: Io.Reader = .fixed(md);
    const root = try parse(testing.allocator, &in, .{});
    defer root.deinit(testing.allocator);

    var buf = Io.Writer.Allocating.init(testing.allocator);
    try renderJSON(root, &buf.writer, .{ .whitespace = .indent_2 });
    const result = try buf.toOwnedSlice();
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test loadJSON {
    const jsonAST =
        \\{
        \\  "type": "root",
        \\  "children": [
        \\    {
        \\      "type": "block",
        \\      "children": [
        \\        {
        \\          "type": "paragraph",
        \\          "children": [
        \\            {
        \\              "type": "text",
        \\              "value": "I am a paragraph containing "
        \\            },
        \\            {
        \\              "type": "emphasis",
        \\              "children": [
        \\                {
        \\                  "type": "text",
        \\                  "value": "emphasis"
        \\                }
        \\              ]
        \\            },
        \\            {
        \\              "type": "text",
        \\              "value": "."
        \\            }
        \\          ]
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var in: Io.Reader = .fixed(jsonAST);
    try testing.expectError(
        error.NotImplemented,
        loadJSON(testing.allocator, &in),
    );
}

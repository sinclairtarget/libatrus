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
const transform_ = @import("transform/transform.zig");
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
        /// Only parse blocks, not inline content. This is only really useful
        /// for debugging.
        block = 0,
        /// Parse blocks and inline content into a "raw" MyST AST. A "raw" AST
        /// is hot out of the parser and has not yet been transformed in any
        /// way; in particular, builtin directives and roles are not
        /// implemented. This is also only really useful for debugging.
        raw = 1,
        /// Parse MyST Markdown into an unresolved MyST AST. The structure of
        /// this AST conforms exactly to the MyST specification. Choose this
        /// option if you want a maximally portable AST for interop with other
        /// MyST tooling, or want to skip the post-processing transforms.
        pre = 2,
        /// Parse blocks and inline content into a "resolved" MyST AST. A
        /// "resolved" AST is the result of running several post-processing
        /// transforms on the AST, including transforms to simplify the AST and
        /// resolve internal references. Choose this option if you intend to
        /// render the AST as-is using libatrus.
        ///
        /// If you want more control over which post-processing transforms are
        /// done, use the `.pre` parse level and call `atrus.transform()` on
        /// the returned AST.
        post = 3,
    } = .post,
};

/// Parses the input (containing MyST markdown) into a MyST AST. Returns
/// a pointer to the root node.
///
/// The caller is responsible for freeing the memory used by the AST nodes.
///
/// By default, this function returns a fully resolved MyST AST. This is
/// appropriate if you plan to render the returned AST as-is. If you plan to
/// modify the AST, or want control over which post-processing transforms are
/// done in the resolution phase, use the `.pre` parse level option and make a
/// call to `atrus.transform()` if you later want to run the resolution phase.
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
    root = try transform_.inlines.transform(alloc, &arena, root, link_defs);
    logger.debug("Done in {D}.", .{timer.read()});

    if (options.parse_level == .raw) {
        return root;
    }

    _ = arena.reset(.retain_capacity);

    // run pre stage transforms (built-in roles and directives)
    timer.reset();
    logger.debug("Beginning pre transforms...", .{});
    root = try transform_.pre.transform(alloc, scratch, root);
    logger.debug("Done in {D}.", .{timer.read()});

    if (options.parse_level == .pre) {
        return root;
    }

    _ = arena.reset(.retain_capacity);

    // run post stage transforms (resolution phase)
    timer.reset();
    logger.debug("Beginning post transforms...", .{});
    root = try transform_.post.transform(alloc, scratch, root);
    logger.debug("Done in {D}.", .{timer.read()});

    return root;
}

pub const TransformError = error{
    OutOfMemory,
};

pub const TransformOptions = struct {};

/// Runs post-processing transforms on the given AST, modifying it in-place.
/// After these transforms, the AST is considered to be "resolved".
///
/// This is a no-op if you previously called `atrus.parse()` using the `.post`
/// parse level, since these are the same transforms done there.
///
/// This function gives you more control over which post-processing transforms
/// are done. It also allows you to modify the AST returned from
/// `atrus.parse()` before running any of the post-processing transforms.
pub fn transform(
    alloc: Allocator,
    root: *ast.Node,
    options: TransformOptions,
) TransformError!*ast.Node {
    _ = options;

    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();

    var timer = time.Timer.start() catch { @panic("timer unsupported"); };
    logger.debug("Beginning post transforms...", .{});
    const transformed = try transform_.post.transform(alloc, scratch, root);
    logger.debug("Done in {D}.", .{timer.read()});

    return transformed;
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
    _ = @import("cmark/cmark.zig");
    _ = @import("lex/LineReader.zig");
    _ = @import("lex/BlockTokenizer.zig");
    _ = @import("lex/InlineTokenizer.zig");
    _ = @import("parse/LeafBlockParser.zig");
    _ = @import("parse/ContainerBlockParser.zig");
    _ = @import("parse/escape.zig");
    _ = @import("parse/InlineParser.zig");
    _ = @import("transform/pre/roles.zig");
    _ = @import("transform/pre/directives.zig");
    _ = @import("util/util.zig");
}

test parse {
    const md =
        \\# I am a heading
        \\I am a paragraph containing *emphasis*.
        \\
    ;

    var in: Io.Reader = .fixed(md);
    const root_node = try parse(testing.allocator, &in, .{});
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));
}

test transform {
    const md =
        \\# I am a heading
        \\I am a paragraph containing *emphasis*.
        \\
    ;

    var in: Io.Reader = .fixed(md);
    var root_node = try parse(testing.allocator, &in, .{
        // Don't execute any post-processing transforms.
        .parse_level = .pre,
    });
    defer root_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, root_node.*));

    // Both the heading and the paragraph are direct children of the root node.
    try testing.expectEqual(2, root_node.root.children.len);

    root_node = try transform(testing.allocator, root_node, .{});

    // One of the post-processing transformations groups sub-trees of the AST
    // into "blocks". The root node just has a single block child now.
    try testing.expectEqual(1, root_node.root.children.len);
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

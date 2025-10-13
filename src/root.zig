//! libatrus parses MyST-flavored markdown into the MyST AST.
//!
//! It can also render the AST to JSON and HTML.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;

const BlockTokenizer = @import("lex/BlockTokenizer.zig");
const BlockParser = @import("parse/BlockParser.zig");
const InlineParser = @import("parse/InlineParser.zig");
const post = @import("parse/post.zig");
const json = @import("render/json.zig");
const html = @import("render/html.zig");

// The below `pub` variable and function declarations define the public
// interface of libatrus.

pub const ast = @import("parse/ast.zig");
pub const version = config.version;

pub const ParseError = error{
    ReadFailed,
    LineTooLong, // TODO: Remove this?
    UnrecognizedSyntax,
    UnicodeError,
} || Allocator.Error || Io.Writer.Error;

pub const ParseOptions = struct {
    parse_level: enum {
        pre,
        post,
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

    // first stage; parse into blocks
    var block_tokenizer = BlockTokenizer.init(&reader);
    var block_parser = BlockParser.init(&block_tokenizer);
    var root = try block_parser.parse(alloc);

    // second stage; parse inline elements
    root = try InlineParser.transform(alloc, root);

    if (options.parse_level == .pre) {
        return root;
    }

    // third stage; MyST-specific transforms
    root = try post.postProcess(alloc, root);
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
};

/// Takes the root node of a MyST AST. Returns the rendered JSON as a
/// null-terminated string.
///
/// The caller is responsible for freeing the returned string.
pub fn renderJSON(
    alloc: Allocator,
    root: *ast.Node,
    options: JSONOptions,
) RenderJSONError![:0]const u8 {
    var buf = Io.Writer.Allocating.init(alloc);

    try json.render(
        root,
        &buf.writer,
        options,
    );

    try buf.writer.writeByte(0); // zero terminate
    const written = buf.written();
    return written[0 .. written.len - 1 :0];
}

pub const RenderHTMLError = error{
    WriteFailed,
    OutOfMemory,
    NotPostProcessed,
};

/// Takes the root node of a MyST AST. Returns the rendered HTML as a string.
///
/// The caller is responsible for freeing the returned string.
pub fn renderHTML(
    alloc: Allocator,
    root: *ast.Node,
) RenderHTMLError![:0]const u8 {
    if (!root.root.is_post_processed) {
        return RenderHTMLError.NotPostProcessed;
    }

    var buf = Io.Writer.Allocating.init(alloc);
    try html.render(
        root,
        &buf.writer,
    );

    try buf.writer.writeByte(0); // zero terminate
    const written = buf.written();
    return written[0 .. written.len - 1 :0];
}

// Tokenization is part of the public interface of the library only in debug
// mode.
pub const lex =
    if (builtin.mode == .Debug)
        struct {
            pub const BlockToken = @import("lex/tokens.zig").BlockToken;
            pub const BlockTokenType = @import("lex/tokens.zig").BlockTokenType;
            pub const BlockTokenizer = @import("lex/BlockTokenizer.zig");
        }
    else
        @compileError("tokenziation is only supported in the debug release mode");

// ----------------------------------------------------------------------------
const md =
    \\# I am a heading
    \\I am a paragraph.
;

test renderHTML {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const root = try parse(arena, md, .{});
    const result = try renderHTML(arena, root);

    try std.testing.expectEqualStrings(
        "<h1>I am a heading</h1>\n<p>I am a paragraph.</p>\n",
        result,
    );
}

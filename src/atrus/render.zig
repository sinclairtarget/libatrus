const std = @import("std");
const Io = std.Io;

const ast = @import("ast.zig");
const json = @import("render/json.zig");
const html = @import("render/html.zig");
const typst = @import("render/typst.zig");

pub const HTMLOptions = html.Options;

pub const HTMLError = error{
    WriteFailed,
    OutOfMemory,
    NotPostProcessed,
};

/// Renders the AST as HTML, writing to the given writer.
pub fn toHTML(
    root: *ast.Node,
    out: *Io.Writer,
    options: HTMLOptions,
) HTMLError!void {
    try html.render(root, out, options);
}

pub const JSONOptions = json.Options;

pub const JSONError = error{
    WriteFailed,
    OutOfMemory,
};

/// Renders the AST as JSON, writing to the given writer.
pub fn toJSON(
    root: *ast.Node,
    out: *Io.Writer,
    options: JSONOptions,
) JSONError!void {
    try json.render(root, out, options);
}

pub const TypstOptions = struct {}; // No options (yet!)

pub const TypstError = typst.RenderError;

pub fn toTypst(
    root: *ast.Node,
    out: *Io.Writer,
    options: TypstOptions,
) TypstError!void {
    _ = options;
    try typst.render(root, out);
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;
const atrus = @import("root.zig");

test toHTML {
    const md =
        \\# I am a heading
        \\I am a paragraph containing *emphasis*.
    ;
    const expected =
        \\<h1>I am a heading</h1>
        \\<p>I am a paragraph containing <em>emphasis</em>.</p>
    ;

    var in: Io.Reader = .fixed(md);
    const root = try atrus.parse(testing.allocator, &in, .{});
    defer root.deinit(testing.allocator);

    var buf = Io.Writer.Allocating.init(testing.allocator);
    try atrus.render.toHTML(root, &buf.writer, .{});
    const result = try buf.toOwnedSlice();
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test toJSON {
    const md =
        \\I am a paragraph containing *emphasis*.
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
    const root = try atrus.parse(testing.allocator, &in, .{});
    defer root.deinit(testing.allocator);

    var buf = Io.Writer.Allocating.init(testing.allocator);
    try atrus.render.toJSON(root, &buf.writer, .{ .whitespace = .indent_2 });
    const result = try buf.toOwnedSlice();
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test toTypst {
    const md =
        \\# I am a heading
        \\I am a paragraph with [a link](http://coolpage.com).
    ;

    const expected =
        \\= I am a heading
        \\I am a paragraph with #link("http://coolpage.com")[a link].
    ;

    var in: Io.Reader = .fixed(md);
    const root = try atrus.parse(testing.allocator, &in, .{});
    defer root.deinit(testing.allocator);

    var buf = Io.Writer.Allocating.init(testing.allocator);
    try atrus.render.toTypst(root, &buf.writer, .{});
    const result = try buf.toOwnedSlice();
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

//! Exported API for C.
//!
//! See include/atrus.h for C API documentation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const atrus = @import("atrus");
const ParseError = atrus.ParseError;
const RenderJSONError = atrus.RenderJSONError;
const RenderHTMLError = atrus.RenderHTMLError;

const alloc = std.heap.c_allocator;

export fn atrus_ast_parse(in: [*:0]const u8, out: **atrus.ast.Node) c_int {
    out.* = atrus.parse(alloc, std.mem.span(in), .{}) catch |err| {
        switch (err) {
            ParseError.ReadFailed => return 1,
            else => return 2,
        }
    };
    return 0;
}

export fn atrus_ast_free(root: *atrus.ast.Node) void {
    root.deinit(alloc);
}

export fn atrus_render_json(root: *atrus.ast.Node, out: *[*:0]const u8) c_int {
    var buf = Io.Writer.Allocating.init(alloc);
    atrus.renderJSON(&buf.writer, root, .{}) catch |err| {
        switch (err) {
            RenderJSONError.WriteFailed => return -1,
            RenderJSONError.OutOfMemory => return -1,
        }
    };

    const s: [:0]const u8 = buf.toOwnedSliceSentinel(0) catch |err| {
        switch (err) {
            Allocator.Error.OutOfMemory => return -1,
        }
    };
    out.* = s.ptr;
    return @intCast(s.len);
}

export fn atrus_render_html(root: *atrus.ast.Node, out: *[*:0]const u8) c_int {
    var buf = Io.Writer.Allocating.init(alloc);
    atrus.renderHTML(&buf.writer, root) catch |err| {
        switch (err) {
            RenderHTMLError.WriteFailed => return -1,
            RenderHTMLError.OutOfMemory => return -1,
            RenderHTMLError.NotPostProcessed => return -1, // TODO: Communicate!
        }
    };

    const s: [:0]const u8 = buf.toOwnedSliceSentinel(0) catch |err| {
        switch (err) {
            Allocator.Error.OutOfMemory => return -1,
        }
    };
    out.* = s.ptr;
    return @intCast(s.len);
}

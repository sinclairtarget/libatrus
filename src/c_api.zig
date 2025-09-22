//! Exported API for C.
//!
//! See include/atrus.h for C API documentation.

const std = @import("std");

const atrus = @import("atrus");
const ParseError = atrus.ParseError;
const RenderJSONError = atrus.RenderJSONError;

const alloc = std.heap.c_allocator;

export fn atrus_ast_parse(in: [*:0]const u8, out: **atrus.ast.Node) c_int {
    out.* = atrus.parse(alloc, std.mem.span(in)) catch |err| {
        switch (err) {
            ParseError.ReadFailed => return 1,
            ParseError.LineTooLong => return 2,
            ParseError.OutOfMemory => return 2,
        }
    };
    return 0;
}

export fn atrus_ast_free(root: *atrus.ast.Node) void {
    root.deinit(alloc);
}

export fn atrus_render_json(root: *atrus.ast.Node, out: *[*:0]const u8) c_int {
    const s = atrus.renderJSON(alloc, root, .{}) catch |err| {
        switch (err) {
            RenderJSONError.WriteFailed => return -1,
        }
    };
    out.* = s.ptr;
    return @intCast(s.len);
}

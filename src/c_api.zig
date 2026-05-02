//! Implements the C-ABI-compatible interface to libatrus.
//!
//! See include/atrus.h for usage documentation.
//!
//! Any "extern" data structures here must be kept in sync with the definitions
//! in include/atrus.h. Doing any of the following constitutes a breaking ABI
//! change:
//!
//! * Adding a new field to an extern struct
//! * Changing the order of fields in an extern struct
//! * Adding a new member to an extern union, if the member is bigger than the
//!   others.
//! * Changing any field types.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const atrus = @import("atrus");
const ParseError = atrus.ParseError;
const RenderJSONError = atrus.RenderJSONError;
const RenderHTMLError = atrus.RenderHTMLError;

const alloc = std.heap.c_allocator;

// TODO: Is atrus.version already null-terminated?
export const atrus_version: [*:0]const u8 = atrus.version ++ "\x00";

export fn atrus_parse(
    in: [*:0]const u8,
    out: **atrus.ast.Node,
    options: *const atrus.ParseOptions,
) c_int {
    var reader = Io.Reader.fixed(std.mem.span(in));
    out.* = atrus.parse(alloc, &reader, options.*) catch |err| {
        switch (err) {
            ParseError.ReadFailed => return -1,
            else => return -2,
        }
    };
    return 0;
}

export fn atrus_free(root: *atrus.ast.Node) void {
    if (root.tag != .root) {
        @panic("atrus_free() called on non-root AST node");
    }

    root.deinit(alloc);
}

export fn atrus_render_html(root: *atrus.ast.Node, out: *[*:0]const u8) c_int {
    var buf = Io.Writer.Allocating.init(alloc);
    atrus.renderHTML(root, &buf.writer, .{}) catch |err| {
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

export fn atrus_render_json(
    root: *atrus.ast.Node,
    out: *[*:0]const u8,
    options: *const atrus.JSONOptions,
) c_int {
    var buf = Io.Writer.Allocating.init(alloc);
    atrus.renderJSON(root, &buf.writer, options.*) catch |err| {
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

export fn atrus_load_json(in: [*:0]const u8, out: **atrus.ast.Node) c_int {
    var reader = Io.Reader.fixed(std.mem.span(in));
    out.* = atrus.loadJSON(alloc, &reader) catch |err| {
        switch (err) {
            error.NotImplemented => return -1,
        }
    };

    return 0;
}

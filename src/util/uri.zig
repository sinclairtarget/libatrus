const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Uri = std.Uri;

pub const Error = (
    Allocator.Error
    || Io.Writer.Error
    || Uri.ParseError
);

/// Normalizes URIs that will be used as attibute values (vs. textual content).
pub fn normalize(
    alloc: Allocator,
    scratch: Allocator,
    raw: []const u8,
) Error![]const u8 {
    var w = Io.Writer.Allocating.init(alloc);
    errdefer w.deinit();

    const uri = try Uri.parse(raw);
    const raw_uri = try toRawUri(scratch, uri);
    try customFormat(raw_uri, &w.writer);
    return try w.toOwnedSlice();
}

/// Sad!
///
/// Zig's Uri.parse seems to assume that any input is already percent-encoded.
/// Here, we convert a Uri to one where every component is "raw", forcing Zig
/// to percent-encode each component when we write it out.
///
/// Any existing percent-encoding in the input will be decoded.
fn toRawUri(scratch: Allocator, uri: Uri) !Uri {
    const user: ?Uri.Component = blk: {
        if (uri.user) |existing| {
            const raw = try existing.toRawMaybeAlloc(scratch);
            break :blk Uri.Component{ .raw = raw };
        }
        break :blk null;
    };

    const password: ?Uri.Component = blk: {
        if (uri.password) |existing| {
            const raw = try existing.toRawMaybeAlloc(scratch);
            break :blk Uri.Component{ .raw = raw };
        }
        break :blk null;
    };

    const host: ?Uri.Component = blk: {
        if (uri.host) |existing| {
            const raw = try existing.toRawMaybeAlloc(scratch);
            break :blk Uri.Component{ .raw = raw };
        }
        break :blk null;
    };

    const path: ?Uri.Component = blk: {
        if (!uri.path.isEmpty()) {
            const raw = try uri.path.toRawMaybeAlloc(scratch);
            break :blk Uri.Component{ .raw = raw };
        }
        break :blk null;
    };

    const query: ?Uri.Component = blk: {
        if (uri.query) |existing| {
            const raw = try existing.toRawMaybeAlloc(scratch);
            break :blk Uri.Component{ .raw = raw };
        }
        break :blk null;
    };

    const fragment: ?Uri.Component = blk: {
        if (uri.fragment) |existing| {
            const raw = try existing.toRawMaybeAlloc(scratch);
            break :blk Uri.Component{ .raw = raw };
        }
        break :blk null;
    };

    return Uri{
        .scheme = uri.scheme,
        .user = user,
        .password = password,
        .port = uri.port,
        .host = host,
        .path = path orelse .empty,
        .query = query,
        .fragment = fragment,
    };
}

/// Custom version of Uri.writeToStream(), since as of Zig 0.15.2 that function
/// always includes a '/' for the path, even when it is empty. That seems like
/// a sensible thing to do but it doesn't match the MyST spec tests.
fn customFormat(uri: Uri, writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("{s}:", .{uri.scheme});
    if (uri.host != null) {
        try writer.writeAll("//");
    }
    if (uri.host != null) {
        if (uri.user) |user| {
            try user.formatUser(writer);
            if (uri.password) |password| {
                try writer.writeByte(':');
                try password.formatPassword(writer);
            }
            try writer.writeByte('@');
        }
    }
    if (uri.host) |host| {
        try host.formatHost(writer);
        if (uri.port) |port| try writer.print(":{d}", .{port});
    }
    const uri_path = uri.path;
    try uri_path.formatPath(writer);
    if (uri.query) |query| {
        try writer.writeByte('?');
        try query.formatQuery(writer);
    }
    if (uri.fragment) |fragment| {
        try writer.writeByte('#');
        try fragment.formatFragment(writer);
    }
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

fn expectNormalized(expected: []const u8, in: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const result = try normalize(testing.allocator, scratch, in);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test "normalize uri" {
    try expectNormalized(
        "https://foo.com/bar?nums%5B%5D=1&nums%5B%5D=2",
        "https://foo.com/bar?nums[]=1&nums[]=2",
    );
}

test "normalize uri already encoded" {
    try expectNormalized(
        "https://foo.com/bar?nums%5B%5D=1&nums%5B%5D=2",
        "https://foo.com/bar?nums%5B%5D=1&nums%5B%5D=2",
    );
}

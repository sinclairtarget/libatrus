const std = @import("std");
const config = @import("config");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Child = std.process.Child;

const md =
    \\# This is a heading
    \\This is a paragraph.
    \\
;

pub fn main() !void {
    var arena_impl = ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var stdout_buffer: [64]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input_file_path = blk: {
        var file = try tmp.dir.createFile("test.md", .{});
        defer file.close();

        var buf: [128]u8 = undefined;
        var file_writer = file.writer(&buf);
        const writer = &file_writer.interface;
        try writer.writeAll(md);
        try writer.flush();

        break :blk try tmp.dir.realpathAlloc(arena, "test.md");
    };

    const rusage = try run_atrus(arena, input_file_path);

    if (rusage.getMaxRss()) |rss_bytes| {
        const rss_mb = @as(f32, @floatFromInt(rss_bytes)) / 1_000_000.0;
        try stdout.print("Max RSS: {d:.1} mb\n", .{rss_mb});
    } else {
        try stdout.print("Max RSS was unavailable.\n", .{});
    }

    try stdout.flush();
}

// Run as subprocess.
fn run_atrus(
    alloc: Allocator,
    input_file_path: []const u8,
) !Child.ResourceUsageStatistics {
    var child = Child.init(&.{ config.exec_path, input_file_path }, alloc);

    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.request_resource_usage_statistics = true;

    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
    }

    const term = try child.wait();
    switch (term) {
        .Exited => |exit_code| {
            if (exit_code != 0) {
                std.debug.print(
                    "Subprocess exited with code: {d}\n",
                    .{exit_code},
                );
                return error.BadExitCode;
            }
        },
        else => {
            return error.Terminated;
        },
    }

    return child.resource_usage_statistics;
}

const std = @import("std");
const config = @import("config");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Child = std.process.Child;
const Timer = std.time.Timer;

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

    var timer = try Timer.start();
    try run_atrus(arena, input_file_path);
    const duration_ns = timer.read();
    const duration_ms = duration_ns / 1_000_000;

    try stdout.print("Runtime: {d:.0}ms\n", .{duration_ms});
    try stdout.flush();
}

// Run as subprocess.
fn run_atrus(
    alloc: Allocator,
    input_file_path: []const u8,
) !void {
    const result = Child.run(.{
        .allocator = alloc,
        .argv = &.{config.exec_path, input_file_path},
    }) catch |err| {
        std.debug.print("Got {any} trying to run subprocess.\n", .{err});
        return error.RunFailed;
    };

    switch (result.term) {
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
}

const std = @import("std");
const config = @import("config");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Error = error {
    RunFailed,
    Terminated,
    BadExitCode,
};

// Run as subprocess.
fn run_atrus(alloc: Allocator, comptime args: []const []const u8) ![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &[_][]const u8{config.exec_path} ++ args,
    }) catch |err| {
        std.debug.print("Got {any} trying to run subprocess.\n", .{err});
        return Error.RunFailed;
    };

    switch (result.term) {
        .Exited => |exit_code| {
            if (exit_code == 0) {
                return result.stdout;
            } else {
                std.debug.print(
                    "Subprocess exited with code: {d}\n", 
                    .{exit_code},
                );
                std.debug.print("Output from stderr:\n{s}\n", .{result.stderr});
                return Error.BadExitCode;
            }
        },
        else => {
            return Error.Terminated;
        },
    }
}

test "-h flag" {
    var arena_impl = ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();

    const out = try run_atrus(arena_impl.allocator(), &.{ "-h" });
    try std.testing.expect(std.mem.indexOf(u8, out, "Usage") != null);
}

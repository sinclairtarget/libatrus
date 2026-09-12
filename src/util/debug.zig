const std = @import("std");

/// Timer meant for timing steps in a computation.
pub fn ComputationTimer(logger: anytype) type {
    return struct {
        timer: ?std.time.Timer,
        options: Options,

        const Options = struct {
            /// Prefix timing log messages with this name.
            timer_name: ?[]const u8 = null,
        };

        const Self = @This();

        pub fn init(options: Options) Self {
            return .{
                .timer = null,
                .options = options,
            };
        }

        /// Start timing a new step.
        pub fn step(self: *Self, step_name: []const u8) void {
            self.stop();
            self.reset();

            if (self.options.timer_name) |timer_name| {
                logger.debug(
                    "{s} - Beginning step \"{s}\"...",
                    .{ timer_name, step_name },
                );
            } else {
                logger.debug("Beginning step \"{s}\"...", .{step_name});
            }
        }

        pub fn stop(self: *Self) void {
            var timer = self.timer orelse return;

            if (self.options.timer_name) |timer_name| {
                logger.debug(
                    "{s} - Done in {D}.",
                    .{ timer_name, timer.read() },
                );
            } else {
                logger.debug("Done in {D}.", .{timer.read()});
            }
        }

        fn reset(self: *Self) void {
            if (self.timer) |*timer| {
                timer.reset();
            } else {
                self.timer = std.time.Timer.start() catch {
                    @panic("timer unsupported");
                };
            }
        }
    };
}

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Timer meant for timing steps in a computation.
pub fn ComputationTimer(logger: anytype) type {
    const Options = struct {
        /// Prefix timing log messages with this name.
        timer_name: ?[]const u8 = null,
    };

    if (builtin.mode != .Debug) {
        // No-op implementation in non-debug builds
        return struct {
            const Self = @This();
            pub fn init(options: Options) Self {
                _ = options;
                return .{};
            }
            pub fn step(self: *Self, step_name: []const u8) void {
                _ = self;
                _ = step_name;
            }
            pub fn stop(self: *Self) void {
                _ = self;
            }
        };
    }

    // Debug implementation
    return struct {
        io: Io,
        start: ?Io.Timestamp,
        options: Options,

        const Self = @This();

        pub fn init(options: Options) Self {
            // Creating new instance of Io here! Not using top-level one!!!
            // IDK, we just need the time and this timer isn't used outside of
            // debug builds. We don't want to require an Io arg in our
            // public-facing library methods just so we can time things in
            // debug builds.
            var threaded: Io.Threaded = .init_single_threaded;
            return .{
                .io = threaded.io(),
                .start = null,
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
            const start = self.start orelse return;
            const end = self.now();
            const duration = start.durationTo(end);

            if (self.options.timer_name) |timer_name| {
                logger.debug(
                    "{s} - Done in {f}.",
                    .{ timer_name, duration },
                );
            } else {
                logger.debug("Done in {f}.", .{duration});
            }
        }

        fn reset(self: *Self) void {
            self.start = self.now();
        }

        fn now(self: Self) Io.Timestamp {
            return Io.Timestamp.now(self.io, .awake);
        }
    };
}

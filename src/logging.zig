//! With our logging we want to support the following:
//!
//! * When consumed as a library by other projects, we want to avoid being
//!   obnoxiously chatty. So we try to use only the debug log level. Downstream
//!   consumers may still see debug log messages if they compile libatrus in
//!   debug mode, so they should be able to turn all logging from the library
//!   off using a single scope.
//! * For our own debugging purposes, we want fine-grained logging scopes so
//!   that we can turn on logging only for certain parts of the program when
//!   needed.
//!
//! Zig does not have hierarchical logging scopes, so unfortunately we can't
//! just have scopes like `libatrus.foo` that downstream projects can turn off
//! by disabling the `libatrus` scope.
//!
//! What we do instead is consult a compile-time option that tells us whether
//! to use a single log scope for the entire library or the finer-grained log
//! scopes.
//!

const std = @import("std");
const config = @import("config");

/// Returns a scoped logger.
///
/// Uses the given scope, but only if fine-grained log scopes are enabled.
pub fn logger(scope: @Type(.enum_literal)) type {
    if (config.allow_log_scopes) {
        return std.log.scoped(scope);
    } else {
        return std.log.scoped(.libatrus);
    }
}

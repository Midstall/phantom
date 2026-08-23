//! The single chokepoint for unrecoverable programmer errors (a corrupt tree, a
//! widget config too large for the fault sentinel). NOT for OOM / GPU hiccups,
//! which are recoverable faults recorded on a FaultSink. A host (e.g. a Genesis
//! compositor) can install a hook to tear down one scope instead of aborting the
//! whole session.
//!
//! TRAP: `setHook` only affects THIS file's own `panic` function, reached solely
//! by an explicit call to `phantom.panic(...)`. It is NOT Zig's language level
//! panic handler and does NOT intercept a bare `@panic`, an `unreachable`, or a
//! failed bounds or overflow check anywhere else in the tree: those go through
//! Zig's own panic mechanism, which looks for `pub const panic` in the ROOT
//! MODULE OF THE COMPILATION (the file the build gives as its root source, not
//! any module it imports, so this file's own presence inside the `phantom`
//! import does not count) and falls back to `std.debug.defaultPanic` (print,
//! then `abort()`) when the root declares none.
//!
//! A consumer that wants a language level panic to reach a hook, this one or any
//! other, must declare that itself:
//!
//!     pub const panic = std.debug.FullPanic(myPanicFn);
//!
//! in ITS OWN root source file. The terminal path's answer is
//! `lib/phantom/tui/term.zig`'s `rootPanic`; `phantom.addApp` wires it into the
//! entry point it generates, and `examples/tui.zig` wires it directly since it is
//! its own root and `addApp` never touches it. A root module that skips this has
//! no crash safety at all for the most common class of crash there is, in a
//! project that asserts on programmer errors as a matter of policy: every
//! `unreachable` and every bounds check is exactly this path, not an edge case.

const std = @import("std");
const builtin = @import("builtin");

var hook: ?*const fn (msg: []const u8) noreturn = null;

/// Install (or clear with null) the panic hook. When set, `panic` calls it
/// instead of aborting via std. The hook must not return (it owns teardown).
pub fn setHook(h: ?*const fn (msg: []const u8) noreturn) void {
    hook = h;
}

/// Whether a hook is currently installed (introspection / tests).
pub fn hasHook() bool {
    return hook != null;
}

/// Report an unrecoverable programmer error and do not return. Routes through the
/// installed hook if present, else aborts via std.debug.panic.
pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    if (hook) |h| h(msg);
    // On wasm32-freestanding, std.debug.panic's stack-trace machinery is not
    // available; use the builtin panic there. Native gets the full message.
    if (builtin.target.os.tag == .freestanding) {
        @panic(msg);
    } else {
        std.debug.panic("phantom: {s}", .{msg});
    }
}

test "setHook installs and clears the panic hook" {
    setHook(null);
    try std.testing.expect(!hasHook());
    const H = struct {
        fn h(_: []const u8) noreturn {
            unreachable;
        }
    };
    setHook(H.h);
    try std.testing.expect(hasHook());
    setHook(null);
    try std.testing.expect(!hasHook());
}

const std = @import("std");
const phantom = @import("../phantom.zig");

pub const Backend = enum { gpu, tui, none };

/// Choose the backend from what each one reports about itself.
///
/// The environment override comes first so a user can always force a choice.
/// After that it is a plain preference: a window if there is one to be had,
/// otherwise a terminal, otherwise nothing and a clear message.
///
/// `window_possible` is an ANSWER, not a guess: `window.available` gets it from
/// lattice. This used to read `WAYLAND_DISPLAY` and `DISPLAY` here and conclude
/// a window was possible, which was a second implementation of a decision
/// lattice already makes, and it got it wrong for X11: lattice resolves an X11
/// session to its headless backend, so phantom would pick the window path and
/// lattice would then render to nothing. Taking the capability as an input keeps
/// this function a pure policy that can be tested without a compositor, and
/// leaves the capability with the component that owns it.
pub fn selectBackend(
    env: *const std.process.Environ.Map,
    window_possible: bool,
    stdout_is_tty: bool,
) Backend {
    if (env.get("PHANTOM_BACKEND")) |want| {
        if (std.mem.eql(u8, want, "tui")) return .tui;
        // Honored even against `window_possible`: an override exists to be
        // obeyed, and a user who forces the window backend on a machine that
        // reports none deserves that backend's own error rather than a silent
        // downgrade to the terminal.
        if (std.mem.eql(u8, want, "gpu")) return .gpu;
        // Any other value is user input and is a runtime fault, so the detection runs
        // instead of the program failing.
    }
    if (window_possible) return .gpu;
    if (stdout_is_tty) return .tui;
    return .none;
}

test "the environment override wins over what the backends report" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PHANTOM_BACKEND", "tui");
    try std.testing.expectEqual(Backend.tui, selectBackend(&env, true, true));

    // Forced to the window backend on a machine reporting no window: the
    // override is still obeyed, so what a user gets is that backend's own error
    // and not a silent downgrade they never asked for.
    try env.put("PHANTOM_BACKEND", "gpu");
    try std.testing.expectEqual(Backend.gpu, selectBackend(&env, false, true));
}

test "a window is preferred whenever lattice reports one is possible" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(Backend.gpu, selectBackend(&env, true, true));
    // Even with no terminal to fall back to.
    try std.testing.expectEqual(Backend.gpu, selectBackend(&env, true, false));
}

test "no window and a terminal selects the terminal backend" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(Backend.tui, selectBackend(&env, false, true));
}

test "no window and no terminal selects nothing" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(Backend.none, selectBackend(&env, false, false));
}

test "a display variable on its own decides nothing, because lattice decides" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    // Both variables set and lattice still reporting no window, which is what
    // an X11 session gives: lattice resolves that to its HEADLESS backend,
    // which has no screen to put a window on. The old code read these two
    // variables here and concluded a window was possible, so phantom chose the
    // window backend and lattice then rendered to nothing.
    try env.put("WAYLAND_DISPLAY", "wayland-0");
    try env.put("DISPLAY", ":0");
    try std.testing.expectEqual(Backend.tui, selectBackend(&env, false, true));
}

test "an unknown override value is ignored and the preference runs" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PHANTOM_BACKEND", "nonsense");
    try std.testing.expectEqual(Backend.gpu, selectBackend(&env, true, true));
    try std.testing.expectEqual(Backend.tui, selectBackend(&env, false, true));
}

pub const App = struct {
    /// Pick the backend and dispatch to it. A compositor gives the window path, a
    /// terminal on stdout gives the terminal path, and neither is a runtime fault:
    /// it fails loudly instead of drawing nothing and leaving the person to guess why.
    pub fn run(init: std.process.Init, root: phantom.Root) !void {
        // The terminal backend draws every frame to stdout (see Term.out in
        // lib/phantom/tui/term.zig), so stdout is the fd that decides whether the
        // terminal path can work. A terminal on stderr with stdout piped elsewhere
        // (`phantom-hello-tui | less`, for example) cannot receive the alt-screen and
        // cursor control codes without corrupting the pipe's data, so this checks
        // stdout alone and never falls back to stderr.
        const is_tty = std.Io.File.stdout().isTty(init.io) catch false;
        // Asked of lattice, not guessed from the environment: see
        // `selectBackend`, and `window.open` for what lattice is asked.
        //
        // The window it opens IS the window the session runs on. Opening one is
        // the only honest way to know a window is possible, so the answer comes
        // with the thing itself, and dropping it here would mean connecting a
        // second time for something already in hand.
        const opts = phantom.window.Options{};
        var opened = phantom.window.open(init.gpa, init.io, init.environ_map, opts);
        // Whatever this function does next, an unused window is given back. Every
        // path that takes it over clears this first, so it is closed once or not
        // at all.
        defer if (opened) |*o| o.close();

        switch (selectBackend(init.environ_map, opened != null, is_tty)) {
            .gpu => {
                const win = opened orelse
                    // Only reachable through `PHANTOM_BACKEND=gpu`, which asks
                    // for the window path on a machine that has no window.
                    return error.NoWindowBackend;
                opened = null;
                return phantom.window.App.runOn(init, win, root, opts);
            },
            .tui => return phantom.Tui.run(init, root, .{}),
            .none => {
                // A clear message, because "it did nothing" is the worst outcome here.
                var buf: [256]u8 = undefined;
                var w = std.Io.File.stderr().writerStreaming(init.io, &buf);
                try w.interface.writeAll(
                    "phantom: no display and no terminal.\n" ++
                        "Set WAYLAND_DISPLAY or DISPLAY for a window, run in a terminal, " ++
                        "or set PHANTOM_BACKEND=tui or gpu.\n",
                );
                try w.interface.flush();
                return error.NoBackend;
            },
        }
    }
};

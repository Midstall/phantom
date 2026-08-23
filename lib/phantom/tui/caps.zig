//! Terminal capability detection. The environment gives the first expectation and
//! the queries confirm it. DA1 is the barrier: all terminals answer DA1, so a query
//! with no answer by the time DA1 answers is not supported. This removes the need
//! for a timeout guess.
const std = @import("std");
const ansi = @import("ansi.zig");

pub const Caps = struct {
    kitty_keyboard: bool = false,
    kitty_graphics: bool = false,
    truecolor: bool = false,
    sync_output: bool = false,
    inband_resize: bool = false,
    sgr_pixel_mouse: bool = false,
};

pub const Hint = struct {
    expect_graphics: bool = false,
    expect_kitty_kbd: bool = false,
    multiplexer: bool = false,
    truecolor: bool = false,
};

pub fn hintFromEnv(term_var: ?[]const u8, term_program: ?[]const u8, colorterm: ?[]const u8) Hint {
    var h = Hint{};

    if (colorterm) |ct| {
        h.truecolor = std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit");
    }

    const t = term_var orelse "";
    const p = term_program orelse "";

    h.multiplexer = std.mem.startsWith(u8, t, "tmux") or
        std.mem.startsWith(u8, t, "screen") or
        std.mem.eql(u8, p, "tmux");

    const is_ghostty = std.mem.indexOf(u8, t, "ghostty") != null or std.mem.eql(u8, p, "ghostty");
    const is_kitty = std.mem.indexOf(u8, t, "kitty") != null or std.mem.eql(u8, p, "kitty");

    if (is_ghostty or is_kitty) {
        h.expect_kitty_kbd = true;
        // A multiplexer sits between us and the terminal and does not forward the
        // graphics protocol reliably, so the expectation drops even for ghostty.
        h.expect_graphics = !h.multiplexer;
        h.truecolor = true;
    }

    return h;
}

// The queries, in the order they go out. DA1 is last because it is the barrier.
// Split so the graphics probe can be left out: it is the only piece not written
// as a plain CSI sequence with a numeric body. `parseReplies` already forces
// `kitty_graphics` false under a multiplexer regardless of what comes back, so
// sending it there answers nothing, and worse, tmux does not parse an APC
// sequence the way it parses CSI. It leaks the query's printable payload
// (`Gi=1,s=1,v=1,a=q,t=d,`) into the status line instead of consuming it, a real
// bug seen on a live tmux session. The other four pieces are untouched: three are
// DECRPM `CSI ? <mode> $p` queries and one is the kitty keyboard `CSI ? u` query,
// all plain CSI with only digits in the body, which is tmux's native vocabulary
// and passes through cleanly.
const query_kitty_kbd = ansi.csi ++ "?u";
const query_graphics = ansi.apc ++ "Gi=1,s=1,v=1,a=q,t=d,f=24;AAAA" ++ ansi.st;
const query_rest =
    ansi.csi ++ "?2026$p" ++ // synchronized output
    ansi.csi ++ "?2048$p" ++ // in-band resize
    ansi.csi ++ "?1016$p" ++ // SGR pixel mouse
    ansi.csi ++ "c"; // DA1, the barrier

/// The full probe, graphics query included. Kept for tests that exercise a bare
/// ghostty (not a multiplexer), and as the answer `queryFor` gives outside one.
pub const query = query_kitty_kbd ++ query_graphics ++ query_rest;

/// The probe with the graphics query left out. What `queryFor` sends under a
/// multiplexer.
pub const query_no_graphics = query_kitty_kbd ++ query_rest;

/// The bytes to send for this session. Skips the graphics query under a
/// multiplexer; see `query`'s comment for why sending it there is not just
/// useless but actively harmful.
pub fn queryFor(hint: Hint) []const u8 {
    return if (hint.multiplexer) query_no_graphics else query;
}

/// Read the concatenated replies. Anything unrecognised is skipped, because a
/// terminal is free to send what it likes and unknown bytes are a runtime fault and
/// not a programmer error.
pub fn parseReplies(bytes: []const u8, hint: Hint) Caps {
    var c = Caps{ .truecolor = hint.truecolor };

    // The kitty keyboard answer is CSI ? <flags> u. Look for the `u` terminator
    // on a CSI ? sequence that holds only digits and separators.
    c.kitty_keyboard = findCsiQuestion(bytes, 'u') != null;

    // The graphics answer must carry its terminator, so a cut reply reports nothing.
    // This matches the full literal and not just a `Gi=1` prefix and an `OK` suffix,
    // so a terminal that echoes extra key-value pairs before OK reads as unsupported
    // rather than supported. That is the safe direction: a missed true costs a
    // fallback render path, a wrong true sends a protocol the terminal cannot read.
    if (std.mem.indexOf(u8, bytes, ansi.apc ++ "Gi=1;OK" ++ ansi.st) != null) {
        c.kitty_graphics = !hint.multiplexer;
    }

    c.sync_output = decrpmSupported(bytes, 2026);
    c.inband_resize = decrpmSupported(bytes, 2048);
    c.sgr_pixel_mouse = decrpmSupported(bytes, 1016);

    return c;
}

/// Find a `CSI ? <digits and separators> <final>` sequence and return the digits.
/// Every loop pass either finds a shorter match starting further into `bytes` or
/// exhausts the slice, so this always terminates and never reads past the end.
///
/// `pub` because the terminal event loop reuses this to recognise the DA1 barrier
/// reply (`final = 'c'`) in its bounded read loop. One scanner and one set of
/// tests, so a fix here reaches every caller.
pub fn findCsiQuestion(bytes: []const u8, final: u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, i, ansi.csi ++ "?")) |start| {
        const body = start + 3;
        var end = body;
        while (end < bytes.len and (std.ascii.isDigit(bytes[end]) or bytes[end] == ';')) end += 1;
        if (end < bytes.len and bytes[end] == final and end > body) return bytes[body..end];
        i = start + 3;
    }
    return null;
}

/// DECRPM answers `CSI ? <mode> ; <state> $y`. The five states are:
///
///   0  the terminal does not know this mode
///   1  set, on right now
///   2  reset, off right now
///   3  permanently set
///   4  permanently reset, can never be turned on
///
/// The question this asks is whether the terminal KNOWS the mode, not whether the
/// mode is on right now. Every mode this probe queries is a toggle that starts off,
/// so a terminal with full support answers state 2, not 1. States 1, 2 and 3 all
/// mean the terminal recognises the mode and so all count as supported. Only 0
/// (unknown) and 4 (can never be turned on) count as unsupported.
fn decrpmSupported(bytes: []const u8, mode: u16) bool {
    var buf: [16]u8 = undefined;
    const prefix = std.fmt.bufPrint(buf[0..], ansi.csi ++ "?{d};", .{mode}) catch return false;
    const start = std.mem.indexOf(u8, bytes, prefix) orelse return false;
    const value_at = start + prefix.len;
    // The state must be exactly one digit followed by the '$' of the terminator.
    // Without the terminator check a reply of `;19$y` reads as state 1 and reports
    // the mode supported, which is the wrong-true this whole file exists to avoid.
    if (value_at + 1 >= bytes.len) return false;
    if (bytes[value_at + 1] != '$') return false;
    return switch (bytes[value_at]) {
        '1', '2', '3' => true,
        else => false,
    };
}

test "ghostty in TERM sets the full expectation" {
    const h = hintFromEnv("xterm-ghostty", null, "truecolor");
    try std.testing.expect(h.expect_graphics);
    try std.testing.expect(h.expect_kitty_kbd);
    try std.testing.expect(h.truecolor);
    try std.testing.expect(!h.multiplexer);
}

test "ghostty in TERM_PROGRAM sets the full expectation" {
    const h = hintFromEnv("xterm-256color", "ghostty", "24bit");
    try std.testing.expect(h.expect_graphics);
    try std.testing.expect(h.truecolor);
}

test "tmux is a multiplexer and expects no graphics" {
    const h = hintFromEnv("tmux-256color", "tmux", "truecolor");
    try std.testing.expect(h.multiplexer);
    try std.testing.expect(!h.expect_graphics);
    // Truecolor still passes through a multiplexer.
    try std.testing.expect(h.truecolor);
}

test "a plain xterm expects nothing and no truecolor" {
    const h = hintFromEnv("xterm-256color", null, null);
    try std.testing.expect(!h.expect_graphics);
    try std.testing.expect(!h.expect_kitty_kbd);
    try std.testing.expect(!h.truecolor);
}

test "a missing TERM does not crash and expects nothing" {
    const h = hintFromEnv(null, null, null);
    try std.testing.expect(!h.expect_graphics);
    try std.testing.expect(!h.multiplexer);
}

test "parseReplies reads a full ghostty answer" {
    const hint = hintFromEnv("xterm-ghostty", "ghostty", "truecolor");
    const replies =
        "\x1b[?1u" ++
        "\x1b_Gi=1;OK\x1b\\" ++
        "\x1b[?2026;1$y" ++
        "\x1b[?2048;1$y" ++
        "\x1b[?1016;1$y" ++
        "\x1b[?62;4c";
    const c = parseReplies(replies, hint);
    try std.testing.expect(c.kitty_keyboard);
    try std.testing.expect(c.kitty_graphics);
    try std.testing.expect(c.sync_output);
    try std.testing.expect(c.inband_resize);
    try std.testing.expect(c.sgr_pixel_mouse);
    try std.testing.expect(c.truecolor);
}

test "a terminal that answers DA1 only supports nothing beyond truecolor" {
    const hint = hintFromEnv("xterm-256color", null, "truecolor");
    const c = parseReplies("\x1b[?62;1c", hint);
    try std.testing.expect(!c.kitty_keyboard);
    try std.testing.expect(!c.kitty_graphics);
    try std.testing.expect(!c.sync_output);
    try std.testing.expect(!c.inband_resize);
    try std.testing.expect(c.truecolor);
}

test "DECRPM an unknown mode and a permanently reset mode both count as unsupported" {
    const hint = hintFromEnv("xterm-256color", null, null);
    // 0 means the terminal does not know the mode. 4 means permanently reset, which
    // can never be turned on. These are the only two states that mean unsupported.
    const c = parseReplies("\x1b[?2026;0$y\x1b[?2048;4$y\x1b[?62c", hint);
    try std.testing.expect(!c.sync_output);
    try std.testing.expect(!c.inband_resize);
}

test "DECRPM reports supported when a ghostty shaped reply answers reset, off right now" {
    const hint = hintFromEnv("xterm-ghostty", "ghostty", "truecolor");
    // A toggle that starts off and is fully supported answers state 2, not state 1.
    // This is the shape a real bare ghostty sent: reading only state 1 as supported
    // reported sync=false, inband_resize=false and sgr_pixel_mouse=false on a
    // terminal that has all three.
    const c = parseReplies("\x1b[?2026;2$y\x1b[?2048;2$y\x1b[?1016;2$y\x1b[?62;4c", hint);
    try std.testing.expect(c.sync_output);
    try std.testing.expect(c.inband_resize);
    try std.testing.expect(c.sgr_pixel_mouse);
}

test "DECRPM reports supported for a permanently set mode" {
    const hint = hintFromEnv("xterm-256color", null, null);
    const c = parseReplies("\x1b[?2026;3$y", hint);
    try std.testing.expect(c.sync_output);
}

test "DECRPM rejects a two digit state that starts with a valid digit" {
    const hint = hintFromEnv("xterm-256color", null, null);
    // State "19" is not one of the spec's states 0 to 4. A parser that reads only
    // the first digit would misread this as state 1 and report it supported.
    const c = parseReplies("\x1b[?2026;19$y", hint);
    try std.testing.expect(!c.sync_output);
}

test "DECRPM rejects a two digit state even when it starts with the other valid digit" {
    const hint = hintFromEnv("xterm-256color", null, null);
    // State "31" starts with 3, which alone would be a valid permanently-set state.
    // A fix that only special cased a leading 1 would still misread this one.
    const c = parseReplies("\x1b[?2026;31$y", hint);
    try std.testing.expect(!c.sync_output);
}

test "DECRPM reports unsupported when the reply is cut before the terminator" {
    const hint = hintFromEnv("xterm-256color", null, null);
    const c = parseReplies("\x1b[?2026;1", hint);
    try std.testing.expect(!c.sync_output);
}

test "DECRPM still reports a single digit state followed by its terminator as set" {
    const hint = hintFromEnv("xterm-256color", null, null);
    const c = parseReplies("\x1b[?2026;1$y", hint);
    try std.testing.expect(c.sync_output);
}

test "a truncated reply is dropped and does not report a capability" {
    const hint = hintFromEnv("xterm-ghostty", "ghostty", null);
    // The graphics answer is cut before its terminator.
    const c = parseReplies("\x1b_Gi=1;O", hint);
    try std.testing.expect(!c.kitty_graphics);
}

test "a multiplexer suppresses graphics even when the reply claims it" {
    const hint = hintFromEnv("tmux-256color", "tmux", null);
    const c = parseReplies("\x1b_Gi=1;OK\x1b\\\x1b[?62c", hint);
    // tmux does not pass the protocol through reliably, so the hint wins here.
    try std.testing.expect(!c.kitty_graphics);
}

test "queryFor leaves the graphics probe out under a multiplexer" {
    const hint = hintFromEnv("tmux-256color", "tmux", null);
    const q = queryFor(hint);
    // Sending it would achieve nothing (parseReplies ignores the answer under a
    // multiplexer regardless) and tmux does not parse the APC form: it leaked the
    // query's own printable payload into the status line on a real tmux session.
    try std.testing.expect(std.mem.indexOf(u8, q, "Gi=1,s=1") == null);
    // The rest of the probe, including DA1, must still go out.
    try std.testing.expect(std.mem.indexOf(u8, q, ansi.csi ++ "?u") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, ansi.csi ++ "c") != null);
}

test "queryFor sends the full probe, graphics included, outside a multiplexer" {
    const hint = hintFromEnv("xterm-ghostty", "ghostty", "truecolor");
    const q = queryFor(hint);
    try std.testing.expect(std.mem.indexOf(u8, q, "Gi=1,s=1") != null);
}

test "findCsiQuestion skips a CSI ? sequence with the wrong terminator and keeps looking" {
    const hint = hintFromEnv("xterm-256color", null, null);
    // The DA1 answer is a CSI ? sequence that ends in 'c', not 'u'. The scan must not
    // stop there: it has to carry on and find the real kitty keyboard answer after it.
    const c = parseReplies("\x1b[?62;1c\x1b[?1u", hint);
    try std.testing.expect(c.kitty_keyboard);
}

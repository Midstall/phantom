//! Terminal bytes to events. Every byte here is untrusted input from a terminal, so
//! a sequence that does not parse is dropped and counted, and never asserted on.
const std = @import("std");
const input = @import("../input.zig");

pub const buffer_size = 4096;

pub const MouseKind = enum { move, down, up, scroll };

pub const MouseEvent = struct {
    kind: MouseKind,
    button: u3 = 0,
    /// Cell coordinates, zero based. Pixel coordinates when `pixels` is true, which
    /// happens only when mode 1016 is on.
    x: u16 = 0,
    y: u16 = 0,
    pixels: bool = false,
    mods: input.Mods = .{},
    scroll_dx: f32 = 0,
    scroll_dy: f32 = 0,
};

pub const Event = union(enum) {
    key: input.KeyEvent,
    mouse: MouseEvent,
    /// Borrows the decoder's own paste storage, valid until the next `feed` or
    /// `next` call, the same rule `KeyEvent.text` follows.
    paste: []const u8,
    resize: @import("term.zig").Size,
};

/// One wheel notch. The scroll view reads pixels, and a terminal reports notches, so
/// one notch becomes three lines of the current cell height at the call site.
const notch: f32 = 1;

/// The bracketed paste closing marker. `parsePaste`, `discardPaste` and `feed`'s
/// overflow guard all need to agree on it: any one of them dropping a byte the
/// others expect to see would leave the other two unable to ever find it.
const paste_close = "\x1b[201~";

pub const Decoder = struct {
    buf: [buffer_size]u8 = undefined,
    len: usize = 0,
    /// Storage for `KeyEvent.text`. One codepoint is at most 4 bytes. The event
    /// borrows this, so it stays valid only until the next `next` call, which is
    /// the same rule `TextRun.text` follows.
    text_buf: [4]u8 = undefined,
    /// Storage for `Event.paste`. `next` consumes the parsed bytes out of `buf`
    /// before it returns the event, which shifts `buf` in place, so a paste slice
    /// pointing into `buf` itself would already be corrupt by the time the caller
    /// reads it. Copying the body here first, the same way `text_buf` stands in
    /// for `buf` on the key path, keeps it stable.
    paste_buf: [buffer_size]u8 = undefined,
    /// How many byte sequences were dropped because they did not parse: bad digits,
    /// a missing terminator, a truncated report. This is a genuine protocol fault
    /// and the loop reports it. It does NOT count a sequence that parsed fine but
    /// names a key this enum has no keysym for yet (see `unmapped`): a terminal
    /// reporting a real, legitimate key is not malformed input, and counting it as
    /// one turns something as ordinary as holding shift into a false fault report.
    dropped: u32 = 0,
    /// How many sequences parsed correctly but named a key with no keysym yet (for
    /// example, most of the kitty private-use block: caps lock, the media keys,
    /// F13 and up). Not a fault, so the loop never reports it to the sink. Kept
    /// separate from `dropped` so a test or a human can tell "the terminal spoke
    /// wrongly" apart from "we do not have a mapping for this key yet".
    unmapped: u32 = 0,
    /// The raw bytes of the most recently DROPPED (malformed) sequence, up to this
    /// many. A drop count with no bytes attached gives a human nothing to debug
    /// against, so the loop logs this alongside the count. Only the latest is kept:
    /// logging every one would flood the log the same way the on-screen warning used
    /// to flood the display.
    last_dropped: [32]u8 = undefined,
    last_dropped_len: u8 = 0,
    /// True when mode 1016 is on, which makes the terminal report pixels.
    pixels: bool = false,
    /// True when the caller knows no more bytes are coming for now, which turns a
    /// lone escape byte into the escape key instead of the start of a sequence.
    pending_escape: bool = false,
    /// True when a paste ran past the buffer without its closing marker. The
    /// bytes that follow are still paste content and must never be parsed as
    /// keys, or an oversized paste types itself into whatever holds the focus.
    /// The state clears when the closing marker finally arrives.
    discarding_paste: bool = false,

    pub fn flushPending(self: *Decoder) void {
        self.pending_escape = true;
    }

    pub fn feed(self: *Decoder, bytes: []const u8) void {
        // A flush only applies to bytes already buffered when it was called. New
        // bytes start a fresh sequence, so an armed flush must not fire on their
        // leading escape. An empty feed brings no new bytes, so it must not cancel
        // an armed flush either, or an idle poll would swallow a real Escape press.
        if (bytes.len > 0) self.pending_escape = false;
        const room = self.buf.len - self.len;
        if (bytes.len > room) {
            // A terminal cannot send more than the buffer holds in one useful
            // sequence, so an overflow means the buffer holds junk. Drop it all
            // rather than growing without limit.
            //
            // Contract: a single `feed` call must stay smaller than `buffer_size`.
            // A call larger than the whole buffer can truncate a bracketed
            // paste's closing marker beyond recovery while `discarding_paste` is
            // set (see `dropOverlap`); callers must split large reads into
            // chunks smaller than `buffer_size` before feeding them in.
            self.dropped += 1;
            if (self.discarding_paste) {
                // The buffer's tail may be the start of the closing marker, split
                // right across this boundary. The plain reset below keeps only
                // the newest bytes of THIS write and would erase that tail,
                // which could strand `discarding_paste` forever: the terminal
                // never resends a marker once it is past it. Keep the tail, and
                // take the new bytes in the order they arrived, from their
                // start, so the marker stays contiguous if it spans the join.
                var carry: [paste_close.len - 1]u8 = undefined;
                const carry_len = @min(self.len, carry.len);
                @memcpy(carry[0..carry_len], self.buf[self.len - carry_len .. self.len]);
                @memcpy(self.buf[0..carry_len], carry[0..carry_len]);
                const take = @min(bytes.len, self.buf.len - carry_len);
                @memcpy(self.buf[carry_len..][0..take], bytes[0..take]);
                self.len = carry_len + take;
                return;
            }
            self.len = 0;
            const take = @min(bytes.len, self.buf.len);
            @memcpy(self.buf[0..take], bytes[bytes.len - take ..]);
            self.len = take;
            return;
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn consume(self: *Decoder, n: usize) void {
        const keep = self.len - n;
        std.mem.copyForwards(u8, self.buf[0..keep], self.buf[n..self.len]);
        self.len = keep;
    }

    /// The next event, or null when the buffer holds no complete sequence. A buffer
    /// that is full and still holds no event is junk, so it resets.
    pub fn next(self: *Decoder) ?Event {
        while (self.len > 0) {
            if (self.parseOne()) |result| {
                self.consume(result.consumed);
                if (result.event) |ev| return ev;
                continue; // a dropped sequence, try the next one
            }
            // Incomplete. Wait for more bytes, unless the buffer cannot hold more.
            if (self.len >= self.buf.len) {
                self.dropped += 1;
                self.len = 0;
            }
            return null;
        }
        return null;
    }

    const ParseResult = struct { consumed: usize, event: ?Event };

    /// Null means the buffer holds the start of a sequence and needs more bytes.
    /// A result with a null event means the bytes were consumed and dropped.
    fn parseOne(self: *Decoder) ?ParseResult {
        if (self.discarding_paste) return self.discardPaste();
        const b = self.buf[0..self.len];
        if (b[0] != 0x1b) return self.parseText();
        if (b.len < 2) {
            // A lone escape byte is ambiguous: it may be the start of a sequence
            // whose rest has not arrived yet. Only report it as the escape key once
            // the caller has flushed, which is `parseText`'s job.
            if (!self.pending_escape) return null;
            return self.parseText();
        }
        if (b[1] == '[') return self.parseCsi();
        return self.parseEsc();
    }

    fn parseCsi(self: *Decoder) ?ParseResult {
        const b = self.buf[0..self.len];
        if (b.len < 3) return null;
        if (b[2] == '<') return self.parseSgrMouse();
        return self.parseCsiKey();
    }

    /// `CSI < button ; col ; row M` for a press or a motion, and `m` for a release.
    fn parseSgrMouse(self: *Decoder) ?ParseResult {
        const b = self.buf[0..self.len];
        var i: usize = 3;
        while (i < b.len and b[i] != 'M' and b[i] != 'm') : (i += 1) {
            // A sequence this long is not a mouse report, so stop looking rather than
            // scanning the whole buffer for a terminator that is not coming.
            if (i > 32) return self.drop(i);
        }
        if (i >= b.len) return null; // no terminator yet

        const final = b[i];
        const body = b[3..i];
        const consumed = i + 1;

        var it = std.mem.splitScalar(u8, body, ';');
        const code = parseU32(it.next() orelse return self.drop(consumed)) orelse return self.drop(consumed);
        const raw_x = parseU32(it.next() orelse return self.drop(consumed)) orelse return self.drop(consumed);
        const raw_y = parseU32(it.next() orelse return self.drop(consumed)) orelse return self.drop(consumed);
        if (it.next() != null) return self.drop(consumed);

        // The terminal reports one based coordinates. A zero is malformed, and a
        // value that does not fit a u16 is malformed as well.
        if (raw_x == 0 or raw_y == 0) return self.drop(consumed);
        const x = std.math.cast(u16, raw_x - 1) orelse return self.drop(consumed);
        const y = std.math.cast(u16, raw_y - 1) orelse return self.drop(consumed);

        var ev = MouseEvent{
            .kind = .move,
            .x = x,
            .y = y,
            .pixels = self.pixels,
            .mods = .{
                .shift = (code & 4) != 0,
                .alt = (code & 8) != 0,
                .ctrl = (code & 16) != 0,
            },
        };

        if ((code & 64) != 0) {
            ev.kind = .scroll;
            // 64 is up, 65 is down, 66 is left and 67 is right. Up is a negative
            // vertical delta, which matches the scroll view's content offset.
            switch (code & 3) {
                0 => ev.scroll_dy = -notch,
                1 => ev.scroll_dy = notch,
                2 => ev.scroll_dx = -notch,
                3 => ev.scroll_dx = notch,
                else => unreachable, // masked to two bits above
            }
        } else if ((code & 32) != 0) {
            ev.kind = .move;
        } else {
            ev.kind = if (final == 'M') .down else .up;
            ev.button = @intCast(code & 3);
        }

        return .{ .consumed = consumed, .event = .{ .mouse = ev } };
    }

    fn drop(self: *Decoder, consumed: usize) ParseResult {
        self.dropped += 1;
        // `consumed` is bounded by `self.len` at every call site, but this is
        // untrusted-input bookkeeping, so it is re-clamped here rather than trusted.
        const n = @min(@min(consumed, self.last_dropped.len), self.len);
        @memcpy(self.last_dropped[0..n], self.buf[0..n]);
        self.last_dropped_len = @intCast(n);
        return .{ .consumed = consumed, .event = null };
    }

    /// The sequence parsed correctly but names a key with no keysym yet: a real,
    /// legitimate report from the terminal, not a protocol violation. Consumed the
    /// same way a drop is, so the decoder does not stall, but counted separately so
    /// the loop never mistakes an ordinary unmapped key for a fault.
    fn unmappedKey(self: *Decoder, consumed: usize) ParseResult {
        self.unmapped += 1;
        return .{ .consumed = consumed, .event = null };
    }

    fn parseU32(s: []const u8) ?u32 {
        if (s.len == 0) return null;
        return std.fmt.parseInt(u32, s, 10) catch null;
    }

    /// `CSI ... final`, which covers the arrows, the tilde keys, the kitty form and
    /// bracketed paste.
    fn parseCsiKey(self: *Decoder) ?ParseResult {
        const b = self.buf[0..self.len];
        var i: usize = 2;
        // The parameter bytes of a CSI sequence are 0x30 to 0x3F and the intermediate
        // bytes are 0x20 to 0x2F. Anything else ends it.
        while (i < b.len and ((b[i] >= 0x30 and b[i] <= 0x3F) or (b[i] >= 0x20 and b[i] <= 0x2F))) : (i += 1) {
            if (i > 64) return self.drop(i);
        }
        if (i >= b.len) return null; // no final byte yet
        const final = b[i];
        const params = b[2..i];
        const consumed = i + 1;

        // Bracketed paste opens with CSI 200 ~ and closes with CSI 201 ~.
        if (final == '~' and std.mem.eql(u8, params, "200")) return self.parsePaste(consumed);

        // The in-band resize report is CSI 48 ; rows ; cols ; ypixel ; xpixel t.
        // CSI ... t is a whole family of window reports (position, state, title
        // and more), and only the one that leads with 48 is a resize. Reading a
        // different report as a size would resize the grid to nonsense, so any
        // other leading number here falls through to `drop` rather than `return`.
        if (final == 't') {
            var it = std.mem.splitScalar(u8, params, ';');
            const kind = std.fmt.parseInt(u32, it.next() orelse "", 10) catch return self.drop(consumed);
            if (kind != 48) return self.drop(consumed);
            const rows = nextU16(&it) orelse return self.drop(consumed);
            const cols = nextU16(&it) orelse return self.drop(consumed);
            const ypixel = nextU16(&it) orelse 0;
            const xpixel = nextU16(&it) orelse 0;
            return .{ .consumed = consumed, .event = .{ .resize = .{
                .cols = cols,
                .rows = rows,
                .xpixel = xpixel,
                .ypixel = ypixel,
            } } };
        }

        var action = input.KeyAction.press;
        var first: u32 = 0;
        var second: u32 = 0;
        parseParams(params, &first, &second, &action);
        var mods = modsFromCode(second);

        const sym: ?input.Keysym = switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            'Z' => blk: {
                // Back tab is shift and tab, and it carries no modifier parameter.
                mods.shift = true;
                break :blk .tab;
            },
            'u' => kittyKeysym(first),
            '~' => switch (first) {
                1, 7 => .home,
                2 => .insert,
                3 => .delete,
                4, 8 => .end,
                5 => .page_up,
                6 => .page_down,
                11...15 => functionKey(first - 10),
                17...21 => functionKey(first - 11),
                23...26 => functionKey(first - 12),
                else => null,
            },
            else => null,
        };

        const keysym = sym orelse return self.unmappedKey(consumed);

        // A key reports text only when it produces one and no ctrl or alt is held.
        // A text field inserts `text` blindly, so a shortcut must never carry any.
        var text: ?[]const u8 = null;
        if (!mods.ctrl and !mods.alt) {
            if (keysym.toCodepoint()) |cp| {
                const n = std.unicode.utf8Encode(cp, &self.text_buf) catch 0;
                if (n > 0) text = self.text_buf[0..n];
            }
        }

        return .{ .consumed = consumed, .event = .{ .key = .{
            .keysym = keysym,
            .text = text,
            .mods = mods,
            .action = action,
        } } };
    }

    fn parsePaste(self: *Decoder, body_start: usize) ?ParseResult {
        const b = self.buf[0..self.len];
        const end = std.mem.indexOfPos(u8, b, body_start, paste_close) orelse {
            if (self.len < self.buf.len) return null; // still room, wait for more
            // The buffer filled up before the closing marker arrived. Falling
            // back to normal parsing here would read the rest of the paste as
            // key presses and type it into whatever holds the focus, so drop
            // what is buffered and keep discarding until the marker turns up.
            // `dropOverlap` keeps the closing marker's worth of tail: the marker
            // itself may straddle this exact boundary, and losing that partial
            // match would stall `discarding_paste` forever, since the terminal
            // never resends a marker once it is past it.
            self.discarding_paste = true;
            return self.dropOverlap();
        };
        const body_len = end - body_start;
        // Copy out to `paste_buf` before the caller ever sees the slice: `next`
        // consumes and shifts `buf` before returning the event, which would
        // otherwise overwrite the very bytes this event points at.
        @memcpy(self.paste_buf[0..body_len], b[body_start..end]);
        return .{
            .consumed = end + paste_close.len,
            .event = .{ .paste = self.paste_buf[0..body_len] },
        };
    }

    /// Reached only while `discarding_paste` is set, which means an earlier
    /// paste ran off the end of the buffer before its closing marker arrived.
    /// Every byte here is still paste content until that marker shows up, so it
    /// is discarded rather than handed to the normal parsers.
    fn discardPaste(self: *Decoder) ?ParseResult {
        const b = self.buf[0..self.len];
        if (std.mem.indexOf(u8, b, paste_close)) |pos| {
            self.discarding_paste = false;
            return .{ .consumed = pos + paste_close.len, .event = null };
        }
        if (self.len < self.buf.len) return null; // wait, the marker may still complete
        // Another full buffer with no marker: drop it, keeping the tail, and
        // keep discarding. See `parsePaste`'s matching branch for why the tail
        // survives.
        return self.dropOverlap();
    }

    /// Drops the buffer down to just the closing marker's worth of tail, the
    /// same retention `parsePaste` and `discardPaste` both need so a marker
    /// split across this exact boundary can still complete on the next feed.
    fn dropOverlap(self: *Decoder) ParseResult {
        return self.drop(self.len - (paste_close.len - 1));
    }

    /// `ESC O <final>` for the first four function keys, and `ESC <char>` for alt.
    fn parseEsc(self: *Decoder) ?ParseResult {
        const b = self.buf[0..self.len];
        if (b.len < 2) return null;
        if (b[1] == 'O') {
            if (b.len < 3) return null;
            const sym: ?input.Keysym = switch (b[2]) {
                'P' => .f1,
                'Q' => .f2,
                'R' => .f3,
                'S' => .f4,
                else => null,
            };
            const f = sym orelse return self.unmappedKey(3);
            return .{ .consumed = 3, .event = .{ .key = .{ .keysym = f } } };
        }
        // The C1 string sequences: OSC `]`, DCS `P`, PM `^`, SOS `X` and APC `_`,
        // each `ESC <introducer> ... ST`. The startup probe's kitty graphics query
        // answers in APC form, and the probe stops reading the instant DA1 (last
        // in the query string) matches, so a reply still in flight at that exact
        // moment is not consumed by it and lands here on the next read instead.
        // Every introducer byte here is printable, so without this check any of
        // the five would fall through to the plain ESC+printable case below and
        // misread a reply as a garbage keystroke: APC is the one with a live
        // trigger today (that bug was real and is what this guards against), but
        // a terminal is free to send an unsolicited OSC reply with no query from
        // us at all, and it is the same bug with a different first byte. Consumed
        // and discarded instead: a stray reply is a well formed sequence, not
        // garbage, and not a key.
        if (std.mem.indexOfScalar(u8, "]P^X_", b[1]) != null) return self.parseStringSeq();
        // ESC then a printable byte is the alt modifier on that key. Alt held means
        // a shortcut, so it carries no text.
        const cp = b[1];
        if (cp >= 0x20 and cp < 0x7F) {
            return .{
                .consumed = 2,
                .event = .{ .key = .{
                    .keysym = input.Keysym.fromCodepoint(cp),
                    .mods = .{ .alt = true },
                } },
            };
        }
        return self.drop(2);
    }

    /// `ESC <introducer> ... ST`, where ST is `ESC \`, for any of the five C1
    /// string sequences (OSC, DCS, PM, SOS, APC). Consumed whole and discarded:
    /// nothing reads any of these bodies today, so there is no event to report,
    /// only bytes to skip cleanly rather than misread as literal keys.
    fn parseStringSeq(self: *Decoder) ?ParseResult {
        const b = self.buf[0..self.len];
        const st = "\x1b\\";
        const end = std.mem.indexOfPos(u8, b, 2, st) orelse {
            if (self.len < self.buf.len) return null; // still room, wait for the rest
            // A terminator that never arrives before the buffer fills is genuinely
            // malformed (or absurdly long), unlike a straggler reply that simply
            // has not finished yet.
            return self.drop(self.len);
        };
        return .{ .consumed = end + st.len, .event = null };
    }

    fn parseText(self: *Decoder) ?ParseResult {
        const b = self.buf[0..self.len];
        const c = b[0];

        if (c == 0x1b) {
            // Reached only when the buffer holds one escape byte and nothing else,
            // and the caller has flushed to say no more bytes are coming.
            self.pending_escape = false;
            return .{ .consumed = 1, .event = .{ .key = .{ .keysym = .escape } } };
        }
        if (c == '\r' or c == '\n') return .{ .consumed = 1, .event = .{ .key = .{ .keysym = .enter } } };
        if (c == '\t') return .{ .consumed = 1, .event = .{ .key = .{ .keysym = .tab } } };
        if (c == 0x7F or c == 0x08) return .{ .consumed = 1, .event = .{ .key = .{ .keysym = .backspace } } };
        if (c < 0x20) {
            // A control byte is the letter it maps to with ctrl held. 0x01 is ctrl
            // and a, so the letter is the byte plus 0x60. It inserts no text.
            return .{
                .consumed = 1,
                .event = .{ .key = .{
                    .keysym = input.Keysym.fromCodepoint(@as(u21, c) + 0x60),
                    .mods = .{ .ctrl = true },
                } },
            };
        }

        const seq_len = std.unicode.utf8ByteSequenceLength(c) catch return self.drop(1);
        if (b.len < seq_len) return null; // the rest of the codepoint has not arrived
        const cp = std.unicode.utf8Decode(b[0..seq_len]) catch return self.drop(seq_len);
        // The text points at the decoder's own buffer and not at `b`, because `b`
        // is about to be consumed and shifted down.
        @memcpy(self.text_buf[0..seq_len], b[0..seq_len]);
        return .{ .consumed = seq_len, .event = .{ .key = .{
            .keysym = input.Keysym.fromCodepoint(cp),
            .text = self.text_buf[0..seq_len],
        } } };
    }
};

/// One resize report field: an unsigned decimal that fits a u16, or null when the
/// field is missing (the iterator is exhausted) or malformed. A missing pixel
/// field is a valid, common report, so `parseCsiKey` gives it a default; a
/// missing cell field is not, so `parseCsiKey` drops the whole sequence instead.
fn nextU16(it: *std.mem.SplitIterator(u8, .scalar)) ?u16 {
    const s = it.next() orelse return null;
    const v = std.fmt.parseInt(u32, s, 10) catch return null;
    return std.math.cast(u16, v);
}

/// The kitty and xterm modifier parameter is 1 plus a bit set: 1 shift, 2 alt,
/// 4 ctrl and 8 super. A zero or a one means no modifier.
fn modsFromCode(code: u32) input.Mods {
    if (code < 2) return .{};
    const bits = code - 1;
    return .{
        .shift = (bits & 1) != 0,
        .alt = (bits & 2) != 0,
        .ctrl = (bits & 4) != 0,
        .super = (bits & 8) != 0,
    };
}

/// `CSI <first> ; <second> [: <event>] <final>`. A missing parameter keeps its
/// default, because a terminal omits what it does not need to say.
///
/// `first` is read as one plain integer. The kitty protocol also allows an
/// extended form on that field, `unicode-key-code:shifted-key:base-layout-key`,
/// which nothing here requests. If a terminal ever sends it, `parseInt` fails
/// on the colon and the key is dropped rather than misread.
fn parseParams(params: []const u8, first: *u32, second: *u32, action: *input.KeyAction) void {
    var it = std.mem.splitScalar(u8, params, ';');
    if (it.next()) |p| first.* = std.fmt.parseInt(u32, p, 10) catch 0;
    if (it.next()) |p| {
        var sub = std.mem.splitScalar(u8, p, ':');
        if (sub.next()) |m| second.* = std.fmt.parseInt(u32, m, 10) catch 1;
        if (sub.next()) |e| {
            const n = std.fmt.parseInt(u32, e, 10) catch 1;
            action.* = switch (n) {
                2 => .repeat,
                3 => .release,
                // 1 is a press, and an unknown value is treated as a press because a
                // dropped key press is worse than a wrong action tag.
                else => .press,
            };
        }
    }
}

/// The kitty keyboard protocol names a key by the codepoint it produces. The control
/// codepoints map to the named keysyms, and everything else becomes a unicode
/// keysym.
///
/// Checked against the kitty keyboard protocol's functional key table
/// (`docs/keyboard-protocol.rst` in kovidgoyal/kitty): ENTER is 13, ESCAPE is 27,
/// TAB is 9 and BACKSPACE is 127, confirmed. The arrows, insert, delete, home, end,
/// page up, page down and F1 through F12 are NOT in this table: kitty reports those
/// with the legacy CSI letter and tilde forms that `parseCsiKey` already handles, so
/// this function never sees them. Everything from 57344 to 63743 is the protocol's
/// private use block (caps lock, scroll lock, num lock, print screen, pause, menu,
/// hyper, meta, F13 and up, the keypad keys, media keys and the bare modifier keys).
///
/// Flag 2 (report events, on since Task 20's flags-3 push) makes a bare modifier
/// press report itself: holding shift alone sends its own key event. Found on a
/// real bare ghostty, where it showed up as a false "terminal input sequences
/// dropped" fault on every shift press, because this function used to drop the
/// whole private-use block with no exceptions. The eight bare modifier codepoints
/// (LEFT/RIGHT SHIFT, CONTROL, ALT, SUPER; kitty's functional key table) now map to
/// their real X11 keysyms, checked against `keysymdef.h`: Shift_L 0xFFE1, Shift_R
/// 0xFFE2, Control_L 0xFFE3, Control_R 0xFFE4, Alt_L 0xFFE9, Alt_R 0xFFEA, Super_L
/// 0xFFEB, Super_R 0xFFEC. A compositor path delivers these too, so mapping them to
/// the shared X11 keysym is the cross backend answer, not a terminal special case.
///
/// Hyper, Meta, and the rest of the block (caps lock, scroll lock, num lock, print
/// screen, pause, menu, F13 and up, the keypad keys, media keys) still have no
/// keysym in this enum, so they are left unmapped for lack of evidence rather than
/// guessed at: `Keysym.fromCodepoint` would otherwise turn one into a plausible
/// looking but wrong unicode keysym, and a wrong number here maps a real key to the
/// wrong action. Returning null for those is not a protocol fault, since the
/// sequence parsed correctly; the caller counts a null result as `unmapped`, never
/// as `dropped`.
fn kittyKeysym(cp: u32) ?input.Keysym {
    return switch (cp) {
        13 => .enter,
        27 => .escape,
        9 => .tab,
        127 => .backspace,
        57441 => .shift_l,
        57442 => .control_l,
        57443 => .alt_l,
        57444 => .super_l,
        57447 => .shift_r,
        57448 => .control_r,
        57449 => .alt_r,
        57450 => .super_r,
        // The rest of the private use block: 57344 to 57440 before the mapped run
        // above, 57445 to 57446 (hyper) and 57451 to 63743 (meta onward) after it.
        0xE000...0xE060, 0xE065...0xE066, 0xE06B...0xF8FF => null,
        else => blk: {
            const c = std.math.cast(u21, cp) orelse break :blk null;
            if (c < 0x20) break :blk null;
            break :blk input.Keysym.fromCodepoint(c);
        },
    };
}

/// Function key `n`, 1 based. Returns null outside the range the enum names, so a
/// terminal reporting F13 is left unmapped rather than turned into a wrong
/// keysym. The sequence still parsed correctly, so the caller counts this as
/// `unmapped`, never as `dropped`, the same distinction `kittyKeysym`'s doc
/// comment makes.
///
/// The tilde numbers that reach here are checked against the kitty keyboard
/// protocol's functional key table, which also matches the classic xterm and
/// VT220 conventions: F1 is 11, F2 is 12, F3 is 13, F4 is 14, F5 is 15 (16 is not
/// assigned), F6 is 17, F7 is 18, F8 is 19, F9 is 20, F10 is 21 (22 is not
/// assigned), F11 is 23, F12 is 24. 25 and 26 are not part of that table; the
/// range that includes them still resolves through `n > 12` below and leaves
/// them unmapped, so carrying them in the switch causes no wrong mapping.
fn functionKey(n: u32) ?input.Keysym {
    if (n < 1 or n > 12) return null;
    return @enumFromInt(@intFromEnum(input.Keysym.f1) + (n - 1));
}

test "an SGR press reports a zero based cell position" {
    var d = Decoder{};
    d.feed("\x1b[<0;10;5M");
    const ev = d.next().?;
    try std.testing.expectEqual(MouseKind.down, ev.mouse.kind);
    try std.testing.expectEqual(@as(u16, 9), ev.mouse.x);
    try std.testing.expectEqual(@as(u16, 4), ev.mouse.y);
    try std.testing.expectEqual(@as(u3, 0), ev.mouse.button);
}

test "a lower case final byte is a release" {
    var d = Decoder{};
    d.feed("\x1b[<0;10;5m");
    try std.testing.expectEqual(MouseKind.up, d.next().?.mouse.kind);
}

test "bit five marks a motion report" {
    var d = Decoder{};
    d.feed("\x1b[<35;3;3M");
    try std.testing.expectEqual(MouseKind.move, d.next().?.mouse.kind);
}

test "bit six marks a wheel report and gives the direction" {
    var d = Decoder{};
    d.feed("\x1b[<64;1;1M");
    const up = d.next().?;
    try std.testing.expectEqual(MouseKind.scroll, up.mouse.kind);
    try std.testing.expect(up.mouse.scroll_dy < 0);

    d.feed("\x1b[<65;1;1M");
    const down = d.next().?;
    try std.testing.expect(down.mouse.scroll_dy > 0);
}

test "the modifier bits reach the event" {
    var d = Decoder{};
    // 16 is ctrl, so 16 + button 0 is a ctrl click.
    d.feed("\x1b[<16;1;1M");
    const ev = d.next().?;
    try std.testing.expect(ev.mouse.mods.ctrl);
    try std.testing.expect(!ev.mouse.mods.shift);
}

test "a sequence split across two reads decodes as one event" {
    var d = Decoder{};
    d.feed("\x1b[<0;10");
    try std.testing.expect(d.next() == null);
    d.feed(";5M");
    const ev = d.next().?;
    try std.testing.expectEqual(MouseKind.down, ev.mouse.kind);
    try std.testing.expectEqual(@as(u16, 9), ev.mouse.x);
}

test "two events in one read decode one after the other" {
    var d = Decoder{};
    d.feed("\x1b[<0;1;1M\x1b[<0;2;2m");
    try std.testing.expectEqual(MouseKind.down, d.next().?.mouse.kind);
    try std.testing.expectEqual(MouseKind.up, d.next().?.mouse.kind);
    try std.testing.expect(d.next() == null);
}

test "a malformed sequence is dropped, counted, and does not stall the decoder" {
    var d = Decoder{};
    // No final byte and a letter where a digit belongs.
    d.feed("\x1b[<zz;;M\x1b[<0;1;1M");
    // The decoder must still find the valid event that follows the broken one.
    var found = false;
    var guard: u8 = 0;
    while (guard < 8) : (guard += 1) {
        const ev = d.next() orelse break;
        if (ev == .mouse and ev.mouse.kind == .down) found = true;
    }
    try std.testing.expect(found);
    try std.testing.expect(d.dropped > 0);
}

test "a dropped sequence keeps its raw bytes for a human to read later" {
    // A drop count with nothing attached gives a human nothing to debug against
    // (this is what a live capture would have needed to confirm Bug 2 without
    // guessing). `drop` must save the bytes it actually saw.
    var d = Decoder{};
    d.feed("\x1b[<zz;;M");
    _ = d.next();
    try std.testing.expect(d.dropped > 0);
    try std.testing.expect(d.last_dropped_len > 0);
    try std.testing.expectEqualStrings("\x1b[<zz;;M", d.last_dropped[0..d.last_dropped_len]);
}

test "a coordinate larger than u16 is rejected instead of wrapping" {
    var d = Decoder{};
    d.feed("\x1b[<0;99999999;1M");
    // Untrusted input: the parse fails and the sequence is dropped, and the decoder
    // does not report a position that wrapped around.
    _ = d.next();
    try std.testing.expect(d.dropped > 0);
}

test "a full buffer with no event is dropped so the decoder cannot wedge" {
    var d = Decoder{};
    var junk: [buffer_size]u8 = undefined;
    @memset(&junk, 0x1b);
    d.feed(&junk);
    try std.testing.expect(d.next() == null);
    // The buffer was full of partial escapes, so it resets instead of blocking.
    try std.testing.expectEqual(@as(usize, 0), d.len);
    try std.testing.expect(d.dropped > 0);
}

test "a plain ASCII byte is a printable keysym and carries its text" {
    var d = Decoder{};
    d.feed("a");
    const ev = d.next().?;
    try std.testing.expectEqual(input.Keysym.fromCodepoint('a'), ev.key.keysym);
    try std.testing.expectEqualStrings("a", ev.key.text.?);
    try std.testing.expect(ev.key.mods.none());
}

test "a UTF-8 codepoint decodes as one key with its text" {
    var d = Decoder{};
    d.feed("\u{00E9}"); // e with an acute accent, two bytes
    const ev = d.next().?;
    try std.testing.expectEqual(@as(?u21, 0xE9), ev.key.keysym.toCodepoint());
    try std.testing.expectEqualStrings("\u{00E9}", ev.key.text.?);
}

test "a partial UTF-8 sequence waits for the rest instead of decoding junk" {
    var d = Decoder{};
    d.feed("\xC3"); // the first byte of a two byte sequence
    try std.testing.expect(d.next() == null);
    d.feed("\xA9");
    try std.testing.expectEqual(@as(?u21, 0xE9), d.next().?.key.keysym.toCodepoint());
}

test "a control byte is the letter with the ctrl modifier and produces no text" {
    var d = Decoder{};
    d.feed("\x01");
    const ev = d.next().?;
    try std.testing.expectEqual(input.Keysym.fromCodepoint('a'), ev.key.keysym);
    try std.testing.expect(ev.key.mods.ctrl);
    // Ctrl and a inserts nothing into a text field, so the text must be null.
    try std.testing.expect(ev.key.text == null);
}

test "carriage return, tab and backspace are named keysyms and carry no text" {
    var d = Decoder{};
    d.feed("\r\t\x7F");
    const enter = d.next().?;
    try std.testing.expectEqual(input.Keysym.enter, enter.key.keysym);
    try std.testing.expect(enter.key.text == null);
    try std.testing.expectEqual(input.Keysym.tab, d.next().?.key.keysym);
    try std.testing.expectEqual(input.Keysym.backspace, d.next().?.key.keysym);
}

test "the arrow keys decode from the legacy form" {
    var d = Decoder{};
    d.feed("\x1b[A\x1b[B\x1b[C\x1b[D");
    try std.testing.expectEqual(input.Keysym.up, d.next().?.key.keysym);
    try std.testing.expectEqual(input.Keysym.down, d.next().?.key.keysym);
    try std.testing.expectEqual(input.Keysym.right, d.next().?.key.keysym);
    try std.testing.expectEqual(input.Keysym.left, d.next().?.key.keysym);
}

test "a modified arrow carries the modifier" {
    var d = Decoder{};
    d.feed("\x1b[1;5A"); // 5 is 1 + ctrl
    const ev = d.next().?;
    try std.testing.expectEqual(input.Keysym.up, ev.key.keysym);
    try std.testing.expect(ev.key.mods.ctrl);
    try std.testing.expect(!ev.key.mods.shift);
}

test "shift and tab decode as a back tab" {
    var d = Decoder{};
    d.feed("\x1b[Z");
    const ev = d.next().?;
    try std.testing.expectEqual(input.Keysym.tab, ev.key.keysym);
    try std.testing.expect(ev.key.mods.shift);
}

test "the tilde keys decode by number" {
    var d = Decoder{};
    d.feed("\x1b[3~\x1b[5~\x1b[6~\x1b[2~");
    try std.testing.expectEqual(input.Keysym.delete, d.next().?.key.keysym);
    try std.testing.expectEqual(input.Keysym.page_up, d.next().?.key.keysym);
    try std.testing.expectEqual(input.Keysym.page_down, d.next().?.key.keysym);
    try std.testing.expectEqual(input.Keysym.insert, d.next().?.key.keysym);
}

test "SS3 decodes the first four function keys" {
    var d = Decoder{};
    d.feed("\x1bOP\x1bOQ");
    try std.testing.expectEqual(input.Keysym.f1, d.next().?.key.keysym);
    try std.testing.expectEqual(input.Keysym.f2, d.next().?.key.keysym);
}

test "the kitty form gives the keysym and the modifiers" {
    var d = Decoder{};
    d.feed("\x1b[97;5u"); // a with ctrl
    const ev = d.next().?;
    try std.testing.expectEqual(input.Keysym.fromCodepoint('a'), ev.key.keysym);
    try std.testing.expect(ev.key.mods.ctrl);
    // Ctrl held means no text, the same as the legacy control byte path.
    try std.testing.expect(ev.key.text == null);
}

test "the kitty form of a plain letter carries its text" {
    var d = Decoder{};
    d.feed("\x1b[97;1u"); // a with no modifier
    const ev = d.next().?;
    try std.testing.expectEqualStrings("a", ev.key.text.?);
}

test "the kitty form reports the event type when the terminal sends one" {
    var d = Decoder{};
    d.feed("\x1b[97;1:3u"); // event type 3 is a release
    try std.testing.expectEqual(input.KeyAction.release, d.next().?.key.action);
    d.feed("\x1b[97;1:2u"); // event type 2 is a repeat
    try std.testing.expectEqual(input.KeyAction.repeat, d.next().?.key.action);
}

test "the kitty form maps the control codepoints to named keysyms" {
    var d = Decoder{};
    d.feed("\x1b[13u\x1b[27u\x1b[9u");
    // The protocol names these keys by the control codepoint they produce, so 13
    // must become the enter keysym and not the unicode keysym for 13.
    try std.testing.expectEqual(input.Keysym.enter, d.next().?.key.keysym);
    try std.testing.expectEqual(input.Keysym.escape, d.next().?.key.keysym);
    try std.testing.expectEqual(input.Keysym.tab, d.next().?.key.keysym);
}

test "a bare modifier key reports its real X11 keysym and is not counted as dropped" {
    // Ghostty sends this once Task 20's kitty flags include "report events" (flag
    // 2): holding a bare shift alone reports itself, not just shift-as-a-modifier
    // on another key. Before this fix, `kittyKeysym` dropped the whole private-use
    // block with no exceptions, so this counted as a protocol fault on every press.
    var d = Decoder{};
    d.feed("\x1b[57441u"); // LEFT_SHIFT, kitty's functional key table
    const ev = d.next().?;
    try std.testing.expectEqual(input.Keysym.shift_l, ev.key.keysym);
    try std.testing.expectEqual(@as(u32, 0), d.dropped);
}

test "the right-hand modifiers and control/alt/super all map, left and right alike" {
    var d = Decoder{};
    d.feed("\x1b[57442u\x1b[57443u\x1b[57444u\x1b[57447u\x1b[57448u\x1b[57449u\x1b[57450u");
    try std.testing.expectEqual(input.Keysym.control_l, d.next().?.key.keysym);
    try std.testing.expectEqual(input.Keysym.alt_l, d.next().?.key.keysym);
    try std.testing.expectEqual(input.Keysym.super_l, d.next().?.key.keysym);
    try std.testing.expectEqual(input.Keysym.shift_r, d.next().?.key.keysym);
    try std.testing.expectEqual(input.Keysym.control_r, d.next().?.key.keysym);
    try std.testing.expectEqual(input.Keysym.alt_r, d.next().?.key.keysym);
    try std.testing.expectEqual(input.Keysym.super_r, d.next().?.key.keysym);
    try std.testing.expectEqual(@as(u32, 0), d.dropped);
}

test "a private-use key with no mapping yet counts as unmapped, not dropped" {
    // 57358 is CAPS_LOCK in kitty's functional key table. Genuinely no keysym for
    // it yet, but that is normal (see `kittyKeysym`'s doc comment), not a protocol
    // fault: the sequence parsed correctly.
    var d = Decoder{};
    d.feed("\x1b[57358u");
    try std.testing.expect(d.next() == null); // consumed, but names no event
    try std.testing.expectEqual(@as(u32, 0), d.dropped);
    try std.testing.expectEqual(@as(u32, 1), d.unmapped);
}

test "a straggler DECRPM capability reply is not a protocol fault" {
    // The startup probe (caps.zig) stops reading the instant DA1 answers, since
    // DA1 is last in the query string. A DECRPM reply still in flight at that exact
    // moment is not consumed by the probe and lands here on the next read instead.
    // It is a well formed CSI sequence, just not a key, so it must not raise a
    // false "terminal input sequences dropped" fault.
    var d = Decoder{};
    d.feed("\x1b[?2026;2$y"); // a real DECRPM sync-mode reply, reset/off right now
    try std.testing.expect(d.next() == null); // consumed, but names no key event
    try std.testing.expectEqual(@as(u32, 0), d.dropped);
    try std.testing.expectEqual(@as(u32, 1), d.unmapped);
}

test "a straggler DA1 reply is not a protocol fault" {
    var d = Decoder{};
    d.feed("\x1b[?62;1c"); // a real DA1 reply
    try std.testing.expect(d.next() == null);
    try std.testing.expectEqual(@as(u32, 0), d.dropped);
    try std.testing.expectEqual(@as(u32, 1), d.unmapped);
}

test "a straggler kitty graphics APC reply is discarded, not read as literal alt-prefixed keys" {
    // Same straggler timing as the CSI replies above, but the graphics query
    // answers in APC form (ESC _ ... ST), which is not a CSI sequence at all.
    // Before parseStringSeq existed, the leading `_` fell through to the plain
    // ESC+printable case and turned a late reply into Alt+underscore followed by
    // its whole body typed out as ordinary keys.
    var d = Decoder{};
    d.feed("\x1b_Gi=1;OK\x1b\\a");
    // next() does not stop at a no-event result: it keeps pulling from the buffer,
    // so the APC being silently skipped means the very next call already reaches
    // the real key that follows it.
    const ev = d.next().?;
    try std.testing.expectEqual(input.Keysym.fromCodepoint('a'), ev.key.keysym);
    try std.testing.expect(ev.key.mods.none()); // not Alt+underscore
    try std.testing.expectEqual(@as(u32, 0), d.dropped);
    try std.testing.expectEqual(@as(u32, 0), d.unmapped);
}

test "an unterminated APC waits for the rest instead of misreading its body" {
    var d = Decoder{};
    d.feed("\x1b_Gi=1;OK");
    try std.testing.expect(d.next() == null);
    d.feed("\x1b\\a");
    try std.testing.expectEqual(input.Keysym.fromCodepoint('a'), d.next().?.key.keysym);
}

test "the other three C1 string introducers are discarded the same way APC is" {
    // OSC, DCS and SOS: nothing here queries for any of these today, but a
    // terminal is free to send an unsolicited OSC reply with no query from us at
    // all, and the bug this guards against (ESC + printable misread as an Alt
    // keystroke) is identical for all five introducers, not just APC.
    var osc = Decoder{};
    osc.feed("\x1b]0;title\x1b\\a");
    try std.testing.expectEqual(input.Keysym.fromCodepoint('a'), osc.next().?.key.keysym);
    try std.testing.expectEqual(@as(u32, 0), osc.dropped);

    var dcs = Decoder{};
    dcs.feed("\x1bPsome dcs body\x1b\\a");
    try std.testing.expectEqual(input.Keysym.fromCodepoint('a'), dcs.next().?.key.keysym);
    try std.testing.expectEqual(@as(u32, 0), dcs.dropped);

    var sos = Decoder{};
    sos.feed("\x1bXsome sos body\x1b\\a");
    try std.testing.expectEqual(input.Keysym.fromCodepoint('a'), sos.next().?.key.keysym);
    try std.testing.expectEqual(@as(u32, 0), sos.dropped);
}

test "PM (privacy message) is discarded the same way, and an unterminated one waits rather than dropping" {
    var d = Decoder{};
    d.feed("\x1b^some pm body");
    try std.testing.expect(d.next() == null); // waits: no terminator yet, room left
    d.feed("\x1b\\a");
    try std.testing.expectEqual(input.Keysym.fromCodepoint('a'), d.next().?.key.keysym);
    try std.testing.expectEqual(@as(u32, 0), d.dropped);
}

test "an unterminated string sequence that fills the buffer is a genuine drop" {
    // Unlike a straggler reply that simply has not finished arriving yet, a
    // terminator that never shows up before the buffer fills is malformed (or
    // absurdly long), and that IS a protocol fault.
    var d = Decoder{};
    var chunk: [buffer_size]u8 = undefined;
    @memset(&chunk, 'x');
    d.feed("\x1b]");
    d.feed(chunk[0 .. buffer_size - 2]);
    try std.testing.expect(d.next() == null);
    try std.testing.expect(d.dropped > 0);
}

test "an escape prefixed letter is the alt modifier" {
    var d = Decoder{};
    d.feed("\x1ba");
    const ev = d.next().?;
    try std.testing.expectEqual(input.Keysym.fromCodepoint('a'), ev.key.keysym);
    try std.testing.expect(ev.key.mods.alt);
}

test "a lone escape byte decodes as the escape key" {
    var d = Decoder{};
    d.feed("\x1b");
    // One escape with nothing after it is ambiguous while more bytes may arrive, so
    // the decoder waits.
    try std.testing.expect(d.next() == null);
    d.flushPending();
    try std.testing.expectEqual(input.Keysym.escape, d.next().?.key.keysym);
}

test "bracketed paste returns the pasted text as one event" {
    var d = Decoder{};
    d.feed("\x1b[200~hello world\x1b[201~");
    const ev = d.next().?;
    try std.testing.expectEqualStrings("hello world", ev.paste);
}

test "an unterminated paste waits rather than reporting a partial paste" {
    var d = Decoder{};
    d.feed("\x1b[200~hel");
    try std.testing.expect(d.next() == null);
    d.feed("lo\x1b[201~");
    try std.testing.expectEqualStrings("hello", d.next().?.paste);
}

test "a paste followed by more buffered bytes keeps its own text intact" {
    var d = Decoder{};
    // The bytes after the closer are long enough that consume's shift-down would
    // overwrite the paste body in place if the paste borrowed `buf` directly.
    d.feed("\x1b[200~hi\x1b[201~1234567");
    const ev = d.next().?;
    try std.testing.expectEqualStrings("hi", ev.paste);
}

test "a paste containing a byte sequence that looks like a key press stays literal text" {
    var d = Decoder{};
    d.feed("\x1b[200~up \x1b[A arrow\x1b[201~");
    try std.testing.expectEqualStrings("up \x1b[A arrow", d.next().?.paste);
}

test "an unterminated paste that fills the buffer resets instead of hanging" {
    var d = Decoder{};
    var chunk: [buffer_size]u8 = undefined;
    @memset(&chunk, 'x');
    d.feed("\x1b[200~");
    d.feed(chunk[0 .. buffer_size - 6]); // tops the buffer up to exactly full
    // A single call must return, not loop forever, even though nothing has
    // parsed yet.
    try std.testing.expect(d.next() == null);
    // The buffer resets down to just the closing marker's worth of tail, not
    // all the way to empty: see the marker-split tests below for why.
    try std.testing.expectEqual(@as(usize, paste_close.len - 1), d.len);
    try std.testing.expect(d.dropped > 0);
    try std.testing.expect(d.discarding_paste);
}

test "a closing marker split exactly across a full buffer boundary still ends the discard" {
    // The buffer ends with everything but the marker's last byte, and that
    // last byte arrives in the next feed. A plain reset here would discard the
    // "\x1b[201" tail and strand `discarding_paste` forever, since the '~'
    // that follows can never match anything on its own.
    var d = Decoder{};
    var chunk: [buffer_size]u8 = undefined;
    @memset(&chunk, 'x');
    d.feed("\x1b[200~");
    d.feed(chunk[0 .. buffer_size - 6 - (paste_close.len - 1)]);
    d.feed(paste_close[0 .. paste_close.len - 1]); // "\x1b[201", buffer now exactly full
    try std.testing.expect(d.next() == null);
    try std.testing.expect(d.discarding_paste);

    d.feed(paste_close[paste_close.len - 1 ..]); // "~"
    try std.testing.expect(d.next() == null); // resolves the marker, itself no event
    try std.testing.expect(!d.discarding_paste);

    d.feed("a");
    try std.testing.expectEqual(input.Keysym.fromCodepoint('a'), d.next().?.key.keysym);
}

test "a closing marker split at other offsets across the boundary still ends the discard" {
    // Splitting after ESC, after ESC [, and after ESC [ 2 0 1 each retain a
    // different amount of the marker in the buffer's last five bytes. Every
    // offset must resolve, not just the one the other test names directly.
    var split: usize = 1;
    while (split < paste_close.len - 1) : (split += 1) {
        var d = Decoder{};
        var chunk: [buffer_size]u8 = undefined;
        @memset(&chunk, 'x');
        d.feed("\x1b[200~");
        d.feed(chunk[0 .. buffer_size - 6 - split]);
        d.feed(paste_close[0..split]);
        try std.testing.expect(d.next() == null);
        try std.testing.expect(d.discarding_paste);

        d.feed(paste_close[split..]);
        try std.testing.expect(d.next() == null);
        try std.testing.expect(!d.discarding_paste);

        d.feed("a");
        try std.testing.expectEqual(input.Keysym.fromCodepoint('a'), d.next().?.key.keysym);
    }
}

test "a discard spanning several full buffers still ends when the marker arrives, with no accumulated junk" {
    var d = Decoder{};
    var chunk: [buffer_size]u8 = undefined;
    @memset(&chunk, 'x');
    d.feed("\x1b[200~");
    d.feed(chunk[0 .. buffer_size - 6]);
    try std.testing.expect(d.next() == null);
    try std.testing.expect(d.discarding_paste);
    try std.testing.expectEqual(@as(usize, paste_close.len - 1), d.len);

    // Several more full buffers of unterminated body: the discard state must
    // survive each one, and each round must retain only the marker's worth of
    // tail, never accumulate.
    var round: u8 = 0;
    while (round < 3) : (round += 1) {
        d.feed(chunk[0 .. buffer_size - (paste_close.len - 1)]); // tops back up to full
        try std.testing.expect(d.next() == null);
        try std.testing.expect(d.discarding_paste);
        try std.testing.expectEqual(@as(usize, paste_close.len - 1), d.len);
    }

    d.feed("\x1b[201~a");
    const ev = d.next().?;
    try std.testing.expect(!d.discarding_paste);
    try std.testing.expectEqual(input.Keysym.fromCodepoint('a'), ev.key.keysym);
}

test "an oversized single feed mid discard still lets a split marker complete" {
    // `feed`'s own overflow guard fires when one write alone is bigger than the
    // room left. It must not wipe the marker-split tail the way its plain reset
    // does for the non-paste case.
    var d = Decoder{};
    var chunk: [buffer_size]u8 = undefined;
    @memset(&chunk, 'x');
    d.feed("\x1b[200~");
    d.feed(chunk[0 .. buffer_size - 6 - (paste_close.len - 1)]);
    d.feed(paste_close[0 .. paste_close.len - 1]); // "\x1b[201", buffer now exactly full
    try std.testing.expect(d.next() == null);
    try std.testing.expect(d.discarding_paste);

    // A single write completes the marker as its very first byte, then keeps
    // going past the room the retained tail left free, forcing the overflow
    // guard rather than a plain append.
    var big: [buffer_size]u8 = undefined;
    @memset(&big, 'x');
    big[0] = paste_close[paste_close.len - 1]; // '~'
    const room = buffer_size - (paste_close.len - 1);
    d.feed(big[0 .. room + 1]);

    // The marker resolves inside this very call. `next` does not stop there:
    // it keeps pulling from the loop until it finds an event or runs dry, so
    // the first non-null result may already be a leftover filler key. Only
    // `discarding_paste` is asserted here; the drain below confirms nothing
    // wedges either way.
    _ = d.next();
    try std.testing.expect(!d.discarding_paste);

    var guard: u16 = 0;
    while (d.next() != null and guard < buffer_size) : (guard += 1) {}
    try std.testing.expect(guard < buffer_size); // drained, did not hit the guard

    d.feed("a");
    try std.testing.expectEqual(input.Keysym.fromCodepoint('a'), d.next().?.key.keysym);
}

test "an oversized paste produces no key events for its tail, and normal parsing resumes once it closes" {
    var d = Decoder{};
    var chunk: [buffer_size]u8 = undefined;
    @memset(&chunk, 'x');
    d.feed("\x1b[200~");
    d.feed(chunk[0 .. buffer_size - 6]);
    try std.testing.expect(d.next() == null);
    try std.testing.expect(d.discarding_paste);

    // A second full buffer of body with still no closer: the discard state must
    // survive across it, and it must produce no events, key or otherwise.
    d.feed(&chunk);
    try std.testing.expect(d.next() == null);
    try std.testing.expect(d.discarding_paste);

    // The closing marker finally arrives, followed by a real key press. That
    // key must decode normally and not be swallowed by the discard state.
    d.feed("\x1b[201~a");
    const ev = d.next().?;
    try std.testing.expect(!d.discarding_paste);
    try std.testing.expectEqual(input.Keysym.fromCodepoint('a'), ev.key.keysym);
}

test "flushing before a real sequence arrives does not misread its first byte as escape" {
    var d = Decoder{};
    d.flushPending(); // an idle flush while nothing is pending yet
    d.feed("\x1b"); // the leading byte of a real sequence starts arriving
    // The stale flush must not carry over onto bytes fed after it: this escape
    // might still be the start of something else, so the decoder waits.
    try std.testing.expect(d.next() == null);
    d.feed("[A"); // the rest of the sequence: Up
    try std.testing.expectEqual(input.Keysym.up, d.next().?.key.keysym);
}

test "an empty feed after a flush does not cancel it" {
    var d = Decoder{};
    d.feed("\x1b"); // a real lone escape byte, genuinely pending
    d.flushPending();
    // An idle poll that read nothing must not swallow the flush: the escape
    // byte already buffered is still exactly what it was.
    d.feed(&.{});
    try std.testing.expectEqual(input.Keysym.escape, d.next().?.key.keysym);
}

test "the in-band resize report decodes to a size" {
    var d = Decoder{};
    // CSI 48 ; rows ; cols ; ypixel ; xpixel t
    d.feed("\x1b[48;24;80;432;720t");
    const ev = d.next().?;
    try std.testing.expectEqual(@as(u16, 80), ev.resize.cols);
    try std.testing.expectEqual(@as(u16, 24), ev.resize.rows);
    try std.testing.expectEqual(@as(u16, 720), ev.resize.xpixel);
    try std.testing.expectEqual(@as(u16, 432), ev.resize.ypixel);
}

test "a resize report with missing pixel fields still gives the cell counts" {
    var d = Decoder{};
    d.feed("\x1b[48;24;80t");
    const ev = d.next().?;
    try std.testing.expectEqual(@as(u16, 80), ev.resize.cols);
    try std.testing.expectEqual(@as(u16, 0), ev.resize.xpixel);
}

test "a window report that is not a resize is dropped and not read as a size" {
    var d = Decoder{};
    // CSI 8 ; ... t is a different window report.
    d.feed("\x1b[8;24;80t");
    _ = d.next();
    try std.testing.expect(d.dropped > 0);
}

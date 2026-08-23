//! Escape sequences that the terminal backends write. This module holds no state
//! and does no input and output, so every function here is a pure byte builder and
//! is testable with no terminal.

const std = @import("std");

pub const esc = "\x1b";
pub const csi = esc ++ "[";
pub const st = esc ++ "\\";
pub const apc = esc ++ "_";

pub const alt_screen_on = csi ++ "?1049h";
pub const alt_screen_off = csi ++ "?1049l";
pub const cursor_hide = csi ++ "?25l";
pub const cursor_show = csi ++ "?25h";
pub const clear_screen = csi ++ "2J";
pub const sgr_reset = csi ++ "0m";

/// 1003 reports all motion, which the pointer dispatcher needs for hover with no
/// button held. 1002 reports motion only while a button is down and is the fallback.
/// 1006 selects the SGR encoding, which removes the 223 column limit of the original.
pub const mouse_all_on = csi ++ "?1003h";
pub const mouse_all_off = csi ++ "?1003l";
pub const mouse_button_on = csi ++ "?1002h";
pub const mouse_button_off = csi ++ "?1002l";
pub const mouse_sgr_on = csi ++ "?1006h";
pub const mouse_sgr_off = csi ++ "?1006l";
pub const mouse_pixel_on = csi ++ "?1016h";
pub const mouse_pixel_off = csi ++ "?1016l";

pub const paste_on = csi ++ "?2004h";
pub const paste_off = csi ++ "?2004l";
pub const sync_begin = csi ++ "?2026h";
pub const sync_end = csi ++ "?2026l";
pub const inband_resize_on = csi ++ "?2048h";
pub const inband_resize_off = csi ++ "?2048l";
pub const kitty_kbd_pop = csi ++ "<u";

/// Move the cursor. `row` and `col` are zero based, because the cell grid is zero
/// based. CUP is one based, so both gain one here and nowhere else.
pub fn cursorTo(buf: *[16]u8, row: u16, col: u16) []const u8 {
    // Two u16 print as at most 5 digits each, and the fixed bytes are 4, so 14
    // bytes is the worst case and the buffer cannot overflow.
    comptime std.debug.assert(16 >= 4 + 5 + 5);
    return std.fmt.bufPrint(buf, csi ++ "{d};{d}H", .{
        @as(u32, row) + 1,
        @as(u32, col) + 1,
    }) catch unreachable;
}

/// Carriage return: the cursor goes to the first column of the row it is on.
///
/// Used by the relative writer instead of counting columns back from wherever
/// the cursor was. After a glyph lands in the last column a terminal holds a
/// "pending wrap" state, where the cursor is visually past the last column but
/// has not moved to the next row yet. A relative column move from there is
/// ambiguous; a carriage return clears the state and gives a known column to
/// count forward from.
pub const cr = "\r";

/// Move the cursor `n` rows up, `n` rows down, or `n` columns right, relative to
/// wherever it already is.
///
/// `n` must not be zero. A terminal reads a zero parameter as one, so an
/// unguarded "move zero" moves one and the frame drifts. Every caller here
/// checks for a zero move and writes nothing for it.
///
/// None of these scroll. Moving down at the last row of the screen leaves the
/// cursor where it is, unlike a line feed. A caller that draws a band relative
/// to the cursor is responsible for the rows below it already existing.
pub fn cursorUp(buf: *[8]u8, n: u16) []const u8 {
    return relativeMove(buf, n, 'A');
}

pub fn cursorDown(buf: *[8]u8, n: u16) []const u8 {
    return relativeMove(buf, n, 'B');
}

pub fn cursorRight(buf: *[8]u8, n: u16) []const u8 {
    return relativeMove(buf, n, 'C');
}

fn relativeMove(buf: *[8]u8, n: u16, comptime final: u8) []const u8 {
    // A u16 prints as at most 5 digits, and the fixed bytes are CSI (2) plus
    // the final byte (1), so 8 bytes cannot overflow.
    comptime std.debug.assert(8 >= 3 + 5);
    std.debug.assert(n != 0);
    return std.fmt.bufPrint(buf, csi ++ "{d}" ++ [_]u8{final}, .{n}) catch unreachable;
}

// The fixed bytes of the truecolor form are CSI (2), "38;2;" (5), two ';' (2)
// and 'm' (1), which is 10. Each channel prints at most 3 digits.
pub fn setFg(buf: *[24]u8, r: u8, g: u8, b: u8) []const u8 {
    comptime std.debug.assert(24 >= 10 + 3 + 3 + 3);
    return std.fmt.bufPrint(buf, csi ++ "38;2;{d};{d};{d}m", .{ r, g, b }) catch unreachable;
}

pub fn setBg(buf: *[24]u8, r: u8, g: u8, b: u8) []const u8 {
    comptime std.debug.assert(24 >= 10 + 3 + 3 + 3);
    return std.fmt.bufPrint(buf, csi ++ "48;2;{d};{d};{d}m", .{ r, g, b }) catch unreachable;
}

// The fixed bytes of the indexed form are CSI (2), "38;5;" (5) and 'm' (1).
pub fn setFg256(buf: *[16]u8, index: u8) []const u8 {
    comptime std.debug.assert(16 >= 8 + 3);
    return std.fmt.bufPrint(buf, csi ++ "38;5;{d}m", .{index}) catch unreachable;
}

pub fn setBg256(buf: *[16]u8, index: u8) []const u8 {
    comptime std.debug.assert(16 >= 8 + 3);
    return std.fmt.bufPrint(buf, csi ++ "48;5;{d}m", .{index}) catch unreachable;
}

/// Push the kitty keyboard progressive enhancement flags. Bit 1 is the
/// disambiguate flag, bit 2 reports events, bit 4 reports alternate keys and
/// bit 8 reports all keys as escape codes.
pub fn kittyKbdPush(buf: *[16]u8, flags: u8) []const u8 {
    comptime std.debug.assert(16 >= 4 + 3);
    return std.fmt.bufPrint(buf, csi ++ ">{d}u", .{flags}) catch unreachable;
}

test "cursorTo converts a zero based cell to a one based CUP sequence" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[1;1H", cursorTo(&buf, 0, 0));
    try std.testing.expectEqualStrings("\x1b[24;80H", cursorTo(&buf, 23, 79));
}

test "cursorTo fits the largest coordinates a u16 can hold" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[65536;65536H", cursorTo(&buf, 65535, 65535));
}

test "the relative cursor moves write their own final byte and carry the count" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[1A", cursorUp(&buf, 1));
    try std.testing.expectEqualStrings("\x1b[3B", cursorDown(&buf, 3));
    try std.testing.expectEqualStrings("\x1b[12C", cursorRight(&buf, 12));
}

test "a relative cursor move fits the largest count a u16 can hold" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[65535B", cursorDown(&buf, 65535));
}

test "the relative moves are distinct final bytes, so up is never confused with down" {
    var up: [8]u8 = undefined;
    var down: [8]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, cursorUp(&up, 4), cursorDown(&down, 4)));
}

test "setFg and setBg write the truecolor SGR forms" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[38;2;255;0;16m", setFg(&buf, 255, 0, 16));
    try std.testing.expectEqualStrings("\x1b[48;2;0;128;255m", setBg(&buf, 0, 128, 255));
}

test "setFg256 and setBg256 write the indexed SGR forms" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[38;5;231m", setFg256(&buf, 231));
    try std.testing.expectEqualStrings("\x1b[48;5;0m", setBg256(&buf, 0));
}

test "kittyKbdPush writes the progressive enhancement flags" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[>15u", kittyKbdPush(&buf, 15));
}

test "the alternate screen constants are a matched pair" {
    try std.testing.expectEqualStrings("\x1b[?1049h", alt_screen_on);
    try std.testing.expectEqualStrings("\x1b[?1049l", alt_screen_off);
}

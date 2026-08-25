//! One line of editable text. This is the prompt input of a shell and the search
//! box of a launcher, so it must work the same on the GPU backend and on the
//! terminal backend.
//!
//! What it composes rather than rebuilds:
//!   * `Focus` supplies the keys. The focus manager only dispatches to the focused
//!     node, so an unfocused field never sees a key and needs no guard of its own.
//!     A `KeyboardListener` is deliberately NOT used: a listener sees keys while
//!     the field is not focused, which is the opposite of what a text field wants.
//!   * `Ticker` blinks the caret. It measures real time, so the blink rate is the
//!     same however fast the backend draws frames.
//!   * `text/layout.zig` measures the line, so the caret lands on a cell boundary
//!     under the terminal's monospace metrics and on a glyph advance under the
//!     GPU's proportional ones.
//!
//! Enter is left unhandled on purpose. The field does not own the meaning of the
//! text, so a caller wraps it in a `KeyboardListener` and decides what submitting
//! means there.
const std = @import("std");
const phantom = @import("../../phantom.zig");
const geom = phantom.geometry;
const layout = phantom.layout;
const Canvas = phantom.Canvas;
const Widget = phantom.Widget;
const Element = phantom.Element;
const RenderObject = phantom.RenderObject;
const BuildContext = phantom.BuildContext;
const Ticker = phantom.Ticker;
const input = phantom.input;
const text_layout = @import("../text/layout.zig");
const Font = @import("../text/Font.zig");
const mono = @import("../text/mono.zig");
const theme_mod = @import("../theme.zig");
const testing = @import("../testing.zig");

/// Half of one blink cycle, in nanoseconds. The caret shows for this long and
/// hides for the same again.
pub const default_blink_period: Ticker.Nanos = 500_000_000;

// ---------------------------------------------------------------------------
// UTF-8 caret motion
// ---------------------------------------------------------------------------

/// The byte index of the character boundary before `i`. Malformed bytes are a
/// runtime fault in the input, not a programmer error, so a run of continuation
/// bytes with no lead byte still yields progress instead of stalling the caret.
pub fn previousBoundary(s: []const u8, i: usize) usize {
    if (i == 0 or i > s.len) return 0;
    var j = i - 1;
    while (j > 0 and s[j] & 0xC0 == 0x80) j -= 1;
    return j;
}

/// The byte index of the character boundary after `i`. A byte that starts no
/// valid sequence advances by one, so the caret can always leave it.
pub fn nextBoundary(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    return @min(s.len, i + len);
}

/// How many characters `s` holds. Every byte that is not a continuation byte
/// starts one, which also counts malformed input without rejecting it.
fn characterCount(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (b & 0xC0 != 0x80) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// The render object: one line, a scroll offset and a caret
// ---------------------------------------------------------------------------

const RenderCaretText = struct {
    base: RenderObject,
    gpa: std.mem.Allocator,
    /// Owned copy of the text. The State's buffer moves when it grows, so the
    /// render object must not borrow it across a frame.
    text: []const u8,
    /// Caret position in BYTES, always on a character boundary.
    caret: usize,
    caret_visible: bool,
    font: *Font,
    /// Logical font size. layoutFn multiplies it by the constraint scale.
    size: f32,
    physical_size: f32 = 0,
    color: geom.Color,
    caret_color: geom.Color,
    /// Logical caret width, used only where text is proportional. A character
    /// grid gives the caret a whole cell instead, so it reads as a block.
    caret_width: f32,
    text_metrics: *const mono.TextMetrics,
    line: ?text_layout.Line = null,
    /// How far the view has scrolled right, in physical units. Kept across
    /// layouts so a caret that is already visible does not jump.
    scroll: f32 = 0,
    /// Physical caret geometry resolved by the last layout.
    caret_x: f32 = 0,
    physical_caret_width: f32 = 0,

    fn dropLine(self: *RenderCaretText) void {
        if (self.line) |*l| {
            l.deinit(self.gpa);
            self.line = null;
        }
    }

    /// The physical x of the caret inside the unscrolled line. One glyph is laid
    /// out per character, so counting characters up to the caret byte gives the
    /// glyph the caret sits in front of.
    fn caretOffset(self: *const RenderCaretText, l: text_layout.Line) f32 {
        const caret = @min(self.caret, self.text.len);
        const index = characterCount(self.text[0..caret]);
        if (index >= l.glyphs.len) return l.width;
        return l.glyphs[index].x;
    }

    fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderCaretText = @fieldParentPtr("base", base);
        self.dropLine();
        self.physical_size = self.size * c.scale;
        const l = text_layout.layoutLine(
            self.gpa,
            self.font,
            self.text,
            self.physical_size,
            self.text_metrics.*,
        ) catch {
            // Measuring failed, so there is nothing to place a caret against.
            // The field keeps its box and paints nothing this frame.
            return c.constrain(geom.PhysicalSize.zero);
        };
        self.line = l;

        self.physical_caret_width = switch (self.text_metrics.*) {
            // A character grid has no sub cell position, so a thin bar would
            // either vanish or tint a whole cell anyway. A full cell block is
            // what a terminal cursor looks like.
            .mono => |m| m.advance,
            .proportional => self.caret_width * c.scale,
        };
        self.caret_x = self.caretOffset(l);

        // An unbounded width has no view to scroll inside, so the field reports
        // its natural width. Everywhere else it fills what it was offered.
        const width = if (std.math.isInf(c.max_width)) l.width + self.physical_caret_width else c.max_width;
        const size = c.constrain(.{ .width = width, .height = l.height });

        // Keep the caret inside the view. A long prompt in a narrow field then
        // stays usable, because what the user is typing is always on screen.
        if (self.caret_x < self.scroll) self.scroll = self.caret_x;
        const right_edge = self.scroll + size.width - self.physical_caret_width;
        if (self.caret_x > right_edge) self.scroll = self.caret_x - size.width + self.physical_caret_width;
        const max_scroll = @max(@as(f32, 0), l.width + self.physical_caret_width - size.width);
        self.scroll = std.math.clamp(self.scroll, 0, max_scroll);
        return size;
    }

    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderCaretText = @fieldParentPtr("base", base);
        const l = self.line orelse return;
        // The caret goes down first so a glyph under a block caret still reads.
        if (self.caret_visible) {
            try cv.fillRRect(.{
                .x = offset.x + self.caret_x - self.scroll,
                .y = offset.y,
                .width = self.physical_caret_width,
                .height = base.size.height,
            }, 0, self.caret_color);
        }
        try cv.drawText(.{
            .glyphs = l.glyphs,
            .text = self.text,
            .font = @ptrCast(self.font),
            .size = self.physical_size,
            .color = self.color,
            .origin = .{ .x = offset.x - self.scroll, .y = offset.y },
            .ascent = l.ascent,
        });
    }

    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderCaretText = @fieldParentPtr("base", base);
        self.dropLine();
        gpa.free(self.text);
        gpa.destroy(self);
    }
};

/// The leaf the TextField's State builds. Private: a caller configures the field,
/// not the view inside it.
const CaretText = struct {
    text: []const u8,
    caret: usize,
    caret_visible: bool,
    font: *Font,
    size: f32,
    color: geom.Color,
    caret_color: geom.Color,
    caret_width: f32,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    fn widget(self: *const CaretText) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const CaretText = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const owned = try gpa.dupe(u8, self.text);
        errdefer gpa.free(owned);
        const ro = try gpa.create(RenderCaretText);
        errdefer gpa.destroy(ro);
        ro.* = .{
            .base = .{
                .layoutFn = RenderCaretText.layoutFn,
                .paintFn = RenderCaretText.paintFn,
                .destroyFn = RenderCaretText.destroyFn,
            },
            .gpa = gpa,
            .text = owned,
            .caret = @min(self.caret, owned.len),
            .caret_visible = self.caret_visible,
            .font = self.font,
            .size = self.size,
            .color = self.color,
            .caret_color = self.caret_color,
            .caret_width = self.caret_width,
            .text_metrics = &bctx.owner.text_metrics,
        };
        const el = try gpa.create(Element);
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(CaretText),
            .render_object = &ro.base,
            .depth = phantom.widget.depthOf(parent),
        };
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        _ = bctx;
        const self: *const CaretText = @ptrCast(@alignCast(ptr));
        const ro: *RenderCaretText = @fieldParentPtr("base", el.render_object.?);
        // Duplicate before freeing, so a failed allocation leaves the old string
        // in place rather than a dangling one.
        const owned = try ro.gpa.dupe(u8, self.text);
        ro.gpa.free(ro.text);
        ro.text = owned;
        ro.caret = @min(self.caret, owned.len);
        ro.caret_visible = self.caret_visible;
        ro.font = self.font;
        ro.size = self.size;
        ro.color = self.color;
        ro.caret_color = self.caret_color;
        ro.caret_width = self.caret_width;
        ro.dropLine();
    }
};

// ---------------------------------------------------------------------------
// The widget
// ---------------------------------------------------------------------------

pub const TextField = struct {
    /// The text the field starts with. It is copied on mount and the field owns
    /// its text from then on, so a later rebuild does not overwrite what the user
    /// typed.
    text: []const u8 = "",
    /// Logical font size. Null takes the theme's.
    size: ?f32 = null,
    /// Null takes the theme's text colour.
    color: ?geom.Color = null,
    /// Null takes the theme's accent, which is the colour that marks the active
    /// element everywhere else.
    caret_color: ?geom.Color = null,
    /// Null takes the theme's body font.
    font: ?*Font = null,
    /// Logical caret width where text is proportional.
    caret_width: f32 = 2,
    /// Half of a blink cycle in nanoseconds. Zero or less holds the caret steady.
    blink_period: Ticker.Nanos = default_blink_period,
    /// Called after every edit with the whole text. The slice is borrowed and is
    /// valid for the call only.
    on_change: ?*const fn (ctx: *anyopaque, text: []const u8) void = null,
    ctx: *anyopaque = undefined,
    /// The name `FocusManager.focusById` moves the focus here by. This is what a
    /// click on the field routes through, because a pointer hit gives a render
    /// object and the focus is held by name. Null leaves the field reachable
    /// through Tab only.
    id: ?[]const u8 = null,

    pub fn widget(self: *const TextField) Widget {
        return phantom.StatefulWidget(TextField, self);
    }

    pub const State = struct {
        base: phantom.StateBase = .{},
        /// The field's own text. Owned, so a `KeyEvent.text` slice that borrows
        /// decoder storage is copied in here and never held.
        buf: std.ArrayList(u8) = .empty,
        /// Caret position in bytes, always on a character boundary.
        caret: usize = 0,
        focused: bool = false,
        /// The blink phase. The caret only draws when the field is focused AND
        /// this is on.
        caret_on: bool = true,
        ticker: Ticker = undefined,
        blink_period: Ticker.Nanos = default_blink_period,
        on_change: ?*const fn (ctx: *anyopaque, text: []const u8) void = null,
        user_ctx: *anyopaque = undefined,
        font: ?*Font = null,
        size: ?f32 = null,
        color: ?geom.Color = null,
        caret_color: ?geom.Color = null,
        caret_width: f32 = 2,
        /// Borrowed from the config. The `Focus` widget below copies it, so the
        /// slice only has to survive until the next build.
        id: ?[]const u8 = null,
        // The built configs live here so their addresses stay stable across the
        // build, which is what a Widget borrows.
        view: CaretText = undefined,
        focus_config: phantom.Focus = undefined,

        pub fn initState(s: *State, config: *const TextField) anyerror!void {
            s.takeStyle(config);
            try s.buf.appendSlice(s.base.gpa(), config.text);
            s.caret = s.buf.items.len;
            s.ticker = .{
                .scheduler = s.base.scheduler(),
                .ctx = s,
                .on_tick = State.onFrame,
            };
        }

        pub fn didUpdateWidget(s: *State, config: *const TextField) anyerror!void {
            // The text is deliberately not taken again: the field owns it after
            // mount, and a parent rebuild must not undo what the user typed.
            s.takeStyle(config);
        }

        pub fn dispose(s: *State) void {
            // Without this the scheduler keeps calling a freed State every frame.
            s.ticker.deinit();
            s.buf.deinit(s.base.gpa());
        }

        fn takeStyle(s: *State, config: *const TextField) void {
            s.on_change = config.on_change;
            s.user_ctx = config.ctx;
            s.font = config.font;
            s.size = config.size;
            s.color = config.color;
            s.caret_color = config.caret_color;
            s.caret_width = config.caret_width;
            s.blink_period = config.blink_period;
            s.id = config.id;
        }

        /// The text as it stands. Borrowed and valid until the next edit.
        pub fn value(s: *const State) []const u8 {
            return s.buf.items;
        }

        pub fn build(s: *State, b: *BuildContext) anyerror!Widget {
            const td = phantom.Theme.of(b);
            s.view = .{
                .text = s.buf.items,
                .caret = s.caret,
                .caret_visible = s.focused and s.caret_on,
                .font = s.font orelse td.body_font,
                .size = s.size orelse td.text_size,
                .color = s.color orelse td.text_color,
                .caret_color = s.caret_color orelse td.accent,
                .caret_width = s.caret_width,
            };
            s.focus_config = .{
                .child = s.view.widget(),
                .on_key = State.onKey,
                .on_focus_change = State.onFocusChange,
                .ctx = s,
                .id = s.id,
            };
            return s.focus_config.widget();
        }

        // -- editing -------------------------------------------------------

        fn insert(s: *State, bytes: []const u8) bool {
            s.buf.insertSlice(s.base.gpa(), s.caret, bytes) catch {
                s.base.sink().report(.oom, "text field could not insert typed text");
                return false;
            };
            s.caret += bytes.len;
            return true;
        }

        fn backspace(s: *State) bool {
            if (s.caret == 0) return false; // no edit, and no unsigned underflow
            const start = previousBoundary(s.buf.items, s.caret);
            s.buf.replaceRangeAssumeCapacity(start, s.caret - start, &.{});
            s.caret = start;
            return true;
        }

        fn deleteForward(s: *State) bool {
            if (s.caret >= s.buf.items.len) return false;
            const end = nextBoundary(s.buf.items, s.caret);
            s.buf.replaceRangeAssumeCapacity(s.caret, end - s.caret, &.{});
            return true;
        }

        /// A caret that just moved must be visible, or the user cannot see where
        /// the next character will land.
        fn showCaret(s: *State) void {
            s.caret_on = true;
            s.ticker.reset();
        }

        fn afterEdit(s: *State) void {
            s.showCaret();
            if (s.on_change) |f| f(s.user_ctx, s.buf.items);
            phantom.markNeedsBuild(s);
        }

        fn afterMove(s: *State) void {
            s.showCaret();
            phantom.markNeedsBuild(s);
        }

        // -- callbacks -----------------------------------------------------

        fn onKey(ctx: *anyopaque, ev: input.KeyEvent) bool {
            const s: *State = @ptrCast(@alignCast(ctx));
            if (ev.action == .release) return false;
            // Keysym is not exhaustive, because a printable key carries a unicode
            // keysym, so the default prong is the printable path.
            switch (ev.keysym) {
                .backspace => {
                    if (s.backspace()) s.afterEdit() else s.afterMove();
                    return true;
                },
                .delete => {
                    if (s.deleteForward()) s.afterEdit() else s.afterMove();
                    return true;
                },
                .left => {
                    s.caret = previousBoundary(s.buf.items, s.caret);
                    s.afterMove();
                    return true;
                },
                .right => {
                    s.caret = nextBoundary(s.buf.items, s.caret);
                    s.afterMove();
                    return true;
                },
                .home => {
                    s.caret = 0;
                    s.afterMove();
                    return true;
                },
                .end => {
                    s.caret = s.buf.items.len;
                    s.afterMove();
                    return true;
                },
                else => {
                    // The decoder already resolved what the key produces, so the
                    // keysym is never consulted here. `text` borrows decoder
                    // storage, so `insert` copies it before returning.
                    const typed = ev.text orelse return false;
                    if (typed.len == 0) return false;
                    if (!s.insert(typed)) return true;
                    s.afterEdit();
                    return true;
                },
            }
        }

        fn onFocusChange(ctx: *anyopaque, focused: bool) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            s.focused = focused;
            if (focused) {
                s.caret_on = true;
                s.ticker.reset();
                s.ticker.start(s.base.gpa()) catch {
                    // A caret that cannot blink still shows, so the field stays
                    // usable. The fault names why it stopped blinking.
                    s.base.sink().report(.oom, "text field caret blink not scheduled");
                };
            } else {
                s.ticker.stop();
            }
            phantom.markNeedsBuild(s);
        }

        fn onFrame(ctx: *anyopaque, elapsed: Ticker.Nanos) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            if (s.blink_period <= 0) return;
            const on = @rem(@divTrunc(elapsed, s.blink_period), 2) == 0;
            // Only a phase change costs a rebuild. Otherwise the field would
            // rebuild on every frame and drown the dirty queue.
            if (on == s.caret_on) return;
            s.caret_on = on;
            phantom.markNeedsBuild(s);
        }
    };
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Recorder = struct {
    calls: u32 = 0,
    last: [64]u8 = undefined,
    last_len: usize = 0,

    fn onChange(ctx: *anyopaque, value: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const n = @min(value.len, self.last.len);
        @memcpy(self.last[0..n], value[0..n]);
        self.last_len = n;
    }

    fn text(self: *const Recorder) []const u8 {
        return self.last[0..self.last_len];
    }
};

/// A mounted field with a focus manager wired to it. Every test drives keys the
/// way the terminal and the compositor do, through the manager.
const Fixture = struct {
    harness: testing.Harness,
    manager: phantom.FocusManager = .{},
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator, field: *const TextField) !Fixture {
        return .{ .harness = try testing.mount(gpa, field.widget()), .gpa = gpa };
    }

    fn deinit(self: *Fixture) void {
        self.harness.deinit();
        self.manager.deinit(self.gpa);
    }

    fn state(self: *Fixture) !*TextField.State {
        return self.harness.stateOf(testing.find.byType(TextField), TextField.State);
    }

    /// Re-collect the focus order, which a real frame loop does after every build.
    /// The owner is wired here rather than in `init`, because a Fixture returned by
    /// value would carry a pointer to the local it was built in.
    fn refresh(self: *Fixture) !void {
        self.harness.owner.focus = &self.manager;
        try self.manager.collect(self.gpa, self.harness.root);
    }

    fn focus(self: *Fixture) !void {
        try self.refresh();
        self.manager.focusNext();
    }

    fn typeText(self: *Fixture, s: []const u8) void {
        _ = self.manager.dispatch(.{ .keysym = .no_symbol, .text = s });
    }

    fn press(self: *Fixture, key: input.Keysym) void {
        _ = self.manager.dispatch(.{ .keysym = key });
    }
};

test "a named TextField takes the focus by id, which is what a click on it does" {
    const gpa = std.testing.allocator;
    var field = TextField{ .id = "prompt", .text = "" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.refresh();

    // A pointer hit gives the application a place on screen, not a Tab count, so
    // this is the only way a click can reach one field out of several.
    try std.testing.expect(f.manager.focusById("prompt"));
    f.typeText("hi");
    const s = try f.state();
    try std.testing.expectEqualStrings("hi", s.value());
}

test "an unnamed TextField answers to no id, so a stray name cannot focus it" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.refresh();

    try std.testing.expect(!f.manager.focusById("prompt"));
    f.typeText("hi");
    const s = try f.state();
    // Nothing holds the focus, so the key went nowhere.
    try std.testing.expectEqualStrings("", s.value());
}

test "typing inserts at the caret and not at the end of the text" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "ac" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    try std.testing.expectEqualStrings("ac", s.value());
    f.press(.left); // caret now sits between 'a' and 'c'
    f.typeText("b");
    try std.testing.expectEqualStrings("abc", s.value());
    try std.testing.expectEqual(@as(usize, 2), s.caret);
}

test "backspace at position zero changes nothing and does not underflow" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "hi" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    f.press(.home);
    try std.testing.expectEqual(@as(usize, 0), s.caret);
    f.press(.backspace);
    f.press(.backspace);
    try std.testing.expectEqualStrings("hi", s.value());
    try std.testing.expectEqual(@as(usize, 0), s.caret);
}

test "backspace removes the character before the caret and leaves the rest" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "abc" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    f.press(.left); // caret between 'b' and 'c'
    f.press(.backspace);
    try std.testing.expectEqualStrings("ac", s.value());
    try std.testing.expectEqual(@as(usize, 1), s.caret);
}

test "delete removes the character after the caret and is a no-op at the end" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "abc" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    f.press(.delete); // caret is at the end, so nothing to remove
    try std.testing.expectEqualStrings("abc", s.value());
    f.press(.home);
    f.press(.delete);
    try std.testing.expectEqualStrings("bc", s.value());
    try std.testing.expectEqual(@as(usize, 0), s.caret);
}

test "the left arrow steps over a whole multi byte character" {
    // The euro sign is three bytes. A caret that steps one byte lands inside the
    // sequence, and the next insert splits the character into rubbish.
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "a\u{20AC}b" }; // 1 + 3 + 1 bytes
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    try std.testing.expectEqual(@as(usize, 5), s.value().len);
    try std.testing.expectEqual(@as(usize, 5), s.caret);

    f.press(.left); // over 'b'
    try std.testing.expectEqual(@as(usize, 4), s.caret);
    f.press(.left); // over the whole euro sign, three bytes at once
    try std.testing.expectEqual(@as(usize, 1), s.caret);
    f.press(.left); // over 'a'
    try std.testing.expectEqual(@as(usize, 0), s.caret);

    // Stepping right lands on the same boundaries in the other direction.
    f.press(.right);
    try std.testing.expectEqual(@as(usize, 1), s.caret);
    f.press(.right);
    try std.testing.expectEqual(@as(usize, 4), s.caret);
}

test "backspace over a multi byte character removes the whole character" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "a\u{20AC}" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    f.press(.backspace);
    try std.testing.expectEqualStrings("a", s.value());
    // A one byte removal would leave a broken sequence behind.
    try std.testing.expect(std.unicode.utf8ValidateSlice(s.value()));
}

test "delete over a multi byte character removes the whole character" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "\u{20AC}a" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    f.press(.home);
    f.press(.delete);
    try std.testing.expectEqualStrings("a", s.value());
    try std.testing.expect(std.unicode.utf8ValidateSlice(s.value()));
}

test "the field copies the borrowed key text instead of holding the decoder's slice" {
    // KeyEvent.text borrows decoder storage and is valid for the callback only.
    // A field that keeps the slice reads freed or reused memory on the next key.
    const gpa = std.testing.allocator;
    var field = TextField{};
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    // A mutable buffer standing in for the decoder's scratch storage.
    var decoder_scratch = [_]u8{ 'h', 'i' };
    _ = f.manager.dispatch(.{ .keysym = .no_symbol, .text = decoder_scratch[0..] });

    // The decoder reuses its buffer for the next sequence.
    @memcpy(decoder_scratch[0..], "ZZ");

    const s = try f.state();
    try std.testing.expectEqualStrings("hi", s.value());
}

test "an unfocused field ignores every key" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "start" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.refresh(); // collected, but nothing is focused

    const s = try f.state();
    f.typeText("x");
    f.press(.backspace);
    f.press(.home);
    try std.testing.expectEqualStrings("start", s.value());
    try std.testing.expectEqual(@as(usize, 5), s.caret);

    // Focusing it makes the very same keys land.
    f.focus() catch unreachable;
    f.typeText("x");
    try std.testing.expectEqualStrings("startx", s.value());
}

test "on_change fires once per edit and never once per frame" {
    const gpa = std.testing.allocator;
    var recorder = Recorder{};
    var field = TextField{ .on_change = Recorder.onChange, .ctx = &recorder };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    f.typeText("a");
    f.typeText("b");
    f.typeText("c");
    try std.testing.expectEqual(@as(u32, 3), recorder.calls);
    try std.testing.expectEqualStrings("abc", recorder.text());

    // Caret movement is not an edit.
    f.press(.left);
    f.press(.home);
    f.press(.end);
    try std.testing.expectEqual(@as(u32, 3), recorder.calls);

    // Nor is a frame. Sixty of them blink the caret several times over.
    var frame: u32 = 0;
    while (frame < 60) : (frame += 1) {
        f.harness.owner.scheduler.tick(@as(Ticker.Nanos, frame) * 100_000_000);
    }
    try std.testing.expectEqual(@as(u32, 3), recorder.calls);

    // A backspace that removes nothing is not an edit either.
    f.press(.home);
    f.press(.backspace);
    try std.testing.expectEqual(@as(u32, 3), recorder.calls);

    // A backspace that does remove something is.
    f.press(.end);
    f.press(.backspace);
    try std.testing.expectEqual(@as(u32, 4), recorder.calls);
    try std.testing.expectEqualStrings("ab", recorder.text());
}

test "the caret blinks off and on again as real time passes" {
    const gpa = std.testing.allocator;
    var field = TextField{ .blink_period = 100 };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    const s = try f.state();
    try std.testing.expect(s.caret_on);
    f.harness.owner.scheduler.tick(0); // baselines the ticker
    f.harness.owner.scheduler.tick(150); // one and a half periods in: off
    try std.testing.expect(!s.caret_on);
    f.harness.owner.scheduler.tick(250); // two and a half: on again
    try std.testing.expect(s.caret_on);
}

test "an unfocused field draws no caret and a focused one draws it" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "hi" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    f.harness.viewport = .{ .width = 200, .height = 40 };
    try f.harness.pump();

    // Unfocused: the text run only, no caret rectangle.
    try std.testing.expectEqual(@as(usize, 1), f.harness.canvas.list.primitives.items.len);
    _ = f.harness.canvas.list.primitives.items[0].text;

    try f.focus();
    try f.harness.pump();
    const prims = f.harness.canvas.list.primitives.items;
    try std.testing.expectEqual(@as(usize, 2), prims.len);
    // The caret goes down first so a glyph under a block caret still reads.
    const caret = prims[0].rrect;
    try std.testing.expect(caret.rect.width > 0);
    try std.testing.expect(caret.rect.height > 0);
}

test "the caret is drawn at the theme accent colour" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    f.harness.viewport = .{ .width = 200, .height = 40 };
    try f.focus();
    try f.harness.pump();

    const accent = phantom.theme.defaultTheme(f.harness.owner).accent;
    const caret = f.harness.canvas.list.primitives.items[0].rrect;
    try std.testing.expectEqual(accent, caret.color);
}

test "the caret width scales with the layout scale" {
    // Without the scale multiply the caret is half width on a HiDPI display.
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "", .caret_width = 3 };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    f.harness.viewport = .{ .width = 200, .height = 40 };
    try f.focus();

    try f.harness.pump();
    try std.testing.expectEqual(@as(f32, 3), f.harness.canvas.list.primitives.items[0].rrect.rect.width);

    f.harness.dpr = 2.0;
    try f.harness.pump();
    try std.testing.expectEqual(@as(f32, 6), f.harness.canvas.list.primitives.items[0].rrect.rect.width);
}

test "a long line scrolls so the caret stays inside the field" {
    const gpa = std.testing.allocator;
    var field = TextField{};
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    // A narrow field, so a handful of characters already overflow it.
    f.harness.viewport = .{ .width = 60, .height = 40 };
    try f.focus();

    // Type far more than fits.
    var i: u32 = 0;
    while (i < 40) : (i += 1) f.typeText("W");
    try f.harness.pump();

    const prims = f.harness.canvas.list.primitives.items;
    const caret = prims[0].rrect;
    const run = prims[1].text;
    // The run scrolled left, which is what puts the end of the line on screen.
    try std.testing.expect(run.origin.x < 0);
    // The caret is inside the field, not past its right edge.
    try std.testing.expect(caret.rect.x >= 0);
    try std.testing.expect(caret.rect.x + caret.rect.width <= 60.001);

    // Home brings the view back to the start of the line.
    f.press(.home);
    try f.harness.pump();
    const home_prims = f.harness.canvas.list.primitives.items;
    try std.testing.expectEqual(@as(f32, 0), home_prims[1].text.origin.x);
    try std.testing.expectEqual(@as(f32, 0), home_prims[0].rrect.rect.x);
}

test "in a terminal the caret covers a whole cell and the text lands on cells" {
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "hi" };
    var f = try Fixture.init(gpa, &field);
    defer f.deinit();
    try f.focus();

    // One row, because a tight parent wins over the size a child asks for: in a
    // three row grid the field fills all three and the caret with it.
    var r = try f.harness.tuiRender(20, 1, 8, 16);
    defer r.deinit();

    try r.expectCell(0, 0, 'h');
    try r.expectCell(1, 0, 'i');

    // The caret sits after the text and fills its cell, so a terminal shows a
    // block cursor rather than a sliver that rounds away to nothing.
    const prims = f.harness.canvas.list.primitives.items;
    const caret = prims[0].rrect;
    try std.testing.expectEqual(@as(f32, 8), caret.rect.width);
    try std.testing.expectEqual(@as(f32, 16), caret.rect.height);
    try std.testing.expectEqual(@as(f32, 16), caret.rect.x); // two cells in
    try r.expectBg(2, 0, phantom.theme.defaultTheme(f.harness.owner).accent);
}

test "unmounting a focused field cancels its blink registration" {
    // A ticker that outlives its State calls a freed pointer on the next frame.
    const gpa = std.testing.allocator;
    var field = TextField{ .text = "x" };
    var f = try Fixture.init(gpa, &field);
    try f.focus();
    try std.testing.expectEqual(@as(usize, 1), f.harness.owner.scheduler.entries.items.len);

    const owner = f.harness.owner;
    f.harness.root.deinit(gpa);
    // The entry is cancelled rather than merely forgotten, so the next sweep
    // drops it instead of calling into the freed State.
    for (owner.scheduler.entries.items) |e| try std.testing.expect(e.cancelled);
    owner.scheduler.tick(1_000);
    try std.testing.expectEqual(@as(usize, 0), owner.scheduler.entries.items.len);

    // Tear down the rest by hand: the harness root was already freed above.
    // This mirrors `Harness.deinit` and has to be kept in step with it.
    f.harness.focus.deinit(gpa);
    owner.deinit();
    f.harness.canvas.deinit();
    f.harness.arena.deinit();
    gpa.destroy(f.harness.arena);
    gpa.destroy(f.harness.owner);
    gpa.destroy(f.harness.sink);
    gpa.destroy(f.harness.focus);
    f.manager.deinit(gpa);
}

test "previousBoundary and nextBoundary step whole UTF-8 sequences" {
    // One, two, three and four byte sequences in one string.
    const s = "a\u{00E9}\u{20AC}\u{1F600}b";
    try std.testing.expectEqual(@as(usize, 11), s.len);
    // Forward.
    try std.testing.expectEqual(@as(usize, 1), nextBoundary(s, 0));
    try std.testing.expectEqual(@as(usize, 3), nextBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 6), nextBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 10), nextBoundary(s, 6));
    try std.testing.expectEqual(@as(usize, 11), nextBoundary(s, 10));
    try std.testing.expectEqual(@as(usize, 11), nextBoundary(s, 11)); // clamped at the end
    // Backward.
    try std.testing.expectEqual(@as(usize, 10), previousBoundary(s, 11));
    try std.testing.expectEqual(@as(usize, 6), previousBoundary(s, 10));
    try std.testing.expectEqual(@as(usize, 3), previousBoundary(s, 6));
    try std.testing.expectEqual(@as(usize, 1), previousBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 0), previousBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 0), previousBoundary(s, 0)); // clamped at the start
}

test "a malformed byte still lets the caret move, one byte at a time" {
    // Input is never trusted. A lone continuation byte must not stall the caret
    // in a loop, and a lone lead byte must not step past the end of the string.
    const stray = [_]u8{ 0x80, 0x80, 'a' };
    try std.testing.expectEqual(@as(usize, 1), nextBoundary(&stray, 0));
    try std.testing.expectEqual(@as(usize, 0), previousBoundary(&stray, 2));

    const truncated = [_]u8{ 0xF0, 'a' };
    try std.testing.expectEqual(@as(usize, 2), nextBoundary(&truncated, 0)); // clamped to the length
}

test "characterCount counts characters and not bytes" {
    try std.testing.expectEqual(@as(usize, 0), characterCount(""));
    try std.testing.expectEqual(@as(usize, 3), characterCount("abc"));
    try std.testing.expectEqual(@as(usize, 3), characterCount("a\u{20AC}b"));
    try std.testing.expectEqual(@as(usize, 1), characterCount("\u{1F600}"));
}

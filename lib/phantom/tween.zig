//! Interpolation between two values over a normalized `t`. A `Ticker` supplies
//! the elapsed time and the caller turns that into `t`; this module holds no
//! clock, allocates nothing and performs no IO, so the same tween drives a dock
//! hover on the GPU backend and a progress bar in a terminal.
const std = @import("std");
const geom = @import("geometry.zig");

/// How a normalized `t` is shaped before it interpolates. Every curve maps 0 to
/// exactly 0 and 1 to exactly 1, so the ends of an animation land on the values
/// the caller named.
pub const Curve = enum {
    linear,
    ease_in,
    ease_out,
    ease_in_out,
    ease_in_cubic,
    ease_out_cubic,
    ease_in_out_cubic,

    /// Shape `t`, which the caller has already clamped to 0 through 1.
    pub fn apply(self: Curve, t: f32) f32 {
        const inv = 1.0 - t;
        return switch (self) {
            .linear => t,
            .ease_in => t * t,
            .ease_out => 1.0 - inv * inv,
            .ease_in_out => if (t < 0.5) 2.0 * t * t else 1.0 - 2.0 * inv * inv,
            .ease_in_cubic => t * t * t,
            .ease_out_cubic => 1.0 - inv * inv * inv,
            .ease_in_out_cubic => if (t < 0.5) 4.0 * t * t * t else 1.0 - 4.0 * inv * inv * inv,
        };
    }
};

/// Mix `a` and `b` by `t`. `T` is either a float or a struct whose every field is
/// an f32, which covers Color, LogicalOffset, LogicalSize and LogicalRect with no
/// per-type code.
fn mix(comptime T: type, a: T, b: T, t: f32) T {
    // The operand is comptime known, so only the matching prong is compiled and
    // the arithmetic of one prong never has to typecheck for the other.
    switch (@typeInfo(T)) {
        .float => return a + (b - a) * @as(T, @floatCast(t)),
        .@"struct" => |s| {
            var out: T = a;
            inline for (s.fields) |f| {
                if (f.type != f32) {
                    @compileError("Tween(" ++ @typeName(T) ++ "): field '" ++ f.name ++ "' is not f32");
                }
                const fa = @field(a, f.name);
                const fb = @field(b, f.name);
                @field(out, f.name) = fa + (fb - fa) * t;
            }
            return out;
        },
        else => @compileError("Tween(" ++ @typeName(T) ++ ") needs a float or a struct of f32 fields"),
    }
}

/// A pair of values and the curve between them. `at(0)` and `at(1)` return the
/// named values themselves, with no arithmetic that could drift, and a `t`
/// outside the range is clamped rather than extrapolated: an animation whose
/// clock overruns must stop at its end value, not sail past it.
pub fn Tween(comptime T: type) type {
    return struct {
        const Self = @This();

        begin: T,
        end: T,
        curve: Curve = .linear,

        pub fn at(self: Self, t: f32) T {
            // The comparisons come before the clamp so an infinite or reversed
            // input lands on an end value rather than reaching the arithmetic.
            if (!(t > 0)) return self.begin;
            if (t >= 1) return self.end;
            return mix(T, self.begin, self.end, self.curve.apply(t));
        }

        /// The value at `elapsed` nanoseconds into an animation of `duration`
        /// nanoseconds. A duration of zero or less is already finished, which is
        /// what a caller with no animation configured asks for.
        pub fn atTime(self: Self, elapsed: i96, duration: i96) T {
            if (duration <= 0) return self.end;
            if (elapsed <= 0) return self.begin;
            if (elapsed >= duration) return self.end;
            // f64 through the division: a nanosecond count large enough to lose
            // f32 precision is still only a few seconds of animation.
            const e: f64 = @floatFromInt(elapsed);
            const d: f64 = @floatFromInt(duration);
            return self.at(@floatCast(e / d));
        }
    };
}

test "a tween returns its exact end values at t of 0 and 1" {
    // 0.1 and 0.3 are not representable in binary, so `a + (b - a) * 1` lands a
    // few bits short of 0.3. An equality check on the end of an animation then
    // never fires and the widget animates forever.
    const t = Tween(f32){ .begin = 0.1, .end = 0.3 };
    try std.testing.expectEqual(@as(f32, 0.1), t.at(0));
    try std.testing.expectEqual(@as(f32, 0.3), t.at(1));
}

test "every curve returns its exact end values at t of 0 and 1" {
    inline for (@typeInfo(Curve).@"enum".fields) |f| {
        const curve: Curve = @enumFromInt(f.value);
        const t = Tween(f32){ .begin = 4, .end = 7, .curve = curve };
        try std.testing.expectEqual(@as(f32, 4), t.at(0));
        try std.testing.expectEqual(@as(f32, 7), t.at(1));
        // The shaping function must agree with the tween at both ends.
        try std.testing.expectEqual(@as(f32, 0), curve.apply(0));
        try std.testing.expectEqual(@as(f32, 1), curve.apply(1));
    }
}

test "a t outside 0 to 1 is clamped and never extrapolated" {
    const t = Tween(f32){ .begin = 10, .end = 20 };
    try std.testing.expectEqual(@as(f32, 10), t.at(-5));
    try std.testing.expectEqual(@as(f32, 20), t.at(5));
    try std.testing.expectEqual(@as(f32, 10), t.at(-std.math.inf(f32)));
    try std.testing.expectEqual(@as(f32, 20), t.at(std.math.inf(f32)));
}

test "a linear tween reaches its midpoint at t of one half" {
    const t = Tween(f32){ .begin = 0, .end = 100 };
    try std.testing.expectApproxEqAbs(@as(f32, 50), t.at(0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 25), t.at(0.25), 0.001);
}

test "a colour tween interpolates every channel including alpha" {
    // Alpha is the channel a hand written mix forgets, and a dropped alpha makes
    // a fade in appear instantly at full opacity.
    const from = geom.Color{ .r = 0, .g = 0.25, .b = 1, .a = 0 };
    const to = geom.Color{ .r = 1, .g = 0.75, .b = 0, .a = 1 };
    const t = Tween(geom.Color){ .begin = from, .end = to };
    const half = t.at(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), half.r, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), half.g, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), half.b, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), half.a, 0.001);
    // The ends stay exact, alpha included.
    try std.testing.expectEqual(from, t.at(0));
    try std.testing.expectEqual(to, t.at(1));
}

test "an offset tween interpolates both axes" {
    const t = Tween(geom.LogicalOffset){
        .begin = .{ .x = 0, .y = 100 },
        .end = .{ .x = 40, .y = 0 },
    };
    const q = t.at(0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 10), q.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 75), q.y, 0.001);
}

test "a size tween interpolates width and height" {
    const t = Tween(geom.LogicalSize){
        .begin = .{ .width = 10, .height = 10 },
        .end = .{ .width = 30, .height = 50 },
    };
    const half = t.at(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 20), half.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 30), half.height, 0.001);
}

test "ease_in starts slower than linear and ease_out starts faster" {
    // A curve that is applied in the wrong direction still passes an ends only
    // test, so the shape has to be pinned in the middle of the range.
    const slow = Curve.ease_in.apply(0.25);
    const fast = Curve.ease_out.apply(0.25);
    try std.testing.expect(slow < 0.25);
    try std.testing.expect(fast > 0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0625), slow, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4375), fast, 0.001);
}

test "the ease_in_out curves are symmetric about the halfway point" {
    for ([_]Curve{ .ease_in_out, .ease_in_out_cubic }) |curve| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), curve.apply(0.5), 0.001);
        // f(t) + f(1 - t) must sum to 1 for a symmetric curve.
        for ([_]f32{ 0.1, 0.25, 0.4 }) |t| {
            try std.testing.expectApproxEqAbs(@as(f32, 1), curve.apply(t) + curve.apply(1 - t), 0.001);
        }
    }
}

test "every curve stays inside 0 to 1 across the whole range" {
    inline for (@typeInfo(Curve).@"enum".fields) |f| {
        const curve: Curve = @enumFromInt(f.value);
        var i: u32 = 0;
        while (i <= 100) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / 100.0;
            const v = curve.apply(t);
            try std.testing.expect(v >= 0 and v <= 1);
        }
    }
}

test "every curve rises without ever going backwards" {
    // A non-monotonic curve makes an animation jitter backwards mid flight.
    inline for (@typeInfo(Curve).@"enum".fields) |f| {
        const curve: Curve = @enumFromInt(f.value);
        var previous: f32 = 0;
        var i: u32 = 1;
        while (i <= 100) : (i += 1) {
            const v = curve.apply(@as(f32, @floatFromInt(i)) / 100.0);
            try std.testing.expect(v >= previous);
            previous = v;
        }
    }
}

test "atTime maps an elapsed nanosecond count onto the tween" {
    const t = Tween(f32){ .begin = 0, .end = 200 };
    const second: i96 = 1_000_000_000;
    try std.testing.expectEqual(@as(f32, 0), t.atTime(0, second));
    try std.testing.expectApproxEqAbs(@as(f32, 100), t.atTime(@divExact(second, 2), second), 0.001);
    try std.testing.expectEqual(@as(f32, 200), t.atTime(second, second));
    // An overrun holds at the end rather than running past it.
    try std.testing.expectEqual(@as(f32, 200), t.atTime(second * 10, second));
    // A zero duration is already finished.
    try std.testing.expectEqual(@as(f32, 200), t.atTime(0, 0));
}

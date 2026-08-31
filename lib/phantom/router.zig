//! Routing for every backend. A route table maps a path to a build function,
//! and a bounded stack holds the history. The browser is not in this file:
//! `phantom.platform` carries the location hooks that a backend fills in.

const std = @import("std");

/// A path longer than this is refused. 128 bytes holds every route this
/// framework is meant for, and a fixed size keeps the stack free of an
/// allocator.
pub const max_path = 128;

/// The deepest the history can go. A deeper stack is a navigation loop, which
/// is a fault and not a state to grow into.
pub const max_stack = 16;

/// One path, copied into fixed storage. A caller's slice can point into a
/// build arena that is reset every frame, so the stack never holds a borrowed
/// path.
pub const Location = struct {
    buf: [max_path]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Location, path: []const u8) error{PathTooLong}!void {
        if (path.len > max_path) return error.PathTooLong;
        @memcpy(self.buf[0..path.len], path);
        self.len = path.len;
    }

    pub fn slice(self: *const Location) []const u8 {
        return self.buf[0..self.len];
    }
};

/// The history. Bounded, and it owns every path in it.
pub const Stack = struct {
    entries: [max_stack]Location = undefined,
    count: usize = 0,

    pub fn init(path: []const u8) error{PathTooLong}!Stack {
        var s = Stack{};
        s.entries[0] = .{};
        try s.entries[0].set(path);
        s.count = 1;
        return s;
    }

    pub fn depth(self: *const Stack) usize {
        return self.count;
    }

    /// The top of the stack. The stack is never empty: `init` fills it and
    /// `pop` refuses to remove the last entry.
    pub fn current(self: *const Stack) []const u8 {
        std.debug.assert(self.count > 0);
        return self.entries[self.count - 1].slice();
    }

    pub fn push(self: *Stack, path: []const u8) error{ PathTooLong, StackFull }!void {
        if (self.count == max_stack) return error.StackFull;
        var loc = Location{};
        try loc.set(path);
        self.entries[self.count] = loc;
        self.count += 1;
    }

    /// True if a level was removed. False at the bottom, where there is
    /// nothing to go back to.
    pub fn pop(self: *Stack) bool {
        if (self.count <= 1) return false;
        self.count -= 1;
        return true;
    }

    pub fn replace(self: *Stack, path: []const u8) error{PathTooLong}!void {
        std.debug.assert(self.count > 0);
        try self.entries[self.count - 1].set(path);
    }
};

test "a location holds the path it was set from" {
    var loc = Location{};
    try loc.set("/gallery");
    try std.testing.expectEqualStrings("/gallery", loc.slice());
}

test "a location refuses a path longer than the buffer" {
    var loc = Location{};
    const long = "/" ++ ("a" ** max_path);
    try std.testing.expectError(error.PathTooLong, loc.set(long));
}

test "a new stack is one deep and reads the initial path" {
    var s = try Stack.init("/");
    try std.testing.expectEqual(@as(usize, 1), s.depth());
    try std.testing.expectEqualStrings("/", s.current());
}

test "push adds a level and pop returns to the one below" {
    var s = try Stack.init("/");
    try s.push("/gallery");
    try std.testing.expectEqual(@as(usize, 2), s.depth());
    try std.testing.expectEqualStrings("/gallery", s.current());
    try std.testing.expect(s.pop());
    try std.testing.expectEqualStrings("/", s.current());
}

test "pop at the bottom keeps the last location and reports that it did nothing" {
    var s = try Stack.init("/");
    try std.testing.expect(!s.pop());
    try std.testing.expectEqual(@as(usize, 1), s.depth());
    try std.testing.expectEqualStrings("/", s.current());
}

test "replace changes the top without growing the stack" {
    var s = try Stack.init("/");
    try s.push("/about");
    try s.replace("/gallery");
    try std.testing.expectEqual(@as(usize, 2), s.depth());
    try std.testing.expectEqualStrings("/gallery", s.current());
}

test "a full stack refuses another push and keeps its top" {
    var s = try Stack.init("/");
    var i: usize = 1;
    while (i < max_stack) : (i += 1) try s.push("/gallery");
    try std.testing.expectEqual(@as(usize, max_stack), s.depth());
    try std.testing.expectError(error.StackFull, s.push("/about"));
    try std.testing.expectEqualStrings("/gallery", s.current());
}

test "the stack copies the path, so a caller's buffer can change afterwards" {
    var buf = [_]u8{ '/', 'a' };
    var s = try Stack.init(&buf);
    buf[1] = 'b';
    try std.testing.expectEqualStrings("/a", s.current());
}

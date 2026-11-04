//! HTTP/2 flow-control windows (RFC 9113 §5.2, §6.9).
//!
//! A window counts the bytes a peer may still send (the receive side) or this
//! endpoint may still send (the send side). It is signed because
//! SETTINGS_INITIAL_WINDOW_SIZE can shrink below the bytes already sent, and a
//! sender must wait for WINDOW_UPDATE to bring the window positive again
//! (§6.9.2).
//!
//! This module is accounting only. It does not decide whether an error is a
//! connection or a stream error; the session does.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

/// The largest flow-control window, 2^31-1.
pub const max_window: i64 = 0x7fff_ffff;

pub const Error = error{
    /// The frame carries more than the window allows, or an update overflows it.
    FlowControlError,
    /// A WINDOW_UPDATE increment of zero (RFC 9113 §6.9).
    ZeroIncrement,
};

pub const Window = struct {
    available: i64,

    pub fn init(initial: u32) Window {
        assert(initial <= max_window);
        return .{ .available = initial };
    }

    /// Account for `count` bytes of DATA. A send window must be positive
    /// before the bytes are written; a receive window rejects bytes over its
    /// limit.
    pub fn consume(self: *Window, count: u32) Error!void {
        if (@as(i64, count) > self.available) return error.FlowControlError;
        self.available -= count;
    }

    /// Apply a WINDOW_UPDATE increment.
    pub fn increase(self: *Window, increment: u31) Error!void {
        if (increment == 0) return error.ZeroIncrement;
        const next = self.available + increment;
        if (next > max_window) return error.FlowControlError;
        self.available = next;
    }

    /// Apply the delta from a SETTINGS_INITIAL_WINDOW_SIZE change to one
    /// stream's window. The result may be negative.
    pub fn applyInitialChange(self: *Window, old: u32, new: u32) Error!void {
        const next = self.available + @as(i64, new) - @as(i64, old);
        if (next > max_window) return error.FlowControlError;
        self.available = next;
    }
};

test "a window starts at its initial value" {
    const window = Window.init(65_535);
    try testing.expectEqual(@as(i64, 65_535), window.available);
}

test "consume subtracts and refuses to overdraw" {
    var window = Window.init(10);
    try window.consume(0);
    try testing.expectEqual(@as(i64, 10), window.available);
    try window.consume(10);
    try testing.expectEqual(@as(i64, 0), window.available);
    try testing.expectError(error.FlowControlError, window.consume(1));
}

test "increase refuses zero and overflow" {
    var window = Window.init(0);
    try testing.expectError(error.ZeroIncrement, window.increase(0));
    try window.increase(5);
    try testing.expectEqual(@as(i64, 5), window.available);

    var full = Window.init(@intCast(max_window));
    try testing.expectError(error.FlowControlError, full.increase(1));
}

test "a shrink may make the window negative, and updates bring it back" {
    var window = Window.init(65_535);
    // 2,000 bytes sent against a 65,535 window leaves 63,535.
    try window.consume(2000);
    try testing.expectEqual(@as(i64, 63_535), window.available);

    // The peer lowered its initial window below what we already sent.
    try window.applyInitialChange(65_535, 1000);
    try testing.expectEqual(@as(i64, -1000), window.available);
    try testing.expectError(error.FlowControlError, window.consume(1));

    try window.increase(1500);
    try testing.expectEqual(@as(i64, 500), window.available);
    try window.consume(500);
    try testing.expectEqual(@as(i64, 0), window.available);
}

test "a growth applies the delta, and the maximum is enforced" {
    var window = Window.init(65_535);
    try window.applyInitialChange(65_535, 100_000);
    try testing.expectEqual(@as(i64, 100_000), window.available);
    try window.applyInitialChange(100_000, 0);
    try testing.expectEqual(@as(i64, 0), window.available);
}

test "growth above 2^31-1 is a flow-control error" {
    var window = Window.init(@intCast(max_window));
    try testing.expectError(error.FlowControlError, window.applyInitialChange(0, 0x7fff_ffff));
}

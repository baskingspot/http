//! SETTINGS state for one direction (RFC 9113 §6.5.2).
//!
//! Two `Values` live on a connection: the local settings this endpoint
//! advertises, and the remote settings the peer sent. `apply` reads a SETTINGS
//! payload, validates the defined identifiers, and lets the last value win.
//! Unknown identifiers are ignored, as the registry requires.
//!
//! A change to `initial_window_size` does not touch stream windows here; the
//! flow-control layer applies the delta to every open stream (§6.9.2).

const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const frame = @import("frame.zig");

/// The endpoint's own role. The peer has the other role.
pub const Role = enum { client, server };

// ast-grep-ignore: public-struct-field-default -- the field defaults are the protocol defaults
pub const Values = struct {
    header_table_size: u32 = 4096,
    enable_push: bool = true,
    /// null means unlimited (the initial state).
    max_concurrent_streams: ?u32 = null,
    initial_window_size: u32 = 65_535,
    max_frame_size: u32 = frame.default_max_frame_size,
    /// null means unlimited.
    max_header_list_size: ?u32 = null,
};

pub const Error = error{
    /// ENABLE_PUSH was not 0 or 1.
    InvalidEnablePush,
    /// A server sent ENABLE_PUSH = 1 (RFC 9113 §6.5.2).
    ServerEnablePush,
    /// INITIAL_WINDOW_SIZE was above 2^31-1.
    InvalidInitialWindowSize,
    /// MAX_FRAME_SIZE was outside 16,384..16,777,215.
    InvalidMaxFrameSize,
};

/// Apply a peer's SETTINGS payload. `local_role` is this endpoint's role; the
/// peer is the other one.
pub fn apply(values: *Values, local_role: Role, settings: frame.Settings) Error!void {
    var entries = settings.iterator();
    while (entries.next()) |entry| {
        switch (entry.id) {
            .header_table_size => values.header_table_size = entry.value,

            .enable_push => {
                if (entry.value > 1) return error.InvalidEnablePush;
                if (local_role == .client and entry.value == 1) return error.ServerEnablePush;
                values.enable_push = entry.value == 1;
            },

            .max_concurrent_streams => values.max_concurrent_streams = entry.value,

            .initial_window_size => {
                if (entry.value > 0x7fff_ffff) return error.InvalidInitialWindowSize;
                values.initial_window_size = entry.value;
            },

            .max_frame_size => {
                if (entry.value < frame.min_max_frame_size or
                    entry.value > frame.max_frame_size_limit) return error.InvalidMaxFrameSize;
                values.max_frame_size = entry.value;
            },

            .max_header_list_size => values.max_header_list_size = entry.value,

            else => {},
        }
    }
}

test "defaults are the RFC 9113 §6.5.2 values" {
    const values: Values = .{};
    try testing.expectEqual(@as(u32, 4096), values.header_table_size);
    try testing.expect(values.enable_push);
    try testing.expect(values.max_concurrent_streams == null);
    try testing.expectEqual(@as(u32, 65_535), values.initial_window_size);
    try testing.expectEqual(frame.default_max_frame_size, values.max_frame_size);
    try testing.expect(values.max_header_list_size == null);
}

fn applyOne(values: *Values, role: Role, id: frame.SettingId, value: u32) Error!void {
    var payload: [6]u8 = undefined;
    mem.writeInt(u16, payload[0..2], @intFromEnum(id), .big);
    mem.writeInt(u32, payload[2..6], value, .big);
    try apply(values, role, .{ .ack = false, .payload = &payload });
}

test "each defined setting is applied" {
    var values: Values = .{};
    try applyOne(&values, .server, .header_table_size, 1024);
    try applyOne(&values, .server, .enable_push, 0);
    try applyOne(&values, .server, .max_concurrent_streams, 0);
    try applyOne(&values, .server, .initial_window_size, 1024);
    try applyOne(&values, .server, .max_frame_size, 32_768);
    try applyOne(&values, .server, .max_header_list_size, 8192);

    try testing.expectEqual(@as(u32, 1024), values.header_table_size);
    try testing.expect(!values.enable_push);
    try testing.expectEqual(@as(?u32, 0), values.max_concurrent_streams);
    try testing.expectEqual(@as(u32, 1024), values.initial_window_size);
    try testing.expectEqual(@as(u32, 32_768), values.max_frame_size);
    try testing.expectEqual(@as(?u32, 8192), values.max_header_list_size);
}

test "the last value in a payload wins, and unknown identifiers are ignored" {
    var values: Values = .{};
    const payload = [_]u8{
        0, 1, 0, 0, 4, 0, // HEADER_TABLE_SIZE 1024
        0x12, 0x34, 0, 0, 0, 1, // unknown
        0, 1, 0, 0, 8, 0, // HEADER_TABLE_SIZE 2048
    };
    try apply(&values, .server, .{ .ack = false, .payload = &payload });
    try testing.expectEqual(@as(u32, 2048), values.header_table_size);
}

test "ENABLE_PUSH is 0 or 1, and a server may not send 1" {
    var values: Values = .{};
    try testing.expectError(
        error.InvalidEnablePush,
        applyOne(&values, .client, .enable_push, 2),
    );
    try testing.expectError(
        error.ServerEnablePush,
        applyOne(&values, .client, .enable_push, 1),
    );
    try applyOne(&values, .server, .enable_push, 1);
    try testing.expect(values.enable_push);
}

test "INITIAL_WINDOW_SIZE is at most 2^31-1" {
    var values: Values = .{};
    try applyOne(&values, .server, .initial_window_size, 0x7fff_ffff);
    try testing.expectEqual(@as(u32, 0x7fff_ffff), values.initial_window_size);
    try testing.expectError(
        error.InvalidInitialWindowSize,
        applyOne(&values, .server, .initial_window_size, 0x8000_0000),
    );
}

test "MAX_FRAME_SIZE is within 16,384..16,777,215" {
    var values: Values = .{};
    try applyOne(&values, .server, .max_frame_size, 16_384);
    try applyOne(&values, .server, .max_frame_size, 0xff_ffff);
    try testing.expectEqual(@as(u32, 0xff_ffff), values.max_frame_size);
    try testing.expectError(
        error.InvalidMaxFrameSize,
        applyOne(&values, .server, .max_frame_size, 16_383),
    );
    try testing.expectError(
        error.InvalidMaxFrameSize,
        applyOne(&values, .server, .max_frame_size, 0x100_0000),
    );
}

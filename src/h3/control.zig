//! The HTTP/3 control stream and unidirectional stream types
//! (RFC 9114 §6.2, §7.2).
//!
//! A unidirectional stream starts with a varint type. 0x00 is the control
//! stream, 0x01 a push stream, 0x02 the QPACK encoder stream, and 0x03 the
//! QPACK decoder stream. Reserved and unknown types are discarded. The
//! control stream is critical: its closure is H3_CLOSED_CRITICAL_STREAM, and
//! the session owns that check.
//!
//! `Control` is the peer's control-stream state. The first frame must be
//! SETTINGS; a second SETTINGS is H3_FRAME_UNEXPECTED. GOAWAY and MAX_PUSH_ID
//! are monotonic, and GOAWAY on a client must name a client-initiated
//! bidirectional stream. Server push is not implemented, so CANCEL_PUSH and
//! every PUSH_PROMISE are errors.

const std = @import("std");
const testing = std.testing;

const frame = @import("frame.zig");
const settings = @import("settings.zig");
const varint = @import("../varint.zig");

pub const Role = enum { client, server };

/// The four defined unidirectional stream types.
pub const Kind = enum(u62) {
    control = 0x00,
    push = 0x01,
    encoder = 0x02,
    decoder = 0x03,
};

/// The kind of a unidirectional stream type, or null for a reserved or
/// unknown type. Both are discarded.
pub fn streamType(value: u62) ?Kind {
    return switch (value) {
        0x00 => .control,
        0x01 => .push,
        0x02 => .encoder,
        0x03 => .decoder,
        else => null,
    };
}

/// Whether `value` is one of the exercise-and-ignore stream types,
/// 0x1f * N + 0x21 (RFC 9114 §6.2.3).
pub fn isReservedStreamType(value: u62) bool {
    return value >= 0x21 and (value - 0x21) % 0x1f == 0;
}

pub const Error = error{
    /// A non-SETTINGS frame arrived before SETTINGS.
    MissingSettings,
    /// A frame is not allowed on the control stream, or SETTINGS repeated.
    UnexpectedFrame,
    /// A GOAWAY or MAX_PUSH_ID moved the wrong way, or named the wrong kind
    /// of stream.
    IdError,
    /// The SETTINGS payload is invalid (reserved id, duplicate id).
    SettingsError,
};

pub const Event = union(enum) {
    settings: settings.Values,
    goaway: u62,
    max_push_id: u62,
};

pub const Control = struct {
    role: Role,
    settings_seen: bool,
    goaway: ?u62,
    max_push_id: ?u62,

    pub fn init(role: Role) Control {
        return .{
            .role = role,
            .settings_seen = false,
            .goaway = null,
            .max_push_id = null,
        };
    }

    /// Feed one complete control-stream frame. Null means the frame was an
    /// unknown extension and is ignored.
    pub fn receive(self: *Control, value: frame.Body) Error!?Event {
        // §6.2.1: any frame other than SETTINGS as the first frame is
        // H3_MISSING_SETTINGS, not H3_FRAME_UNEXPECTED.
        if (!self.settings_seen) {
            switch (value) {
                .settings => {},
                else => return error.MissingSettings,
            }
        }

        switch (value) {
            .settings => |entries| {
                if (self.settings_seen) return error.UnexpectedFrame;

                var values = settings.Values.zero();
                settings.apply(&values, entries) catch |err| switch (err) {
                    error.ReservedSetting,
                    error.DuplicateSetting,
                    error.TooManySettings,
                    => return error.SettingsError,
                };
                self.settings_seen = true;
                return .{ .settings = values };
            },

            .goaway => |id| {
                if (self.goaway) |last| {
                    if (id > last) return error.IdError;
                }
                // A server's GOAWAY names a client-initiated bidirectional
                // stream, whose low two bits are zero.
                if (self.role == .client and id & 0x3 != 0) return error.IdError;
                self.goaway = id;
                return .{ .goaway = id };
            },

            .max_push_id => |id| {
                if (self.role == .client) return error.UnexpectedFrame;
                if (self.max_push_id) |last| {
                    if (id < last) return error.IdError;
                }
                self.max_push_id = id;
                return .{ .max_push_id = id };
            },

            .cancel_push => |id| {
                // No push is implemented, so no promise can exist.
                _ = id;
                return error.IdError;
            },

            .data, .headers, .push_promise => return error.UnexpectedFrame,

            .unknown => return null,
        }
    }
};

fn receiveSettings(control: *Control, values: settings.Values) !?Event {
    var payload_buf: [64]u8 = undefined;
    const payload = try settings.write(&payload_buf, values);
    var frame_buf: [128]u8 = undefined;
    const bytes = try frame.write(&frame_buf, .settings, payload);
    return control.receive((try frame.parse(bytes)).body);
}

fn receiveVarint(control: *Control, frame_type: frame.FrameType, id: u62) !?Event {
    var payload_buf: [8]u8 = undefined;
    const payload = try varint.encode(&payload_buf, id);
    var frame_buf: [16]u8 = undefined;
    const bytes = try frame.write(&frame_buf, frame_type, payload);
    return control.receive((try frame.parse(bytes)).body);
}

fn receiveBytes(control: *Control, frame_type: frame.FrameType, payload: []const u8) !?Event {
    var frame_buf: [64]u8 = undefined;
    const bytes = try frame.write(&frame_buf, frame_type, payload);
    return control.receive((try frame.parse(bytes)).body);
}

test "the control stream must start with SETTINGS" {
    var control = Control.init(.server);
    try testing.expectError(error.MissingSettings, receiveVarint(&control, .goaway, 0));
    try testing.expectError(error.MissingSettings, receiveBytes(&control, .data, ""));
}

test "SETTINGS is first and cannot repeat" {
    var control = Control.init(.server);
    var values = settings.Values.zero();
    values.qpack_max_table_capacity = 220;
    const event = (try receiveSettings(&control, values)).?.settings;
    try testing.expectEqual(@as(u62, 220), event.qpack_max_table_capacity);

    try testing.expectError(
        error.UnexpectedFrame,
        receiveSettings(&control, settings.Values.zero()),
    );
}

test "GOAWAY is monotonic and names the right stream kind" {
    var server = Control.init(.server);
    _ = try receiveSettings(&server, settings.Values.zero());
    _ = try receiveVarint(&server, .goaway, 12);
    _ = try receiveVarint(&server, .goaway, 8);
    try testing.expectError(error.IdError, receiveVarint(&server, .goaway, 16));

    var client = Control.init(.client);
    _ = try receiveSettings(&client, settings.Values.zero());
    _ = try receiveVarint(&client, .goaway, 4);
    try testing.expectError(error.IdError, receiveVarint(&client, .goaway, 3));
    try testing.expectError(error.IdError, receiveVarint(&client, .goaway, 8));
}

test "MAX_PUSH_ID is a server receipt and cannot decrease" {
    var server = Control.init(.server);
    _ = try receiveSettings(&server, settings.Values.zero());
    _ = try receiveVarint(&server, .max_push_id, 5);
    _ = try receiveVarint(&server, .max_push_id, 8);
    try testing.expectError(error.IdError, receiveVarint(&server, .max_push_id, 3));

    var client = Control.init(.client);
    _ = try receiveSettings(&client, settings.Values.zero());
    try testing.expectError(error.UnexpectedFrame, receiveVarint(&client, .max_push_id, 5));
}

test "CANCEL_PUSH is an IdError without push support" {
    var control = Control.init(.server);
    _ = try receiveSettings(&control, settings.Values.zero());
    try testing.expectError(error.IdError, receiveVarint(&control, .cancel_push, 0));
}

test "DATA, HEADERS, and PUSH_PROMISE are not control frames" {
    var control = Control.init(.server);
    _ = try receiveSettings(&control, settings.Values.zero());

    try testing.expectError(error.UnexpectedFrame, receiveBytes(&control, .data, ""));
    try testing.expectError(error.UnexpectedFrame, receiveBytes(&control, .headers, ""));
    try testing.expectError(
        error.UnexpectedFrame,
        receiveBytes(&control, .push_promise, &.{0}),
    );
}

test "an unknown frame is ignored after SETTINGS, and is an error before it" {
    const unknown: frame.FrameType = @fromBackingInt(@intCast(0x21));

    var control = Control.init(.server);
    try testing.expectError(error.MissingSettings, receiveBytes(&control, unknown, ""));

    _ = try receiveSettings(&control, settings.Values.zero());
    try testing.expect((try receiveBytes(&control, unknown, "")) == null);
}

test "stream types classify and the reserved pattern is named" {
    try testing.expectEqual(Kind.control, streamType(0x00).?);
    try testing.expectEqual(Kind.push, streamType(0x01).?);
    try testing.expectEqual(Kind.encoder, streamType(0x02).?);
    try testing.expectEqual(Kind.decoder, streamType(0x03).?);
    try testing.expect(streamType(0x04) == null);

    try testing.expect(isReservedStreamType(0x21));
    try testing.expect(isReservedStreamType(0x40));
    try testing.expect(!isReservedStreamType(0x22));
    try testing.expect(!isReservedStreamType(0x100));
}

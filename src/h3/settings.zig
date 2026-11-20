//! HTTP/3 SETTINGS (RFC 9114 §7.2.4, RFC 9204 §5).
//!
//! A SETTINGS frame payload is a sequence of identifier/value varint pairs.
//! The three HTTP/3 settings are QPACK_MAX_TABLE_CAPACITY (0x01),
//! MAX_FIELD_SECTION_SIZE (0x06), and QPACK_BLOCKED_STREAMS (0x07). The four
//! HTTP/2 identifiers without an HTTP/3 equivalent (0x02..0x05) are reserved:
//! receipt is H3_SETTINGS_ERROR. Unknown identifiers are ignored, and a
//! duplicate identifier is H3_SETTINGS_ERROR.
//!
//! This module handles the payload only. `h3.control` owns the SETTINGS-first
//! rule on the control stream, and `h3.frame` owns the frame header.

const std = @import("std");
const testing = std.testing;

const frame = @import("frame.zig");
const varint = @import("../varint.zig");

pub const ApplyError = error{
    /// A setting reserved from HTTP/2 (0x02..0x05).
    ReservedSetting,
    /// The same identifier appeared twice.
    DuplicateSetting,
    /// More settings in one frame than the duplicate check holds.
    TooManySettings,
};

pub const WriteError = error{
    /// The destination buffer cannot hold the payload.
    NoSpace,
};

/// The largest SETTINGS payload this decoder will scan for duplicates.
pub const max_settings = 64;

pub const Values = struct {
    /// SETTINGS_QPACK_MAX_TABLE_CAPACITY (0x01).
    qpack_max_table_capacity: u62,
    /// SETTINGS_MAX_FIELD_SECTION_SIZE (0x06); null is unlimited.
    max_field_section_size: ?u62,
    /// SETTINGS_QPACK_BLOCKED_STREAMS (0x07).
    qpack_blocked_streams: u62,

    /// The initial value of every setting.
    pub fn zero() Values {
        return .{
            .qpack_max_table_capacity = 0,
            .max_field_section_size = null,
            .qpack_blocked_streams = 0,
        };
    }
};

/// Apply a peer's SETTINGS payload. The last value wins is not enough: a
/// duplicate is an error, not a later override.
pub fn apply(values: *Values, settings: frame.Settings) ApplyError!void {
    var seen: [max_settings]u62 = undefined;
    var count: usize = 0;

    var entries = settings.iterator();
    while (entries.next()) |entry| {
        if (isReserved(entry.id)) return error.ReservedSetting;
        for (seen[0..count]) |id| {
            if (id == entry.id) return error.DuplicateSetting;
        }
        if (count == max_settings) return error.TooManySettings;
        seen[count] = entry.id;
        count += 1;

        switch (entry.id) {
            0x01 => values.qpack_max_table_capacity = entry.value,
            0x06 => values.max_field_section_size = entry.value,
            0x07 => values.qpack_blocked_streams = entry.value,
            else => {},
        }
    }
}

/// Whether `id` is one of the HTTP/2 settings RFC 9114 §11.2.2 reserved.
pub fn isReserved(id: u62) bool {
    return id >= 0x02 and id <= 0x05;
}

/// The bytes `write` needs for this SETTINGS payload.
pub fn encodedLen(values: Values) usize {
    var total = pairLen(0x01, values.qpack_max_table_capacity);
    if (values.max_field_section_size) |max| total += pairLen(0x06, max);
    total += pairLen(0x07, values.qpack_blocked_streams);
    return total;
}

/// Write a SETTINGS payload. The caller wraps it with `frame.write(.., .settings, ..)`.
pub fn write(buf: []u8, values: Values) WriteError![]u8 {
    if (buf.len < encodedLen(values)) return error.NoSpace;

    var pos: usize = 0;
    pos += try pair(buf[pos..], 0x01, values.qpack_max_table_capacity);
    if (values.max_field_section_size) |max| {
        pos += try pair(buf[pos..], 0x06, max);
    }
    pos += try pair(buf[pos..], 0x07, values.qpack_blocked_streams);
    return buf[0..pos];
}

fn pairLen(id: u62, value: u62) usize {
    return varint.encodedLen(id) + varint.encodedLen(value);
}

fn pair(buf: []u8, id: u62, value: u62) WriteError!usize {
    var pos: usize = 0;
    pos += (try varint.encode(buf[pos..], id)).len;
    pos += (try varint.encode(buf[pos..], value)).len;
    return pos;
}

fn parsePayload(buf: []u8, payload: []const u8) !frame.Settings {
    const bytes = try frame.write(buf, .settings, payload);
    const parsed = try frame.parse(bytes);
    return parsed.body.settings;
}

test "write emits the three settings in order" {
    var buf: [32]u8 = undefined;

    const defaults = try write(&buf, Values.zero());
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x07, 0x00 }, defaults);
    try testing.expectEqual(encodedLen(Values.zero()), defaults.len);

    const values: Values = .{
        .qpack_max_table_capacity = 220,
        .max_field_section_size = 100,
        .qpack_blocked_streams = 2,
    };
    const bytes = try write(&buf, values);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x01, 0x40, 0xdc, 0x06, 0x40, 0x64, 0x07, 0x02 },
        bytes,
    );
    try testing.expectEqual(encodedLen(values), bytes.len);
}

test "apply reads the three settings" {
    var buf: [32]u8 = undefined;
    const payload = try write(&buf, .{
        .qpack_max_table_capacity = 220,
        .max_field_section_size = 100,
        .qpack_blocked_streams = 2,
    });

    var frame_buf: [512]u8 = undefined;
    var values = Values.zero();
    try apply(&values, try parsePayload(&frame_buf, payload));
    try testing.expectEqual(@as(u62, 220), values.qpack_max_table_capacity);
    try testing.expectEqual(@as(?u62, 100), values.max_field_section_size);
    try testing.expectEqual(@as(u62, 2), values.qpack_blocked_streams);
}

test "a duplicate, a reserved HTTP/2 id, and an unknown id" {
    var frame_buf: [512]u8 = undefined;
    var values = Values.zero();

    try testing.expectError(
        error.DuplicateSetting,
        apply(&values, try parsePayload(&frame_buf, &.{ 0x01, 0x00, 0x01, 0x01 })),
    );

    for ([_]u8{ 0x02, 0x03, 0x04, 0x05 }) |id| {
        try testing.expectError(
            error.ReservedSetting,
            apply(&values, try parsePayload(&frame_buf, &.{ id, 0x00 })),
        );
    }

    // 0x21 is the exercise-and-ignore setting.
    try apply(&values, try parsePayload(&frame_buf, &.{ 0x21, 0x00 }));
    try testing.expectEqual(@as(u62, 0), values.qpack_max_table_capacity);
}

test "a short destination is NoSpace" {
    var buf: [2]u8 = undefined;
    try testing.expectError(error.NoSpace, write(&buf, Values.zero()));
}

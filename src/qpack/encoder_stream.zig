//! QPACK encoder-stream instructions (RFC 9204 §4.3).
//!
//! The encoder stream is an unframed sequence of instructions. There is no
//! length prefix, so the only way to find the end is to parse. A caller that
//! feeds a stream in pieces keeps a copy of the cursor and commits it only when
//! an instruction parses; on `error.Truncated`, the parser has moved the
//! cursor and the caller restores the copy.
//!
//! The parser does not touch a dynamic table. It returns the reference an
//! instruction names, and the caller resolves it. A dynamic-relative index in
//! an encoder instruction is relative to the insertion point (the current
//! insert count), not to a field section's Base (RFC 9204 §3.2.5). The caller
//! must copy a referenced name out of the table before inserting, because the
//! insert can evict the entry the name lives in (§3.2.2).
//!
//! Strings are copied into the caller's `out` buffer. An `insert_literal` puts
//! the name first and the value after it, and both slices borrow `out`.

const std = @import("std");
const testing = std.testing;

const Cursor = @import("../Cursor.zig");
const prefix_int = @import("../prefix_int.zig");
const string = @import("string.zig");
const dynamic_table = @import("dynamic_table.zig");
const static_table = @import("static_table.zig");
const DynamicTable = dynamic_table.DynamicTable;
const TableStorage = @import("../TableStorage.zig");

pub const Error = error{
    /// The input ended inside an instruction.
    Truncated,
    /// The output buffer cannot hold the decoded strings.
    NoSpace,
    /// A numeric field does not fit 62 bits.
    InvalidLength,
    /// A Huffman string is not a valid code.
    InvalidHuffman,
};

pub const NameRef = struct {
    /// True for a static-table index, false for a dynamic-relative index.
    is_static: bool,
    index: u62,
    value: []const u8,
};

pub const Literal = struct {
    name: []const u8,
    value: []const u8,
};

pub const Instruction = union(enum) {
    set_capacity: u62,
    insert_name_ref: NameRef,
    insert_literal: Literal,
    /// A dynamic-relative index, resolved against the insertion point.
    duplicate: u62,
};

/// Parse one instruction, decoding its strings into `out`.
pub fn parse(cursor: *Cursor, out: []u8) Error!Instruction {
    const first = cursor.peek() orelse return error.Truncated;

    if (first & 0x80 != 0) {
        const is_static = first & 0x40 != 0;
        const index = try decodeIndex(cursor, 6);
        const value = try string.decode(cursor, 8, out);
        return .{ .insert_name_ref = .{
            .is_static = is_static,
            .index = index,
            .value = value,
        } };
    }

    if (first & 0x40 != 0) {
        const name = try string.decode(cursor, 6, out);
        const value = try string.decode(cursor, 8, out[name.len..]);
        return .{ .insert_literal = .{ .name = name, .value = value } };
    }

    if (first & 0x20 != 0) {
        return .{ .set_capacity = try decodeIndex(cursor, 5) };
    }

    return .{ .duplicate = try decodeIndex(cursor, 5) };
}

/// The bytes `write` needs for one instruction.
pub fn encodedLen(instruction: Instruction) usize {
    return switch (instruction) {
        .set_capacity => |capacity| prefix_int.encodedLenWide(capacity, 5),
        .insert_name_ref => |ref| prefix_int.encodedLenWide(ref.index, 6) +
            string.encodedLen(ref.value, 8),
        .insert_literal => |literal| string.encodedLen(literal.name, 6) +
            string.encodedLen(literal.value, 8),
        .duplicate => |index| prefix_int.encodedLenWide(index, 5),
    };
}

/// Write one instruction. A short buffer is `error.NoSpace` and writes nothing.
pub fn write(buf: []u8, instruction: Instruction) Error![]u8 {
    if (buf.len < encodedLen(instruction)) return error.NoSpace;

    return switch (instruction) {
        .set_capacity => |capacity| blk: {
            const written = try prefix_int.encodeWide(buf, capacity, 5);
            written[0] |= 0x20;
            break :blk written;
        },
        .insert_name_ref => |ref| blk: {
            var written = try prefix_int.encodeWide(buf, ref.index, 6);
            written[0] |= 0x80;
            if (ref.is_static) written[0] |= 0x40;
            const value = try string.write(buf[written.len..], ref.value, 8);
            break :blk buf[0 .. written.len + value.len];
        },
        .insert_literal => |literal| blk: {
            const name = try string.write(buf, literal.name, 6);
            name[0] |= 0x40;
            const value = try string.write(buf[name.len..], literal.value, 8);
            break :blk buf[0 .. name.len + value.len];
        },
        .duplicate => |index| try prefix_int.encodeWide(buf, index, 5),
    };
}

pub const ApplyError = error{
    /// A name or duplicate does not fit the caller's scratch buffer.
    NoSpace,
    /// A static or dynamic reference names an entry that is not there.
    InvalidIndex,
} || dynamic_table.Error;

/// Apply one instruction to the decoder's dynamic table.
///
/// A dynamic-relative index is resolved against the insertion point, which is
/// the current insert count. The referenced name or duplicate is copied into
/// `scratch` before the insert, because the insert can evict the entry it came
/// from (RFC 9204 §3.2.2).
pub fn apply(instruction: Instruction, table: *DynamicTable, scratch: []u8) ApplyError!void {
    switch (instruction) {
        .set_capacity => |capacity| {
            const value = std.math.cast(usize, capacity) orelse return error.CapacityTooLarge;
            try table.setCapacity(value);
        },
        .insert_name_ref => |ref| {
            const entry = if (ref.is_static)
                static_table.get(ref.index) orelse return error.InvalidIndex
            else
                table.getRelative(ref.index, table.insert_count) orelse
                    return error.InvalidIndex;

            if (entry.name.len > scratch.len) return error.NoSpace;
            @memcpy(scratch[0..entry.name.len], entry.name);
            try table.insert(scratch[0..entry.name.len], ref.value);
        },
        .insert_literal => |literal| try table.insert(literal.name, literal.value),
        .duplicate => |index| {
            const entry = table.getRelative(index, table.insert_count) orelse
                return error.InvalidIndex;
            const total = entry.name.len + entry.value.len;
            if (total > scratch.len) return error.NoSpace;

            @memcpy(scratch[0..entry.name.len], entry.name);
            @memcpy(scratch[entry.name.len..][0..entry.value.len], entry.value);
            try table.insert(
                scratch[0..entry.name.len],
                scratch[entry.name.len..][0..entry.value.len],
            );
        },
    }
}

fn decodeIndex(cursor: *Cursor, bits: u4) Error!u62 {
    return prefix_int.decodeWide(cursor, bits) catch |err| switch (err) {
        error.Truncated => error.Truncated,
        error.TooLarge => error.InvalidLength,
    };
}

test "RFC 9204 Appendix B.2, the encoder stream parses" {
    const bytes = [_]u8{
        0x3f, 0xbd, 0x01, // Set Dynamic Table Capacity = 220
        0xc0, 0x0f, 'w',
        'w',  'w',  '.',
        'e',  'x',  'a',
        'm',  'p',  'l', 'e', '.', 'c', 'o', 'm', // :authority=www.example.com
        0xc1, 0x0c, '/', 's', 'a', 'm', 'p', 'l',
        'e',
        '/', 'p', 'a', 't', 'h', // :path=/sample/path
    };
    var cursor: Cursor = .init(&bytes);
    var out: [64]u8 = undefined;

    try testing.expectEqual(@as(u62, 220), (try parse(&cursor, &out)).set_capacity);

    const authority = (try parse(&cursor, &out)).insert_name_ref;
    try testing.expect(authority.is_static);
    try testing.expectEqual(@as(u62, 0), authority.index);
    try testing.expectEqualStrings("www.example.com", authority.value);

    const path = (try parse(&cursor, &out)).insert_name_ref;
    try testing.expect(path.is_static);
    try testing.expectEqual(@as(u62, 1), path.index);
    try testing.expectEqualStrings("/sample/path", path.value);

    try testing.expect(cursor.atEnd());
}

test "RFC 9204 Appendix B.3, a literal name and value parse" {
    const bytes = [_]u8{
        0x4a, 'c',  'u', 's', 't', 'o', 'm', '-', 'k', 'e',
        'y',  0x0c, 'c', 'u', 's', 't', 'o', 'm', '-', 'v',
        'a',  'l',  'u', 'e',
    };
    var cursor: Cursor = .init(&bytes);
    var out: [64]u8 = undefined;

    const literal = (try parse(&cursor, &out)).insert_literal;
    try testing.expectEqualStrings("custom-key", literal.name);
    try testing.expectEqualStrings("custom-value", literal.value);
    try testing.expect(cursor.atEnd());
}

test "RFC 9204 Appendix B.4, the duplicate instruction parses" {
    const bytes = [_]u8{0x02};
    var cursor: Cursor = .init(&bytes);
    var out: [8]u8 = undefined;
    try testing.expectEqual(@as(u62, 2), (try parse(&cursor, &out)).duplicate);
    try testing.expect(cursor.atEnd());
}

test "every instruction round-trips through the writer" {
    const cases = [_]Instruction{
        .{ .set_capacity = 220 },
        .{ .insert_name_ref = .{ .is_static = true, .index = 0, .value = "www.example.com" } },
        .{ .insert_name_ref = .{ .is_static = false, .index = 3, .value = "v" } },
        .{ .insert_literal = .{ .name = "custom-key", .value = "custom-value" } },
        .{ .insert_literal = .{ .name = "a", .value = "" } },
        .{ .duplicate = 2 },
    };

    var buf: [128]u8 = undefined;
    for (cases) |case| {
        const written = try write(&buf, case);
        try testing.expectEqual(encodedLen(case), written.len);

        var cursor: Cursor = .init(written);
        var out: [128]u8 = undefined;
        const decoded = try parse(&cursor, &out);
        try testing.expect(cursor.atEnd());

        switch (case) {
            .set_capacity => |capacity| {
                try testing.expectEqual(capacity, decoded.set_capacity);
            },
            .insert_name_ref => |ref| {
                try testing.expectEqual(ref.is_static, decoded.insert_name_ref.is_static);
                try testing.expectEqual(ref.index, decoded.insert_name_ref.index);
                try testing.expectEqualStrings(ref.value, decoded.insert_name_ref.value);
            },
            .insert_literal => |literal| {
                try testing.expectEqualStrings(literal.name, decoded.insert_literal.name);
                try testing.expectEqualStrings(literal.value, decoded.insert_literal.value);
            },
            .duplicate => |index| try testing.expectEqual(index, decoded.duplicate),
        }
    }
}

test "a truncated instruction is Truncated and the caller can restore the cursor" {
    const bytes = [_]u8{0xc0}; // an index, then nothing for the value
    var cursor: Cursor = .init(&bytes);
    const before = cursor;
    var out: [8]u8 = undefined;
    try testing.expectError(error.Truncated, parse(&cursor, &out));
    cursor = before;
    try testing.expectEqual(@as(u32, 0), cursor.pos);
}

test "a string larger than the output is NoSpace" {
    const bytes = [_]u8{ 0xc0, 0x05, 'a', 'b', 'c', 'd', 'e' };
    var cursor: Cursor = .init(&bytes);
    var out: [4]u8 = undefined;
    try testing.expectError(error.NoSpace, parse(&cursor, &out));
}

test "a short destination is NoSpace and writes nothing" {
    var buf: [1]u8 = undefined;
    buf = .{0xaa};
    try testing.expectError(error.NoSpace, write(&buf, .{
        .insert_literal = .{ .name = "custom-key", .value = "custom-value" },
    }));
    try testing.expectEqual(@as(u8, 0xaa), buf[0]);
}

test "fuzz the encoder stream" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var bytes: [64]u8 = undefined;
            const input = bytes[0..smith.slice(&bytes)];

            var cursor: Cursor = .init(input);
            var out: [256]u8 = undefined;
            _ = parse(&cursor, &out) catch |err| {
                try testing.expect(err == error.Truncated or
                    err == error.NoSpace or
                    err == error.InvalidLength or
                    err == error.InvalidHuffman);
                return;
            };
            try testing.expect(cursor.pos <= input.len);
        }
    }.run, .{
        .corpus = &.{
            "",
            "\x3f\xbd\x01",
            "\xc0\x0fwww.example.com",
            "\x4acustom-key\x0ccustom-value",
            "\x02",
        },
    });
}

test "applying the Appendix B.2 instructions fills the table" {
    const bytes = [_]u8{
        0x3f, 0xbd, 0x01,
        0xc0, 0x0f, 'w',
        'w',  'w',  '.',
        'e',  'x',  'a',
        'm',  'p',  'l',
        'e',  '.',  'c',
        'o',  'm',  0xc1,
        0x0c, '/',  's',
        'a',  'm',  'p',
        'l',  'e',  '/',
        'p',  'a',  't',
        'h',
    };
    var cursor: Cursor = .init(&bytes);
    var out: [64]u8 = undefined;
    var memory: TableStorage.Buffer(220) = undefined;
    var table = DynamicTable.init(try TableStorage.initBuffer(&memory, 220));
    var scratch: [64]u8 = undefined;

    try apply(try parse(&cursor, &out), &table, &scratch);
    try apply(try parse(&cursor, &out), &table, &scratch);
    try apply(try parse(&cursor, &out), &table, &scratch);
    try testing.expect(cursor.atEnd());

    try testing.expectEqual(@as(u64, 2), table.insert_count);
    try testing.expectEqualStrings(":authority", table.get(0).?.name);
    try testing.expectEqualStrings("www.example.com", table.get(0).?.value);
    try testing.expectEqualStrings(":path", table.get(1).?.name);
    try testing.expectEqualStrings("/sample/path", table.get(1).?.value);
}

test "a name reference survives the eviction its insert causes" {
    var memory: TableStorage.Buffer(70) = undefined;
    var table = DynamicTable.init(try TableStorage.initBuffer(&memory, 70));
    try table.setCapacity(70);
    try table.insert("name", ""); // absolute 0, 36 bytes

    var value: [30]u8 = undefined;
    @memset(&value, 'v');
    var scratch: [32]u8 = undefined;
    try apply(.{ .insert_name_ref = .{
        .is_static = false,
        .index = 0,
        .value = &value,
    } }, &table, &scratch);

    try testing.expectEqual(@as(u64, 2), table.insert_count);
    try testing.expectEqual(@as(u64, 1), table.dropped());
    try testing.expectEqualStrings("name", table.get(1).?.name);
    try testing.expectEqualStrings(&value, table.get(1).?.value);
}

test "a duplicate copies before it reinserts" {
    var memory: TableStorage.Buffer(220) = undefined;
    var table = DynamicTable.init(try TableStorage.initBuffer(&memory, 220));
    try table.setCapacity(220);
    try table.insert("a", "b");

    var scratch: [8]u8 = undefined;
    try apply(.{ .duplicate = 0 }, &table, &scratch);
    try testing.expectEqual(@as(u64, 2), table.insert_count);
    try testing.expectEqualStrings("a", table.get(1).?.name);
    try testing.expectEqualStrings("b", table.get(1).?.value);
}

test "a missing reference and a short scratch are errors" {
    var memory: TableStorage.Buffer(220) = undefined;
    var table = DynamicTable.init(try TableStorage.initBuffer(&memory, 220));
    try table.setCapacity(220);
    var scratch: [1]u8 = undefined;

    try testing.expectError(error.InvalidIndex, apply(.{
        .insert_name_ref = .{ .is_static = false, .index = 0, .value = "" },
    }, &table, &scratch));
    try testing.expectError(error.InvalidIndex, apply(.{
        .insert_name_ref = .{ .is_static = true, .index = 99, .value = "" },
    }, &table, &scratch));

    try table.insert("long-name", "");
    try testing.expectError(error.NoSpace, apply(.{
        .insert_name_ref = .{ .is_static = false, .index = 0, .value = "" },
    }, &table, &scratch));
}

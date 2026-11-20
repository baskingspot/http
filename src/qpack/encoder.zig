//! The QPACK static-only encoder (RFC 9204 §4.5).
//!
//! It writes a field section that uses the 99-entry static table and no
//! dynamic table. The Required Insert Count and Base are both zero, so the
//! section never blocks and needs no encoder stream. Every field with an exact
//! static match is an indexed field line; a field whose name is static gets a
//! literal line with a name reference; anything else gets a literal name.
//!
//! The `N` bit is per field. A field with `N` set must use a literal
//! representation (§4.5.4), so an exact static match is not used for it.
//! `encode` leaves `N` clear; `encodeFlags` takes one flag per field.
//!
//! The dynamic encoder is a later phase. Until then this encoder is complete:
//! its output is a valid field section, just larger than a dynamic one.

const std = @import("std");
const testing = std.testing;

const Header = @import("../header.zig").Header;
const Headers = @import("../header.zig").Headers;
const prefix_int = @import("../prefix_int.zig");
const static_table = @import("static_table.zig");
const string = @import("string.zig");

pub const Error = error{NoSpace};

pub const Encoder = struct {
    pub fn init() Encoder {
        return .{};
    }

    pub fn encodedLen(self: *const Encoder, headers: Headers) usize {
        return self.encodedLenFlags(headers, &.{});
    }

    pub fn encodedLenFlags(
        self: *const Encoder,
        headers: Headers,
        never_indexed: []const bool,
    ) usize {
        _ = self;
        // Required Insert Count and Base, both zero.
        var total: usize = 2;
        for (headers.items, 0..) |header, index| {
            const never = index < never_indexed.len and never_indexed[index];
            total += headerLen(choose(header, never), header);
        }
        return total;
    }

    pub fn encode(self: *Encoder, buf: []u8, headers: Headers) Error![]u8 {
        return self.encodeFlags(buf, headers, &.{});
    }

    /// Encode one field section. A short buffer is `error.NoSpace` and writes
    /// nothing. `never_indexed` may be shorter than the field list; a missing
    /// entry means false.
    pub fn encodeFlags(
        self: *Encoder,
        buf: []u8,
        headers: Headers,
        never_indexed: []const bool,
    ) Error![]u8 {
        if (buf.len < self.encodedLenFlags(headers, never_indexed)) return error.NoSpace;

        buf[0] = 0; // Required Insert Count = 0.
        buf[1] = 0; // Base = 0.
        var pos: usize = 2;
        for (headers.items, 0..) |header, index| {
            const never = index < never_indexed.len and never_indexed[index];
            const written = try encodeHeader(buf[pos..], header, never);
            pos += written.len;
        }
        return buf[0..pos];
    }
};

const Representation = union(enum) {
    indexed_static: u62,
    literal_static: u62,
    literal_name,
};

fn choose(header: Header, never_indexed: bool) Representation {
    if (!never_indexed) {
        if (static_table.find(header.name, header.value)) |index| {
            return .{ .indexed_static = @intCast(index) };
        }
    }
    if (static_table.findName(header.name)) |index| {
        return .{ .literal_static = @intCast(index) };
    }
    return .literal_name;
}

fn headerLen(representation: Representation, header: Header) usize {
    return switch (representation) {
        .indexed_static => |index| prefix_int.encodedLenWide(index, 6),
        .literal_static => |index| prefix_int.encodedLenWide(index, 4) +
            string.encodedLen(header.value, 8),
        .literal_name => string.encodedLen(header.name, 4) + string.encodedLen(header.value, 8),
    };
}

fn encodeHeader(buf: []u8, header: Header, never_indexed: bool) Error![]u8 {
    switch (choose(header, never_indexed)) {
        .indexed_static => |index| {
            const written = try prefix_int.encodeWide(buf, index, 6);
            written[0] |= 0xc0;
            return written;
        },
        .literal_static => |index| {
            const index_bytes = try prefix_int.encodeWide(buf, index, 4);
            index_bytes[0] |= 0x40 | 0x10;
            if (never_indexed) index_bytes[0] |= 0x20;
            const value = try string.write(buf[index_bytes.len..], header.value, 8);
            return buf[0 .. index_bytes.len + value.len];
        },
        .literal_name => {
            const name = try string.write(buf, header.name, 4);
            name[0] |= 0x20;
            if (never_indexed) name[0] |= 0x10;
            const value = try string.write(buf[name.len..], header.value, 8);
            return buf[0 .. name.len + value.len];
        },
    }
}

const decoder_mod = @import("decoder.zig");
const TableStorage = @import("../TableStorage.zig");

fn roundTrip(headers: Headers) !void {
    var encoder = Encoder.init();
    var buf: [1024]u8 = undefined;
    const block = try encoder.encode(&buf, headers);
    try testing.expectEqual(encoder.encodedLen(headers), block.len);

    var memory: TableStorage.Buffer(256) = undefined;
    var decoder = decoder_mod.Decoder.init(try TableStorage.initBuffer(&memory, 256));
    var out: [32]Header = undefined;
    var bytes: [1024]u8 = undefined;
    const fields = (try decoder.decode(block, &out, &bytes)).fields.headers;

    try testing.expectEqual(headers.items.len, fields.items.len);
    for (headers.items, fields.items) |want, got| {
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqualStrings(want.value, got.value);
    }
}

test "RFC 9204 §4.5.2, an exact static pair is an indexed field line" {
    var encoder = Encoder.init();
    var buf: [8]u8 = undefined;
    const block = try encoder.encode(&buf, .{ .items = &.{
        .{ .name = ":method", .value = "GET" },
    } });

    try testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0xd1 }, block);
    try roundTrip(.{ .items = &.{.{ .name = ":method", .value = "GET" }} });
}

test "a static name and a literal value use a name reference" {
    var encoder = Encoder.init();
    var buf: [64]u8 = undefined;
    const block = try encoder.encode(&buf, .{ .items = &.{
        .{ .name = ":path", .value = "/index.html" },
    } });

    try testing.expectEqual(@as(u8, 0x51), block[2]);
    try roundTrip(.{ .items = &.{.{ .name = ":path", .value = "/index.html" }} });
}

test "a name outside the static table is a literal name" {
    var encoder = Encoder.init();
    var buf: [64]u8 = undefined;
    const block = try encoder.encode(&buf, .{ .items = &.{
        .{ .name = "x-custom", .value = "value" },
    } });

    try testing.expectEqual(@as(u8, 0x20), block[2] & 0xe0); // the 001 tag
    try roundTrip(.{ .items = &.{.{ .name = "x-custom", .value = "value" }} });
}

test "the N bit forces a literal and reaches the decoder" {
    var encoder = Encoder.init();
    var buf: [64]u8 = undefined;

    // An exact static pair cannot use the indexed form when N is set.
    const block = try encoder.encodeFlags(&buf, .{ .items = &.{
        .{ .name = ":method", .value = "GET" },
    } }, &.{true});
    try testing.expectEqual(@as(u8, 0x7f), block[2]); // 01 N=1 T=1, index 17 continues

    var memory: TableStorage.Buffer(256) = undefined;
    var decoder = decoder_mod.Decoder.init(try TableStorage.initBuffer(&memory, 256));
    var out: [4]Header = undefined;
    var bytes: [64]u8 = undefined;
    var flags: [4]bool = undefined;
    const fields = (try decoder.decodeFlags(block, &out, &bytes, &flags)).fields.headers;

    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings(":method", fields.items[0].name);
    try testing.expectEqualStrings("GET", fields.items[0].value);
    try testing.expect(flags[0]);
}

test "an empty field section is the two-byte prefix" {
    var encoder = Encoder.init();
    var buf: [2]u8 = undefined;
    const block = try encoder.encode(&buf, .{ .items = &.{} });
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x00 }, block);
    try roundTrip(.{ .items = &.{} });
}

test "a mixed request round-trips" {
    try roundTrip(.{ .items = &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/api/v1/things?q=1" },
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "content-length", .value = "42" },
        .{ .name = "accept", .value = "*/*" },
        .{ .name = "user-agent", .value = "baskingspot-http/0.8" },
        .{ .name = "x-request-id", .value = "01234567-89ab-cdef-0123-456789abcdef" },
    } });
}

test "a long static index uses the four-bit prefix continuation" {
    var encoder = Encoder.init();
    var buf: [64]u8 = undefined;
    const block = try encoder.encode(&buf, .{ .items = &.{
        .{ .name = "authorization", .value = "Bearer secret" },
    } });

    try testing.expectEqual(@as(u8, 0x5f), block[2]);
    try roundTrip(.{ .items = &.{.{ .name = "authorization", .value = "Bearer secret" }} });
}

test "a short buffer is NoSpace and writes nothing" {
    var encoder = Encoder.init();
    var buf: [4]u8 = undefined;
    buf = .{ 0xaa, 0xaa, 0xaa, 0xaa };
    try testing.expectError(error.NoSpace, encoder.encode(&buf, .{ .items = &.{
        .{ .name = "x-custom", .value = "value" },
    } }));
    try testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa, 0xaa, 0xaa }, &buf);
}

test "fuzz field values through the encoder and decoder" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var value_buf: [128]u8 = undefined;
            const value = value_buf[0..smith.slice(&value_buf)];
            const headers: Headers = .{ .items = &.{
                .{ .name = "x-fuzz", .value = value },
            } };

            var encoder = Encoder.init();
            var block_buf: [1024]u8 = undefined;
            const block = try encoder.encode(&block_buf, headers);

            var memory: TableStorage.Buffer(256) = undefined;
            var decoder = decoder_mod.Decoder.init(try TableStorage.initBuffer(&memory, 256));
            var out: [4]Header = undefined;
            var bytes: [1024]u8 = undefined;
            const fields = (try decoder.decode(block, &out, &bytes)).fields.headers;
            try testing.expectEqual(@as(usize, 1), fields.items.len);
            try testing.expectEqualStrings(value, fields.items[0].value);
        }
    }.run, .{ .corpus = &.{ "", "a", "application/json", "\xff\x00" } });
}

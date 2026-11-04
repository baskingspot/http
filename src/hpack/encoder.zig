//! HPACK header block encoding (RFC 7541 §3, §5, §6).
//!
//! One instance per connection, per direction. The encoder and the peer's
//! decoder hold the same dynamic table; `setMaxSize` follows the peer's
//! SETTINGS_HEADER_TABLE_SIZE and queues the size update that puts both
//! tables back in step.
//!
//! `encodedLen` is an upper bound: the block is written as if every field had
//! a literal name and a raw value, which is the largest a field can be. If
//! `out` meets that bound, `encode` cannot run out, so the dynamic table is
//! never advanced by a block that was not written.
//!
//! The default policy indexes every field, uses an indexed field when the
//! exact pair is already in a table, and Huffman-codes a string when that is
//! shorter. A caller overrides the first with a `Mode` per field, and can turn
//! off Huffman on the encoder.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const mem = std.mem;
const print = std.debug.print;

const Header = @import("../header.zig").Header;
const huffman = @import("../huffman.zig");
const prefix_int = @import("../prefix_int.zig");
const decoder = @import("decoder.zig");
const dynamic_table = @import("dynamic_table.zig");
const TableStorage = @import("TableStorage.zig");
const Slot = TableStorage.Slot;
const DynamicTable = dynamic_table.DynamicTable;
const static_table = @import("static_table.zig");
const response_mod = @import("../response.zig");
const Response = response_mod.Response;

pub const Error = error{
    /// The destination buffer is smaller than `encodedLen`.
    NoSpace,
};

/// How one field is represented on the wire.
pub const Mode = enum {
    /// Add the field to the dynamic table (§6.2.1). An exact pair that is
    /// already in a table becomes an indexed field instead.
    incremental,
    /// Leave the table alone (§6.2.2).
    without_indexing,
    /// Leave the table alone, and require an intermediary that forwards the
    /// field to use this same representation (§6.2.3).
    never_indexed,
};

pub const Encoder = struct {
    table: DynamicTable,
    /// Huffman-code a string when that is shorter than its raw bytes. On by
    /// default; a caller that values encode speed over block size turns it
    /// off.
    huffman: bool,
    /// The smallest maximum size requested since the last block. A reduction
    /// followed by a growth has to reach the peer as two updates (§4.2).
    pending_min: ?usize,

    pub fn init(storage: TableStorage) Encoder {
        return .{
            .table = .init(storage),
            .huffman = true,
            .pending_min = null,
        };
    }

    /// Change the maximum table size the peer allows. Evicts now, and emits
    /// the update at the start of the next block.
    pub fn setMaxSize(self: *Encoder, new_max: usize) error{TooLarge}!void {
        if (new_max == self.table.max_size) return;
        try self.table.setMaxSize(new_max);
        if (self.pending_min == null or new_max < self.pending_min.?) {
            self.pending_min = new_max;
        }
    }

    /// An upper bound on the block `encode` writes, pending size updates
    /// included. Size `out` with this.
    pub fn encodedLen(self: *const Encoder, headers: []const Header) usize {
        var total: usize = self.pendingLen();

        for (headers) |header| {
            // A literal with a new name, raw bytes: the largest a field can
            // be. An indexed field or a Huffman string is smaller.
            total += 1;
            total += prefix_int.encodedLen(@intCast(header.name.len), 7);
            total += header.name.len;
            total += prefix_int.encodedLen(@intCast(header.value.len), 7);
            total += header.value.len;
        }
        return total;
    }

    /// Encode every field with the default policy: incremental indexing.
    pub fn encode(self: *Encoder, headers: []const Header, out: []u8) Error![]const u8 {
        return self.encodeModes(headers, null, out);
    }

    /// Encode with a mode per field. `modes` is indexed the same way as
    /// `headers`; null means incremental for all.
    pub fn encodeModes(
        self: *Encoder,
        headers: []const Header,
        modes: ?[]const Mode,
        out: []u8,
    ) Error![]const u8 {
        if (modes) |list| assert(list.len == headers.len);
        if (out.len < self.encodedLen(headers)) return error.NoSpace;

        var pos: usize = 0;
        self.writePending(out, &pos);

        for (headers, 0..) |header, index| {
            const mode: Mode = if (modes) |list| list[index] else .incremental;
            self.writeField(out, &pos, header, mode);
        }

        assert(pos <= out.len);
        return out[0..pos];
    }

    /// An upper bound on `encodeResponse` with the default incremental mode.
    pub fn encodedLenResponse(self: *const Encoder, response: Response) usize {
        var total = self.pendingLen();
        total += fieldBound(":status", 3);
        if (response.content_type) |value| {
            total += fieldBound("content-type", value.len);
        }
        if (response.content_length != null) {
            total += fieldBound("content-length", 20);
        }
        for (response.headers) |header| {
            total += fieldBound(header.name, header.value.len);
        }
        return total;
    }

    /// Encode a typed response. The status and content-length text are made
    /// here and live only for the call; the dynamic table copies what it
    /// indexes. The extra headers and content type are borrowed from the
    /// caller.
    pub fn encodeResponse(
        self: *Encoder,
        response: Response,
        out: []u8,
    ) Error![]const u8 {
        if (out.len < self.encodedLenResponse(response)) return error.NoSpace;

        var pos: usize = 0;
        self.writePending(out, &pos);

        const status_text = response.status.text();
        self.writeField(out, &pos, .{
            .name = ":status",
            .value = status_text[0..],
        }, .incremental);

        if (response.content_type) |value| {
            self.writeField(out, &pos, .{
                .name = "content-type",
                .value = value,
            }, .incremental);
        }

        if (response.content_length) |length| {
            var length_buf: [20]u8 = undefined;
            const text = std.fmt.bufPrint(&length_buf, "{d}", .{length}) catch unreachable;
            self.writeField(out, &pos, .{
                .name = "content-length",
                .value = text,
            }, .incremental);
        }

        for (response.headers) |header| {
            self.writeField(out, &pos, header, .incremental);
        }
        return out[0..pos];
    }

    fn pendingLen(self: *const Encoder) usize {
        var total: usize = 0;
        if (self.pending_min) |min| {
            total += prefix_int.encodedLen(@intCast(min), 5);
            if (min != self.table.max_size) {
                total += prefix_int.encodedLen(@intCast(self.table.max_size), 5);
            }
        }
        return total;
    }

    fn writePending(self: *Encoder, out: []u8, pos: *usize) void {
        if (self.pending_min) |min| {
            writeInt(out, pos, @intCast(min), 5, 0x20);
            if (min != self.table.max_size) {
                writeInt(out, pos, @intCast(self.table.max_size), 5, 0x20);
            }
            self.pending_min = null;
        }
    }

    fn fieldBound(name: []const u8, value_len: usize) usize {
        return 1 + prefix_int.encodedLen(@intCast(name.len), 7) + name.len +
            prefix_int.encodedLen(@intCast(value_len), 7) + value_len;
    }

    fn writeField(self: *Encoder, out: []u8, pos: *usize, header: Header, mode: Mode) void {
        if (mode == .incremental) {
            if (self.exactIndex(header)) |index| {
                writeInt(out, pos, index, 7, 0x80);
                return;
            }
        }

        const name_index = self.nameIndex(header.name) orelse 0;
        switch (mode) {
            .incremental => writeInt(out, pos, name_index, 6, 0x40),
            .without_indexing => writeInt(out, pos, name_index, 4, 0x00),
            .never_indexed => writeInt(out, pos, name_index, 4, 0x10),
        }
        if (name_index == 0) self.writeString(out, pos, header.name);
        self.writeString(out, pos, header.value);

        if (mode == .incremental) self.table.insert(header.name, header.value);
    }

    fn writeString(self: *const Encoder, out: []u8, pos: *usize, text: []const u8) void {
        if (self.huffman) {
            const encoded_len = huffman.encodedLen(text);
            if (encoded_len < text.len) {
                writeInt(out, pos, @intCast(encoded_len), 7, 0x80);
                const written = huffman.encode(text, out[pos.*..]) catch unreachable;
                assert(written == encoded_len);
                pos.* += written;
                return;
            }
        }

        writeInt(out, pos, @intCast(text.len), 7, 0x00);
        @memcpy(out[pos.*..][0..text.len], text);
        pos.* += text.len;
    }

    /// The index of the first static or dynamic entry whose name and value
    /// both match. Static wins: its index is never larger.
    fn exactIndex(self: *const Encoder, header: Header) ?u32 {
        if (static_table.find(header)) |index| return index;
        const position = self.table.find(header) orelse return null;
        return static_table.first_dynamic + @as(u32, @intCast(position));
    }

    /// The index of the first static or dynamic entry with this name.
    fn nameIndex(self: *const Encoder, value: []const u8) ?u32 {
        if (static_table.findName(value)) |index| return index;
        const position = self.table.findName(value) orelse return null;
        return static_table.first_dynamic + @as(u32, @intCast(position));
    }
};

/// Write an integer with the representation tag in the high bits. The caller
/// has already checked `encodedLen`.
fn writeInt(out: []u8, pos: *usize, value: u32, bits: u4, tag: u8) void {
    const encoded = prefix_int.encode(out[pos.*..], value, bits) catch unreachable;
    encoded[0] |= tag;
    pos.* += encoded.len;
}

const request_fields = [_]Header{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":authority", .value = "www.example.com" },
};

const request_fields_second = request_fields ++ [_]Header{
    .{ .name = "cache-control", .value = "no-cache" },
};

const request_fields_third = [_]Header{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":authority", .value = "www.example.com" },
    .{ .name = "custom-key", .value = "custom-value" },
};

const response_fields = [_]Header{
    .{ .name = ":status", .value = "302" },
    .{ .name = "cache-control", .value = "private" },
    .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:21 GMT" },
    .{ .name = "location", .value = "https://www.example.com" },
};

const response_fields_second = [_]Header{
    .{ .name = ":status", .value = "307" },
    .{ .name = "cache-control", .value = "private" },
    .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:21 GMT" },
    .{ .name = "location", .value = "https://www.example.com" },
};

const response_fields_third = [_]Header{
    .{ .name = ":status", .value = "200" },
    .{ .name = "cache-control", .value = "private" },
    .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:22 GMT" },
    .{ .name = "location", .value = "https://www.example.com" },
    .{ .name = "content-encoding", .value = "gzip" },
    .{ .name = "set-cookie", .value = "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1" },
};

fn expectWire(
    encoder: *Encoder,
    headers: []const Header,
    modes: ?[]const Mode,
    expected: []const u8,
) !void {
    var out: [1024]u8 = undefined;
    const block = try encoder.encodeModes(headers, modes, &out);
    if (!mem.eql(u8, expected, block)) {
        print("\nexpected {x}\nactual   {x}\n", .{ expected, block });
    }
    try testing.expectEqualSlices(u8, expected, block);
}

test "C.4: the request sequence with Huffman coding (RFC 7541 Appendix C.4)" {
    var table_memory: TableStorage.Buffer(4096) = undefined;
    var encoder = Encoder.init(try .initBuffer(&table_memory, 4096));

    try expectWire(
        &encoder,
        &request_fields,
        null,
        "\x82\x86\x84\x41\x8c\xf1\xe3\xc2\xe5\xf2\x3a\x6b\xa0\xab\x90\xf4\xff",
    );
    try expectWire(
        &encoder,
        &request_fields_second,
        null,
        "\x82\x86\x84\xbe\x58\x86\xa8\xeb\x10\x64\x9c\xbf",
    );
    try expectWire(
        &encoder,
        &request_fields_third,
        null,
        "\x82\x87\x85\xbf\x40\x88\x25\xa8\x49\xe9\x5b\xa9\x7d\x7f" ++
            "\x89\x25\xa8\x49\xe9\x5b\xb8\xe8\xb4\xbf",
    );
}

test "C.5: the response sequence without Huffman (RFC 7541 Appendix C.5)" {
    var table_memory: TableStorage.Buffer(256) = undefined;
    var encoder = Encoder.init(try .initBuffer(&table_memory, 256));
    encoder.huffman = false;

    try expectWire(
        &encoder,
        &response_fields,
        null,
        "\x48\x03302" ++
            "\x58\x07private" ++
            "\x61\x1dMon, 21 Oct 2013 20:13:21 GMT" ++
            "\x6e\x17https://www.example.com",
    );
    try expectWire(
        &encoder,
        &response_fields_second,
        null,
        "\x48\x03307\xc1\xc0\xbf",
    );
    try expectWire(
        &encoder,
        &response_fields_third,
        null,
        "\x88\xc1" ++
            "\x61\x1dMon, 21 Oct 2013 20:13:22 GMT" ++
            "\xc0" ++
            "\x5a\x04gzip" ++
            "\x77\x38foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
    );
}

test "C.6.1: the first response with Huffman coding (RFC 7541 Appendix C.6.1)" {
    // The RFC's example encoder Huffman-codes even when the result ties the
    // raw length; this encoder uses Huffman only when it saves a byte. The
    // first block has no ties, so it matches. C.5 pins the other two.
    var table_memory: TableStorage.Buffer(256) = undefined;
    var encoder = Encoder.init(try .initBuffer(&table_memory, 256));

    try expectWire(
        &encoder,
        &response_fields,
        null,
        "\x48\x82\x64\x02" ++
            "\x58\x85\xae\xc3\x77\x1a\x4b" ++
            "\x61\x96\xd0\x7a\xbe\x94\x10\x54\xd4\x44\xa8\x20\x05\x95\x04\x0b" ++
            "\x81\x66\xe0\x82\xa6\x2d\x1b\xff" ++
            "\x6e\x91\x9d\x29\xad\x17\x18\x63\xc7\x8f\x0b\x97\xc8\xe9\xae\x82\xae\x43\xd3",
    );
}

test "C.2: the three literal representations (RFC 7541 Appendix C.2)" {
    var table_memory: TableStorage.Buffer(1024) = undefined;
    var encoder = Encoder.init(try .initBuffer(&table_memory, 1024));
    encoder.huffman = false;

    const custom = [_]Header{.{ .name = "custom-key", .value = "custom-header" }};
    const incremental = [_]Mode{.incremental};
    try expectWire(
        &encoder,
        &custom,
        &incremental,
        "\x40\x0acustom-key\x0dcustom-header",
    );
    try testing.expectEqual(@as(usize, 55), encoder.table.size);

    const path = [_]Header{.{ .name = ":path", .value = "/sample/path" }};
    const without = [_]Mode{.without_indexing};
    try expectWire(
        &encoder,
        &path,
        &without,
        "\x04\x0c/sample/path",
    );

    var fresh_memory: TableStorage.Buffer(1024) = undefined;
    var fresh = Encoder.init(try .initBuffer(&fresh_memory, 1024));
    fresh.huffman = false;
    const secret = [_]Header{.{ .name = "password", .value = "secret" }};
    const never = [_]Mode{.never_indexed};
    try expectWire(
        &fresh,
        &secret,
        &never,
        "\x10\x08password\x06secret",
    );
    try testing.expect(fresh.table.isEmpty());
}

test "round-trip through the decoder, including a reused table" {
    var encode_memory: TableStorage.Buffer(4096) = undefined;
    var encoder = Encoder.init(try .initBuffer(&encode_memory, 4096));

    var decode_memory: TableStorage.Buffer(4096) = undefined;
    var dec = decoder.Decoder.init(try .initBuffer(&decode_memory, 4096));

    var out: [16]Header = undefined;
    var out_bytes: [1024]u8 = undefined;
    var flags: [16]bool = undefined;
    var block_buf: [1024]u8 = undefined;

    inline for (.{ &request_fields, &request_fields_second, &request_fields_third }) |fields| {
        const block = try encoder.encode(fields, &block_buf);
        const headers = try dec.decodeFlags(block, &out, &out_bytes, &flags);
        try testing.expectEqual(fields.len, headers.items.len);
        for (fields, headers.items) |want, got| {
            try testing.expectEqualStrings(want.name, got.name);
            try testing.expectEqualStrings(want.value, got.value);
        }
    }

    try testing.expectEqual(@as(usize, 164), encoder.table.size);
    try testing.expectEqual(@as(usize, 164), dec.table.size);
}

test "never indexed survives a round-trip with its flag (RFC 7541 §6.2.3)" {
    var encode_memory: TableStorage.Buffer(256) = undefined;
    var encoder = Encoder.init(try .initBuffer(&encode_memory, 256));

    var decode_memory: TableStorage.Buffer(256) = undefined;
    var dec = decoder.Decoder.init(try .initBuffer(&decode_memory, 256));

    const fields = [_]Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = "authorization", .value = "Bearer secret" },
    };
    const modes = [_]Mode{ .incremental, .never_indexed };

    var block_buf: [256]u8 = undefined;
    const block = try encoder.encodeModes(&fields, &modes, &block_buf);

    var out: [4]Header = undefined;
    var out_bytes: [256]u8 = undefined;
    var flags: [4]bool = undefined;
    const headers = try dec.decodeFlags(block, &out, &out_bytes, &flags);

    try testing.expectEqual(@as(usize, 2), headers.items.len);
    try testing.expect(!flags[0]);
    try testing.expect(flags[1]);
    try testing.expectEqualStrings("authorization", headers.items[1].name);
    try testing.expect(dec.table.isEmpty());
}

test "a size update reaches the decoder, minimum first (RFC 7541 §4.2)" {
    var encode_memory: TableStorage.Buffer(4096) = undefined;
    var encoder = Encoder.init(try .initBuffer(&encode_memory, 4096));

    var decode_memory: TableStorage.Buffer(4096) = undefined;
    var dec = decoder.Decoder.init(try .initBuffer(&decode_memory, 4096));

    try encoder.setMaxSize(256);
    try encoder.setMaxSize(4096);

    var block_buf: [256]u8 = undefined;
    const block = try encoder.encode(&.{.{ .name = ":method", .value = "GET" }}, &block_buf);

    // 256 with a 5-bit prefix: 31, then 225 = 0xe1 0x01.
    // 4096: 31, then 4065 = 0xe1 0x9f.
    try testing.expectEqualSlices(
        u8,
        "\x3f\xe1\x01\x3f\xe1\x1f\x82",
        block,
    );

    var out: [4]Header = undefined;
    var out_bytes: [256]u8 = undefined;
    const headers = try dec.decode(block, &out, &out_bytes);
    try testing.expectEqual(@as(usize, 1), headers.items.len);
    try testing.expectEqualStrings(":method", out[0].name);
    try testing.expectEqual(@as(usize, 4096), dec.table.max_size);
}

test "a size update is emitted even with no fields" {
    var encode_memory: TableStorage.Buffer(4096) = undefined;
    var encoder = Encoder.init(try .initBuffer(&encode_memory, 4096));
    try encoder.setMaxSize(0);

    var block_buf: [16]u8 = undefined;
    const block = try encoder.encode(&.{}, &block_buf);
    try testing.expectEqualSlices(u8, "\x20", block);

    var decode_memory: TableStorage.Buffer(4096) = undefined;
    var dec = decoder.Decoder.init(try .initBuffer(&decode_memory, 4096));
    var out: [4]Header = undefined;
    var out_bytes: [16]u8 = undefined;
    try testing.expectEqual(0, (try dec.decode(block, &out, &out_bytes)).items.len);
    try testing.expectEqual(0, dec.table.max_size);
}

test "setMaxSize to zero clears the table and tells the peer" {
    var encode_memory: TableStorage.Buffer(256) = undefined;
    var encoder = Encoder.init(try .initBuffer(&encode_memory, 256));

    var discard: [128]u8 = undefined;
    _ = try encoder.encode(&.{.{ .name = "x-a", .value = "1" }}, &discard);
    try testing.expectEqual(@as(usize, 1), encoder.table.count);

    try encoder.setMaxSize(0);
    try testing.expect(encoder.table.isEmpty());

    var block_buf: [128]u8 = undefined;
    const block = try encoder.encode(&.{.{ .name = "x-b", .value = "2" }}, &block_buf);
    try testing.expectEqual(@as(u8, 0x20), block[0]);

    var decode_memory: TableStorage.Buffer(256) = undefined;
    var dec = decoder.Decoder.init(try .initBuffer(&decode_memory, 256));
    var out: [4]Header = undefined;
    var out_bytes: [128]u8 = undefined;
    const headers = try dec.decode(block, &out, &out_bytes);
    try testing.expectEqual(@as(usize, 1), headers.items.len);
    try testing.expectEqual(@as(usize, 0), dec.table.max_size);
    try testing.expect(dec.table.isEmpty());
}

test "NoSpace does not touch the dynamic table" {
    var table_memory: TableStorage.Buffer(256) = undefined;
    var encoder = Encoder.init(try .initBuffer(&table_memory, 256));

    var tiny: [1]u8 = undefined;
    try testing.expectError(
        error.NoSpace,
        encoder.encode(&.{.{ .name = ":authority", .value = "example.com" }}, &tiny),
    );
    try testing.expect(encoder.table.isEmpty());
}

test "a value that Huffman would expand stays raw" {
    var table_memory: TableStorage.Buffer(256) = undefined;
    var encoder = Encoder.init(try .initBuffer(&table_memory, 256));

    const fields = [_]Header{.{ .name = "x", .value = "\x00\x01\x02" }};
    var block_buf: [128]u8 = undefined;
    const block = try encoder.encode(&fields, &block_buf);

    // 0x40, raw name (0x01 'x'), raw value (0x03 and three bytes).
    try testing.expectEqualSlices(u8, "\x40\x01x\x03\x00\x01\x02", block);
}

test "turning Huffman off writes the raw bytes" {
    var table_memory: TableStorage.Buffer(256) = undefined;
    var encoder = Encoder.init(try .initBuffer(&table_memory, 256));
    encoder.huffman = false;

    const fields = [_]Header{.{ .name = ":authority", .value = "www.example.com" }};
    var block_buf: [128]u8 = undefined;
    const block = try encoder.encode(&fields, &block_buf);

    try testing.expectEqualSlices(u8, "\x41\x0fwww.example.com", block);
}

test "fuzz encode: the bound holds and the decoder recovers the fields" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var encode_memory: TableStorage.Buffer(512) = undefined;
            var encoder = Encoder.init(try .initBuffer(&encode_memory, 512));

            var decode_memory: TableStorage.Buffer(512) = undefined;
            var dec = decoder.Decoder.init(try .initBuffer(&decode_memory, 512));

            const max_size: u32 = smith.valueRangeAtMost(u32, 0, 512);
            try encoder.setMaxSize(max_size);

            var name_buf: [8][16]u8 = undefined;
            var value_buf: [8][16]u8 = undefined;
            var headers: [8]Header = undefined;
            var modes: [8]Mode = undefined;
            const count = smith.valueRangeAtMost(u8, 0, 8);
            for (0..count) |i| {
                headers[i] = .{
                    .name = name_buf[i][0..smith.slice(&name_buf[i])],
                    .value = value_buf[i][0..smith.slice(&value_buf[i])],
                };
                modes[i] = switch (smith.valueRangeAtMost(u8, 0, 2)) {
                    0 => .incremental,
                    1 => .without_indexing,
                    else => .never_indexed,
                };
            }

            var block_buf: [2048]u8 = undefined;
            const bound = encoder.encodedLen(headers[0..count]);
            const block = try encoder.encodeModes(headers[0..count], modes[0..count], &block_buf);
            try testing.expect(block.len <= bound);

            var out: [8]Header = undefined;
            var out_bytes: [2048]u8 = undefined;
            const decoded = try dec.decode(block, &out, &out_bytes);
            try testing.expectEqual(@as(usize, count), decoded.items.len);
            for (headers[0..count], decoded.items) |want, got| {
                try testing.expectEqualStrings(want.name, got.name);
                try testing.expectEqualStrings(want.value, got.value);
            }
        }
    }.run, .{ .corpus = &.{
        "",
        "GET",
        "custom-key",
    } });
}

test "encodedLen is an upper bound" {
    var table_memory: TableStorage.Buffer(4096) = undefined;
    var encoder = Encoder.init(try .initBuffer(&table_memory, 4096));

    var block_buf: [1024]u8 = undefined;
    inline for (.{ &request_fields, &response_fields }) |fields| {
        const block = try encoder.encode(fields, &block_buf);
        try testing.expect(encoder.encodedLen(fields) >= block.len);
    }

    try encoder.setMaxSize(256);
    const bound = encoder.encodedLen(&response_fields);
    const block = try encoder.encode(&response_fields, &block_buf);
    try testing.expect(bound >= block.len);
}

test "encodeResponse writes typed status, content type, and length" {
    var encoder_memory: TableStorage.Buffer(4096) = undefined;
    var encoder = Encoder.init(try .initBuffer(&encoder_memory, 4096));
    var decoder_memory: TableStorage.Buffer(4096) = undefined;
    var dec = decoder.Decoder.init(try .initBuffer(&decoder_memory, 4096));

    const response: Response = .{
        .status = .ok,
        .content_type = "text/plain",
        .content_length = 5,
        .headers = &.{.{ .name = "x-check", .value = "done" }},
    };
    var block_buf: [256]u8 = undefined;
    const block = try encoder.encodeResponse(response, &block_buf);

    var fields_buf: [8]Header = undefined;
    var bytes_buf: [256]u8 = undefined;
    const fields = try dec.decode(block, &fields_buf, &bytes_buf);
    try testing.expectEqual(@as(usize, 4), fields.items.len);
    try testing.expectEqualStrings(":status", fields.items[0].name);
    try testing.expectEqualStrings("200", fields.items[0].value);
    try testing.expectEqualStrings("content-type", fields.items[1].name);
    try testing.expectEqualStrings("text/plain", fields.items[1].value);
    try testing.expectEqualStrings("content-length", fields.items[2].name);
    try testing.expectEqualStrings("5", fields.items[2].value);
    try testing.expectEqualStrings("x-check", fields.items[3].name);
    try testing.expectEqualStrings("done", fields.items[3].value);
}

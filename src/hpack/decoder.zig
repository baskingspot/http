//! HPACK header block decoding (RFC 7541 §3, §6).
//!
//! One instance per connection, per direction. A block is complete when it
//! reaches `decode`: HTTP/2 assembles CONTINUATION frames before calling, so
//! there is no partial-block state here. The dynamic table is the only state
//! that spans blocks.
//!
//! Every field is copied into the caller's `out_bytes`, including indexed
//! fields that point into the static or dynamic table. That costs one copy and
//! buys a single rule: every returned slice lives in `out_bytes` and stays
//! valid until the caller reuses that buffer, whatever the table does next.
//! A decoder that borrowed from the table would hand out a field the next
//! insertion could evict.
//!
//! `decode` returns `error.Truncated` for a block that ends inside a
//! representation, and `error.InvalidIndex`, `error.InvalidInteger`,
//! `error.InvalidHuffman`, `error.TableSizeTooLarge`, or
//! `error.TableSizeUpdateNotFirst` for what RFC 7541 calls a decoding error.
//! An HTTP/2 peer turns any of them into a COMPRESSION_ERROR for the
//! connection. `error.TooManyHeaders` and `error.OutputTooSmall` are local:
//! the caller's arrays were too small, which is not the peer's fault.
//!
//! Any error ends the connection. The block stops where the error is, so the
//! dynamic table can no longer match the peer's, and a later block would
//! decode against the wrong table. That includes the local errors: size `out`,
//! `out_bytes`, and the table so they cannot trip. An application limit on
//! header list size belongs after `decode`, where a stream can be reset and
//! the connection stays in sync.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const Cursor = @import("../Cursor.zig");
const Header = @import("../header.zig").Header;
const Headers = @import("../header.zig").Headers;
const huffman = @import("../huffman.zig");
const prefix_int = @import("../prefix_int.zig");
const dynamic_table = @import("dynamic_table.zig");
const DynamicTable = dynamic_table.DynamicTable;
const static_table = @import("static_table.zig");
/// The first dynamic index. Static indices are 1..61, dynamic start at 62.
pub const first_dynamic = static_table.first_dynamic;
const TableStorage = @import("TableStorage.zig");
const Slot = TableStorage.Slot;

pub const Error = error{
    /// The block ends inside a representation or a string.
    Truncated,
    /// An index of 0, or past the end of the static and dynamic tables.
    InvalidIndex,
    /// A prefix integer that does not fit 32 bits.
    InvalidInteger,
    /// A Huffman string that is not a code, holds EOS, or has bad padding.
    InvalidHuffman,
    /// A dynamic table size update above the storage's capacity.
    TableSizeTooLarge,
    /// A dynamic table size update after a field representation (RFC 7541 §4.2).
    TableSizeUpdateNotFirst,
    /// The caller's field array is full.
    TooManyHeaders,
    /// The caller's output buffer is full.
    OutputTooSmall,
};

pub const Decoder = struct {
    table: DynamicTable,

    /// The storage is the SETTINGS_HEADER_TABLE_SIZE this decoder advertises,
    /// and so the largest size a peer may ask for. `TableStorage.init` sizes it
    /// from that value.
    pub fn init(storage: TableStorage) Decoder {
        return .{ .table = .init(storage) };
    }

    /// Decode one complete header block into `out`, copying the bytes into
    /// `out_bytes`. The returned `Headers` borrows `out`.
    pub fn decode(self: *Decoder, block: []const u8, out: []Header, out_bytes: []u8) Error!Headers {
        return self.decodeInto(block, out, out_bytes, null);
    }

    /// `decode`, and record the RFC 7541 §6.2.3 never-indexed flag per field.
    /// An intermediary that re-encodes must forward such a field with the
    /// same representation, so this is the variant a proxy uses.
    ///
    /// `never_indexed` must have a flag for every field `out` can hold.
    pub fn decodeFlags(
        self: *Decoder,
        block: []const u8,
        out: []Header,
        out_bytes: []u8,
        never_indexed: []bool,
    ) Error!Headers {
        assert(never_indexed.len >= out.len);
        return self.decodeInto(block, out, out_bytes, never_indexed);
    }

    fn decodeInto(
        self: *Decoder,
        block: []const u8,
        out: []Header,
        out_bytes: []u8,
        never_indexed: ?[]bool,
    ) Error!Headers {
        assert(!overlaps(block, out_bytes));
        assert(!overlaps(out_bytes, self.table.bytes));

        var cursor: Cursor = .init(block);
        var fields: usize = 0;
        var bytes: usize = 0;
        var seen_field = false;

        while (!cursor.atEnd()) {
            const first = cursor.peek().?;
            if (first & 0x80 != 0) {
                // Indexed header field (§6.1).
                const index = try integer(&cursor, 7);
                const field = try self.resolve(index);
                const copied = try copyField(out_bytes, &bytes, field);
                try append(out, &fields, copied, false, never_indexed);
                seen_field = true;
            } else if (first & 0x40 != 0) {
                // Literal header field with incremental indexing (§6.2.1).
                const index = try integer(&cursor, 6);
                const name = try self.literalName(&cursor, index, out_bytes, &bytes);
                const value = try string(&cursor, out_bytes, &bytes);
                try append(out, &fields, .{ .name = name, .value = value }, false, never_indexed);
                self.table.insert(name, value);
                seen_field = true;
            } else if (first & 0x20 != 0) {
                // Dynamic table size update (§6.3).
                if (seen_field) return error.TableSizeUpdateNotFirst;
                const size = try integer(&cursor, 5);
                self.table.setMaxSize(size) catch |err| switch (err) {
                    error.TooLarge => return error.TableSizeTooLarge,
                };
            } else {
                // Literal header field without indexing (§6.2.2) or never
                // indexed (§6.2.3). Both use a 4-bit prefix and neither
                // changes the table.
                const index = try integer(&cursor, 4);
                const name = try self.literalName(&cursor, index, out_bytes, &bytes);
                const value = try string(&cursor, out_bytes, &bytes);
                const never = first & 0x10 != 0;
                try append(out, &fields, .{ .name = name, .value = value }, never, never_indexed);
                seen_field = true;
            }
        }

        return .{ .items = out[0..fields] };
    }

    /// The name of a literal field: a string when the index is zero, else the
    /// name of the indexed field, copied out of the table.
    fn literalName(
        self: *const Decoder,
        cursor: *Cursor,
        index: u32,
        out_bytes: []u8,
        bytes: *usize,
    ) Error![]const u8 {
        if (index == 0) return string(cursor, out_bytes, bytes);
        const field = try self.resolve(index);
        return copy(out_bytes, bytes, field.name);
    }

    /// The indexed field, static or dynamic. Index 0 is not a field, and an
    /// index past the table is a decoding error.
    fn resolve(self: *const Decoder, index: u32) Error!Header {
        if (index == 0) return error.InvalidIndex;
        if (index <= static_table.count) return static_table.get(index).?;
        return self.table.get(index - first_dynamic) orelse error.InvalidIndex;
    }
};

/// A prefix integer, with the HPACK error names.
fn integer(cursor: *Cursor, bits: u4) Error!u32 {
    return prefix_int.decode(cursor, bits) catch |err| switch (err) {
        error.Truncated => error.Truncated,
        error.TooLarge => error.InvalidInteger,
    };
}

/// A string literal (§5.2): the H bit, a 7-bit length, then the bytes. The
/// decoded bytes go into `out_bytes`, whether Huffman-coded or not.
fn string(cursor: *Cursor, out_bytes: []u8, bytes: *usize) Error![]const u8 {
    const first = cursor.peek() orelse return error.Truncated;
    const encoded = first & 0x80 != 0;
    const len = try integer(cursor, 7);
    const raw = cursor.take(len) orelse return error.Truncated;

    if (!encoded) return copy(out_bytes, bytes, raw);

    const start = bytes.*;
    const written = huffman.decode(raw, out_bytes[start..]) catch |err| switch (err) {
        error.InvalidCode => return error.InvalidHuffman,
        error.NoSpace => return error.OutputTooSmall,
    };
    bytes.* += written;
    return out_bytes[start..][0..written];
}

fn copy(out_bytes: []u8, bytes: *usize, src: []const u8) Error![]const u8 {
    const start = bytes.*;
    const end = start + src.len;
    if (end > out_bytes.len) return error.OutputTooSmall;
    @memcpy(out_bytes[start..end], src);
    bytes.* = end;
    return out_bytes[start..end];
}

fn copyField(out_bytes: []u8, bytes: *usize, field: Header) Error!Header {
    const name = try copy(out_bytes, bytes, field.name);
    const value = try copy(out_bytes, bytes, field.value);
    return .{ .name = name, .value = value };
}

fn append(
    out: []Header,
    fields: *usize,
    field: Header,
    never: bool,
    flags: ?[]bool,
) Error!void {
    if (fields.* == out.len) return error.TooManyHeaders;
    out[fields.*] = field;
    if (flags) |bits| bits[fields.*] = never;
    fields.* += 1;
}

fn overlaps(block: []const u8, out_bytes: []const u8) bool {
    if (block.len == 0 or out_bytes.len == 0) return false;
    const a = @intFromPtr(block.ptr);
    const b = @intFromPtr(out_bytes.ptr);
    return a < b + out_bytes.len and b < a + block.len;
}

fn expectFields(headers: Headers, expected: []const Header) !void {
    try testing.expectEqual(expected.len, headers.items.len);
    for (expected, headers.items) |want, got| {
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqualStrings(want.value, got.value);
    }
}

const request_fields = [_]Header{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":authority", .value = "www.example.com" },
};

test "C.2.1: literal with indexing adds the entry (RFC 7541 §6.2.1)" {
    var table_memory: TableStorage.Buffer(256) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 256));

    var out: [4]Header = undefined;
    var out_bytes: [256]u8 = undefined;
    const headers = try decoder.decode(
        "\x40\x0acustom-key\x0dcustom-header",
        &out,
        &out_bytes,
    );

    try expectFields(headers, &.{.{ .name = "custom-key", .value = "custom-header" }});
    try testing.expectEqual(@as(usize, 55), decoder.table.size);
    try testing.expectEqualStrings("custom-key", decoder.table.get(0).?.name);
    try testing.expectEqualStrings("custom-header", decoder.table.get(0).?.value);
}

test "C.2.2: literal without indexing leaves the table alone (RFC 7541 §6.2.2)" {
    var table_memory: TableStorage.Buffer(256) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 256));

    var out: [4]Header = undefined;
    var out_bytes: [256]u8 = undefined;
    const headers = try decoder.decode("\x04\x0c/sample/path", &out, &out_bytes);

    try expectFields(headers, &.{.{ .name = ":path", .value = "/sample/path" }});
    try testing.expect(decoder.table.isEmpty());
}

test "C.2.3: never indexed leaves the table alone and sets the flag (RFC 7541 §6.2.3)" {
    var table_memory: TableStorage.Buffer(256) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 256));

    var out: [4]Header = undefined;
    var out_bytes: [256]u8 = undefined;
    var flags: [4]bool = undefined;
    const headers = try decoder.decodeFlags(
        "\x10\x08password\x06secret",
        &out,
        &out_bytes,
        &flags,
    );

    try expectFields(headers, &.{.{ .name = "password", .value = "secret" }});
    try testing.expect(flags[0]);
    try testing.expect(decoder.table.isEmpty());
}

test "C.2.4: an indexed field borrows nothing and returns a copy (RFC 7541 §6.1)" {
    var table_memory: TableStorage.Buffer(256) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 256));

    var out: [4]Header = undefined;
    var out_bytes: [256]u8 = undefined;
    var flags: [4]bool = undefined;
    const headers = try decoder.decodeFlags("\x82", &out, &out_bytes, &flags);

    try expectFields(headers, &.{.{ .name = ":method", .value = "GET" }});
    try testing.expect(!flags[0]);
    try testing.expect(decoder.table.isEmpty());
    try testing.expect(std.mem.startsWith(u8, headers.items[0].name, ":method"));
    try testing.expectEqual(
        @intFromPtr(&out_bytes),
        @intFromPtr(headers.items[0].name.ptr),
    );
}

test "C.3: three requests on one connection, no Huffman (RFC 7541 Appendix C.3)" {
    var table_memory: TableStorage.Buffer(4096) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 4096));

    var out: [8]Header = undefined;
    var out_bytes: [512]u8 = undefined;

    // C.3.1
    var headers = try decoder.decode("\x82\x86\x84\x41\x0fwww.example.com", &out, &out_bytes);
    try expectFields(headers, &request_fields);
    try testing.expectEqual(@as(usize, 57), decoder.table.size);

    // C.3.2: the authority is now dynamic index 62.
    const with_cache = request_fields ++ [_]Header{
        .{ .name = "cache-control", .value = "no-cache" },
    };
    headers = try decoder.decode("\x82\x86\x84\xbe\x58\x08no-cache", &out, &out_bytes);
    try expectFields(headers, &with_cache);
    try testing.expectEqual(@as(usize, 110), decoder.table.size);
    try testing.expectEqualStrings("cache-control", decoder.table.get(0).?.name);
    try testing.expectEqualStrings(":authority", decoder.table.get(1).?.name);

    // C.3.3: inserts custom-key: custom-value, total 164.
    const third = [_]Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/index.html" },
        .{ .name = ":authority", .value = "www.example.com" },
        .{ .name = "custom-key", .value = "custom-value" },
    };
    headers = try decoder.decode(
        "\x82\x87\x85\xbf\x40\x0acustom-key\x0ccustom-value",
        &out,
        &out_bytes,
    );
    try expectFields(headers, &third);
    try testing.expectEqual(@as(usize, 164), decoder.table.size);
}

test "C.4: the same requests with Huffman coding (RFC 7541 Appendix C.4)" {
    var table_memory: TableStorage.Buffer(4096) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 4096));

    var out: [8]Header = undefined;
    var out_bytes: [512]u8 = undefined;

    var headers = try decoder.decode(
        "\x82\x86\x84\x41\x8c\xf1\xe3\xc2\xe5\xf2\x3a\x6b\xa0\xab\x90\xf4\xff",
        &out,
        &out_bytes,
    );
    try expectFields(headers, &request_fields);
    try testing.expectEqual(@as(usize, 57), decoder.table.size);

    const with_cache = request_fields ++ [_]Header{
        .{ .name = "cache-control", .value = "no-cache" },
    };
    headers = try decoder.decode(
        "\x82\x86\x84\xbe\x58\x86\xa8\xeb\x10\x64\x9c\xbf",
        &out,
        &out_bytes,
    );
    try expectFields(headers, &with_cache);
    try testing.expectEqual(@as(usize, 110), decoder.table.size);

    const third = [_]Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/index.html" },
        .{ .name = ":authority", .value = "www.example.com" },
        .{ .name = "custom-key", .value = "custom-value" },
    };
    headers = try decoder.decode(
        "\x82\x87\x85\xbf\x40\x88\x25\xa8\x49\xe9\x5b\xa9\x7d\x7f" ++
            "\x89\x25\xa8\x49\xe9\x5b\xb8\xe8\xb4\xbf",
        &out,
        &out_bytes,
    );
    try expectFields(headers, &third);
    try testing.expectEqual(@as(usize, 164), decoder.table.size);
}

test "C.5: three responses with a 256-byte table, no Huffman (RFC 7541 Appendix C.5)" {
    var table_memory: TableStorage.Buffer(256) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 256));

    var out: [8]Header = undefined;
    var out_bytes: [512]u8 = undefined;

    // C.5.1
    var headers = try decoder.decode(
        "\x48\x03302" ++
            "\x58\x07private" ++
            "\x61\x1dMon, 21 Oct 2013 20:13:21 GMT" ++
            "\x6e\x17https://www.example.com",
        &out,
        &out_bytes,
    );
    try expectFields(headers, &.{
        .{ .name = ":status", .value = "302" },
        .{ .name = "cache-control", .value = "private" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:21 GMT" },
        .{ .name = "location", .value = "https://www.example.com" },
    });
    try testing.expectEqual(@as(usize, 222), decoder.table.size);
    try testing.expectEqualStrings("location", decoder.table.get(0).?.name);
    try testing.expectEqualStrings(":status", decoder.table.get(3).?.name);

    // C.5.2: inserting :status 307 evicts :status 302.
    headers = try decoder.decode("\x48\x03307\xc1\xc0\xbf", &out, &out_bytes);
    try expectFields(headers, &.{
        .{ .name = ":status", .value = "307" },
        .{ .name = "cache-control", .value = "private" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:21 GMT" },
        .{ .name = "location", .value = "https://www.example.com" },
    });
    try testing.expectEqual(@as(usize, 222), decoder.table.size);

    // C.5.3: three entries after evictions, total 215.
    headers = try decoder.decode(
        "\x88\xc1" ++
            "\x61\x1dMon, 21 Oct 2013 20:13:22 GMT" ++
            "\xc0" ++
            "\x5a\x04gzip" ++
            "\x77\x38foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
        &out,
        &out_bytes,
    );
    try expectFields(headers, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "cache-control", .value = "private" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:22 GMT" },
        .{ .name = "location", .value = "https://www.example.com" },
        .{ .name = "content-encoding", .value = "gzip" },
        .{
            .name = "set-cookie",
            .value = "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
        },
    });
    try testing.expectEqual(@as(usize, 215), decoder.table.size);
    try testing.expectEqualStrings("set-cookie", decoder.table.get(0).?.name);
    try testing.expectEqualStrings("content-encoding", decoder.table.get(1).?.name);
    try testing.expectEqualStrings("date", decoder.table.get(2).?.name);
}

test "C.6: the same responses with Huffman coding (RFC 7541 Appendix C.6)" {
    var table_memory: TableStorage.Buffer(256) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 256));

    var out: [8]Header = undefined;
    var out_bytes: [512]u8 = undefined;

    var headers = try decoder.decode(
        "\x48\x82\x64\x02" ++
            "\x58\x85\xae\xc3\x77\x1a\x4b" ++
            "\x61\x96\xd0\x7a\xbe\x94\x10\x54\xd4\x44\xa8\x20\x05\x95\x04\x0b" ++
            "\x81\x66\xe0\x82\xa6\x2d\x1b\xff" ++
            "\x6e\x91\x9d\x29\xad\x17\x18\x63\xc7\x8f\x0b\x97\xc8\xe9\xae\x82\xae\x43\xd3",
        &out,
        &out_bytes,
    );
    try expectFields(headers, &.{
        .{ .name = ":status", .value = "302" },
        .{ .name = "cache-control", .value = "private" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:21 GMT" },
        .{ .name = "location", .value = "https://www.example.com" },
    });
    try testing.expectEqual(@as(usize, 222), decoder.table.size);

    headers = try decoder.decode("\x48\x83\x64\x0e\xff\xc1\xc0\xbf", &out, &out_bytes);
    try expectFields(headers, &.{
        .{ .name = ":status", .value = "307" },
        .{ .name = "cache-control", .value = "private" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:21 GMT" },
        .{ .name = "location", .value = "https://www.example.com" },
    });
    try testing.expectEqual(@as(usize, 222), decoder.table.size);

    headers = try decoder.decode(
        "\x88\xc1" ++
            "\x61\x96\xd0\x7a\xbe\x94\x10\x54\xd4\x44\xa8\x20\x05\x95\x04\x0b" ++
            "\x81\x66\xe0\x84\xa6\x2d\x1b\xff" ++
            "\xc0" ++
            "\x5a\x83\x9b\xd9\xab" ++
            "\x77\xad\x94\xe7\x82\x1d\xd7\xf2\xe6\xc7\xb3\x35\xdf\xdf\xcd\x5b" ++
            "\x39\x60\xd5\xaf\x27\x08\x7f\x36\x72\xc1\xab\x27\x0f\xb5\x29\x1f" ++
            "\x95\x87\x31\x60\x65\xc0\x03\xed\x4e\xe5\xb1\x06\x3d\x50\x07",
        &out,
        &out_bytes,
    );
    try expectFields(headers, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "cache-control", .value = "private" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:22 GMT" },
        .{ .name = "location", .value = "https://www.example.com" },
        .{ .name = "content-encoding", .value = "gzip" },
        .{
            .name = "set-cookie",
            .value = "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
        },
    });
    try testing.expectEqual(@as(usize, 215), decoder.table.size);
}

test "a size update is accepted only before the first field (RFC 7541 §4.2)" {
    var table_memory: TableStorage.Buffer(128) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 128));

    var out: [4]Header = undefined;
    var out_bytes: [128]u8 = undefined;

    // 0x20 is an update to 0; then 0x3f 0x22 is an update to 65.
    _ = try decoder.decode("\x20\x3f\x22", &out, &out_bytes);
    try testing.expectEqual(@as(usize, 65), decoder.table.max_size);

    try testing.expectError(
        error.TableSizeUpdateNotFirst,
        decoder.decode("\x82\x20", &out, &out_bytes),
    );
}

test "a size update above our advertised size is an error (RFC 7541 §6.3)" {
    var table_memory: TableStorage.Buffer(64) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 64));

    var out: [4]Header = undefined;
    var out_bytes: [128]u8 = undefined;

    // 65 with a 5-bit prefix: 31, then 34.
    try testing.expectError(
        error.TableSizeTooLarge,
        decoder.decode("\x3f\x22", &out, &out_bytes),
    );
}

test "index 0 and an index past the tables are errors (RFC 7541 §6.1)" {
    var table_memory: TableStorage.Buffer(128) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 128));

    var out: [4]Header = undefined;
    var out_bytes: [128]u8 = undefined;

    try testing.expectError(error.InvalidIndex, decoder.decode("\x80", &out, &out_bytes));
    // 62 is the first dynamic index, and the table is empty.
    try testing.expectError(error.InvalidIndex, decoder.decode("\xbe", &out, &out_bytes));
    // A literal with an indexed name that does not exist.
    try testing.expectError(error.InvalidIndex, decoder.decode("\x7e\x00", &out, &out_bytes));
}

test "a block that ends before a string is truncated, not out of bounds" {
    var table_memory: TableStorage.Buffer(128) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 128));

    var out: [4]Header = undefined;
    var out_bytes: [128]u8 = undefined;

    // Literal with a new name, but the name string never starts.
    try testing.expectError(error.Truncated, decoder.decode("\x40\x00", &out, &out_bytes));
    // Literal with an indexed name, but the value string never starts.
    try testing.expectError(error.Truncated, decoder.decode("\x01", &out, &out_bytes));
}

test "a truncated block and an oversized integer are errors" {
    var table_memory: TableStorage.Buffer(128) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 128));

    var out: [4]Header = undefined;
    var out_bytes: [128]u8 = undefined;

    // A name length with no name.
    try testing.expectError(error.Truncated, decoder.decode("\x40\x0a", &out, &out_bytes));
    // A value length longer than the rest of the block.
    try testing.expectError(error.Truncated, decoder.decode("\x40\x00\x0aab", &out, &out_bytes));
    // Continuation octets past 32 bits.
    try testing.expectError(
        error.InvalidInteger,
        decoder.decode("\xff\xff\xff\xff\xff\xff\xff", &out, &out_bytes),
    );
}

test "bad Huffman data is an error, and the caller's space is separate" {
    var table_memory: TableStorage.Buffer(128) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 128));

    var out: [4]Header = undefined;
    var out_bytes: [128]u8 = undefined;

    // 0x81 sets H and a one-byte length; 0xff is not a code.
    try testing.expectError(error.InvalidHuffman, decoder.decode("\x40\x81\xff", &out, &out_bytes));

    var small_out: [1]Header = undefined;
    try testing.expectError(
        error.TooManyHeaders,
        decoder.decode("\x82\x86", &small_out, &out_bytes),
    );

    var small_bytes: [1]u8 = undefined;
    try testing.expectError(
        error.OutputTooSmall,
        decoder.decode("\x82", &out, &small_bytes),
    );
}

test "the never-indexed flag is recorded for every field" {
    var table_memory: TableStorage.Buffer(128) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 128));

    var out: [4]Header = undefined;
    var out_bytes: [256]u8 = undefined;
    var flags: [4]bool = undefined;

    // :method GET (indexed), then password: secret (never indexed).
    const headers = try decoder.decodeFlags(
        "\x82\x10\x08password\x06secret",
        &out,
        &out_bytes,
        &flags,
    );
    try expectFields(headers, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = "password", .value = "secret" },
    });
    try testing.expect(!flags[0]);
    try testing.expect(flags[1]);
}

test "every field lives in out_bytes, whatever table it came from" {
    var table_memory: TableStorage.Buffer(256) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 256));

    var out: [4]Header = undefined;
    var out_bytes: [256]u8 = undefined;

    const headers = try decoder.decode(
        "\x40\x0acustom-key\x0dcustom-header\xbe",
        &out,
        &out_bytes,
    );
    for (headers.items) |header| {
        try testing.expect(within(&out_bytes, header.name));
        try testing.expect(within(&out_bytes, header.value));
    }
}

fn within(outer: []const u8, inner: []const u8) bool {
    const base = @intFromPtr(outer.ptr);
    const start = @intFromPtr(inner.ptr);
    return start >= base and start + inner.len <= base + outer.len;
}

test "fuzz decoding: arbitrary blocks never overrun the outputs" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var block_buf: [128]u8 = undefined;
            const block = block_buf[0..smith.slice(&block_buf)];

            var table_memory: TableStorage.Buffer(256) = undefined;
            var decoder = Decoder.init(try .initBuffer(&table_memory, 256));

            var out: [8]Header = undefined;
            var out_bytes: [512]u8 = undefined;
            var flags: [8]bool = undefined;

            const headers = decoder.decodeFlags(block, &out, &out_bytes, &flags) catch return;

            try testing.expect(headers.items.len <= out.len);
            for (headers.items) |header| {
                try testing.expect(within(&out_bytes, header.name));
                try testing.expect(within(&out_bytes, header.value));
            }
            try testing.expect(decoder.table.size <= decoder.table.max_size);
            try testing.expect(decoder.table.used() <= table_memory.len);
        }
    }.run, .{
        .corpus = &.{
            "",
            "\x82\x86\x84\x41\x0fwww.example.com",
            "\x40\x0acustom-key\x0dcustom-header",
            "\x10\x08password\x06secret",
            "\x20\x3f\x22",
            "\xff\xff\xff\xff",
        },
    });
}

test "an allocated TableStorage decodes" {
    var storage = try TableStorage.init(testing.allocator, 4096);
    defer storage.deinit(testing.allocator);
    var decoder = Decoder.init(storage);

    var out: [4]Header = undefined;
    var out_bytes: [256]u8 = undefined;
    const headers = try decoder.decode("\x82", &out, &out_bytes);
    try testing.expectEqual(@as(usize, 1), headers.items.len);
    try testing.expectEqualStrings(":method", headers.items[0].name);
    try testing.expectEqualStrings("GET", headers.items[0].value);
}

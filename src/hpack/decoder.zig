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
//! connection. A decoding error stops the block where it is, so the dynamic
//! table can no longer match the peer's, and a later block would decode
//! against the wrong table.
//!
//! `error.TooManyHeaders` and `error.OutputTooSmall` are local: the caller's
//! arrays were too small, which is not the peer's fault. No size rules them
//! out, because one indexed byte copies a whole table entry, so they do not
//! stop the block. The decoder drops the fields and works through the rest,
//! checking it as strictly and applying every table update, and returns the
//! error at the end with the table in step: an HTTP/2 caller resets one
//! stream and keeps the connection. A decoding error later in the block still
//! wins. To update the table without the fields, each new entry is staged at
//! the start of `out_bytes`, so that needs `out_bytes` to hold the largest
//! entry the table takes, its maximum size less 32; the `TableStorage` size is
//! always enough. With a smaller `out_bytes`, a local error stops the block
//! where it is, as a decoding error does.
//!
//! Whenever a block ends early or is invalid, the table may no longer match
//! the peer's, so the decoder is poisoned: this call returns its error, and
//! every later `decode` returns `error.Desynchronized` without reading the
//! table. A local error is not poisoning only when the whole block was read
//! with the table in step.

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
    /// An earlier block ended early or was invalid, so the table cannot match
    /// the peer's. The decoder is not usable again.
    Desynchronized,
};

pub const Decoder = struct {
    table: DynamicTable,
    /// Set when a block ended early or was invalid. Never cleared.
    poisoned: bool,

    /// The storage is the SETTINGS_HEADER_TABLE_SIZE this decoder advertises,
    /// and so the largest size a peer may ask for. `TableStorage.init` sizes it
    /// from that value.
    pub fn init(storage: TableStorage) Decoder {
        return .{ .table = .init(storage), .poisoned = false };
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
        if (self.poisoned) return error.Desynchronized;
        assert(!overlaps(block, out_bytes));
        assert(!overlaps(out_bytes, self.table.bytes));

        // Every return but the two below leaves the block unfinished or the
        // table possibly out of step.
        self.poisoned = true;
        var cursor: Cursor = .init(block);
        var fields: usize = 0;
        var bytes: usize = 0;
        var seen_field = false;
        // The first local error. Every field from there on is dropped, and
        // the rest of the block only updates the table.
        var dropped: ?Error = null;

        while (!cursor.atEnd()) {
            const first = cursor.peek().?;
            if (first & 0xe0 == 0x20) {
                // Dynamic table size update (§6.3).
                if (seen_field) return error.TableSizeUpdateNotFirst;
                const size = try integer(&cursor, 5);
                self.table.setMaxSize(size) catch |err| switch (err) {
                    error.TooLarge => return error.TableSizeTooLarge,
                };
                continue;
            }

            seen_field = true;
            if (dropped == null) {
                const start = cursor;
                if (self.emit(&cursor, first, out, out_bytes, &fields, &bytes, never_indexed)) |_| {
                    continue;
                } else |err| switch (err) {
                    error.TooManyHeaders, error.OutputTooSmall => {
                        // The size is final once a field is seen (§4.2). If
                        // an entry the table takes may not fit `out_bytes`,
                        // `drop` cannot stage it, so the block cannot finish
                        // in step.
                        if (out_bytes.len + dynamic_table.entry_overhead < self.table.max_size) {
                            return err;
                        }
                        dropped = err;
                        // `emit` changes the table last, so it is untouched:
                        // read the field again to drop it.
                        cursor = start;
                    },
                    else => return err,
                }
            }
            try self.drop(&cursor, first, out_bytes);
        }

        // The whole block was read and the table is in step.
        self.poisoned = false;
        if (dropped) |err| return err;
        return .{ .items = out[0..fields] };
    }

    /// Decode one field representation (§6.1, §6.2) into the caller's
    /// arrays, and add it to the table if the representation says to.
    fn emit(
        self: *Decoder,
        cursor: *Cursor,
        first: u8,
        out: []Header,
        out_bytes: []u8,
        fields: *usize,
        bytes: *usize,
        never_indexed: ?[]bool,
    ) Error!void {
        if (first & 0x80 != 0) {
            // Indexed header field (§6.1).
            const field = try self.resolve(try integer(cursor, 7));
            const name = try copy(out_bytes, bytes, field.name);
            const value = try copy(out_bytes, bytes, field.value);
            return append(out, fields, .{ .name = name, .value = value }, false, never_indexed);
        }

        // Literal header field with incremental indexing (§6.2.1), or without
        // indexing (§6.2.2) or never indexed (§6.2.3). The last two use a
        // 4-bit prefix and leave the table alone.
        const insert = first & 0x40 != 0;
        const index = try integer(cursor, if (insert) 6 else 4);
        const name = try put(out_bytes, bytes, try self.literalName(cursor, index));
        const value = try put(out_bytes, bytes, try literal(cursor));
        const never = !insert and first & 0x10 != 0;
        try append(out, fields, .{ .name = name, .value = value }, never, never_indexed);
        if (insert) self.table.insert(name, value);
    }

    /// Read one field representation the caller's arrays have no room for:
    /// check it in the order `emit` does, and change the table as `emit`
    /// would. A new entry is staged at the start of `out_bytes`, whose fields
    /// are lost anyway.
    fn drop(self: *Decoder, cursor: *Cursor, first: u8, out_bytes: []u8) Error!void {
        if (first & 0x80 != 0) {
            _ = try self.resolve(try integer(cursor, 7));
            return;
        }

        const insert = first & 0x40 != 0;
        const index = try integer(cursor, if (insert) 6 else 4);
        const name = try self.literalName(cursor, index);
        const name_len = try decodedLen(name);
        const value = try literal(cursor);
        const len = name_len + try decodedLen(value);
        if (!insert) return;

        // An entry above the maximum empties the table, as `insert` does, and
        // has no bytes to stage.
        if (len + dynamic_table.entry_overhead > self.table.max_size) {
            self.table.clear();
            return;
        }
        assert(len <= out_bytes.len);
        var staged: usize = 0;
        const staged_name = put(out_bytes, &staged, name) catch unreachable;
        const staged_value = put(out_bytes, &staged, value) catch unreachable;
        self.table.insert(staged_name, staged_value);
    }

    /// The name of a literal field: a string when the index is zero, else the
    /// name of the indexed field, still in the table.
    fn literalName(self: *const Decoder, cursor: *Cursor, index: u32) Error!Literal {
        if (index == 0) return literal(cursor);
        return .raw((try self.resolve(index)).name);
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

/// A string as the block holds it, or a name still in a table, which is raw.
const Literal = struct {
    bytes: []const u8,
    huffman: bool,

    fn raw(bytes: []const u8) Literal {
        return .{ .bytes = bytes, .huffman = false };
    }
};

/// A string literal (§5.2): the H bit, a 7-bit length, then the bytes.
fn literal(cursor: *Cursor) Error!Literal {
    const first = cursor.peek() orelse return error.Truncated;
    const len = try integer(cursor, 7);
    const bytes = cursor.take(len) orelse return error.Truncated;
    return .{ .bytes = bytes, .huffman = first & 0x80 != 0 };
}

/// Decode a string into `out_bytes` at `bytes`, whether Huffman-coded or not.
fn put(out_bytes: []u8, bytes: *usize, text: Literal) Error![]const u8 {
    if (!text.huffman) return copy(out_bytes, bytes, text.bytes);

    const start = bytes.*;
    const written = huffman.decode(text.bytes, out_bytes[start..]) catch |err| switch (err) {
        error.InvalidCode => return error.InvalidHuffman,
        error.NoSpace => return error.OutputTooSmall,
    };
    bytes.* += written;
    return out_bytes[start..][0..written];
}

/// The length `put` would write, with the same checks.
fn decodedLen(text: Literal) Error!usize {
    if (!text.huffman) return text.bytes.len;
    return huffman.decodedLen(text.bytes) catch return error.InvalidHuffman;
}

fn copy(out_bytes: []u8, bytes: *usize, src: []const u8) Error![]const u8 {
    const start = bytes.*;
    const end = start + src.len;
    if (end > out_bytes.len) return error.OutputTooSmall;
    @memcpy(out_bytes[start..end], src);
    bytes.* = end;
    return out_bytes[start..end];
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
    // A decoding error poisons the decoder; each case below starts afresh.
    try testing.expectError(error.Desynchronized, decoder.decode("\x82", &out, &out_bytes));
    // 62 is the first dynamic index, and the table is empty.
    decoder = Decoder.init(try .initBuffer(&table_memory, 128));
    try testing.expectError(error.InvalidIndex, decoder.decode("\xbe", &out, &out_bytes));
    // A literal with an indexed name that does not exist.
    decoder = Decoder.init(try .initBuffer(&table_memory, 128));
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
    decoder = Decoder.init(try .initBuffer(&table_memory, 128));
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
    decoder = Decoder.init(try .initBuffer(&table_memory, 128));
    try testing.expectError(error.Truncated, decoder.decode("\x40\x00\x0aab", &out, &out_bytes));
    // Continuation octets past 32 bits.
    decoder = Decoder.init(try .initBuffer(&table_memory, 128));
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
    try testing.expectError(error.Desynchronized, decoder.decode("\x82", &out, &out_bytes));

    // A caller's array that is too small is not the peer's fault: with the
    // table in step, the decoder stays usable.
    decoder = Decoder.init(try .initBuffer(&table_memory, 128));
    var small_out: [1]Header = undefined;
    try testing.expectError(
        error.TooManyHeaders,
        decoder.decode("\x82\x86", &small_out, &out_bytes),
    );
    try testing.expect(!decoder.poisoned);
    _ = try decoder.decode("\x82", &out, &out_bytes);

    // `out_bytes` too small to stage the largest entry stops the block early.
    var small_bytes: [1]u8 = undefined;
    try testing.expectError(
        error.OutputTooSmall,
        decoder.decode("\x82", &out, &small_bytes),
    );
    try testing.expectError(error.Desynchronized, decoder.decode("\x82", &out, &out_bytes));
}

test "a local error after the whole block is read keeps the decoder usable" {
    var table_memory: TableStorage.Buffer(64) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 64));

    var out: [1]Header = undefined;
    var out_bytes: [64]u8 = undefined;

    try testing.expectError(
        error.TooManyHeaders,
        decoder.decode("\x82\x40\x01a\x011", &out, &out_bytes),
    );
    try testing.expect(!decoder.poisoned);
    const headers = try decoder.decode("\xbe", &out, &out_bytes);
    try expectFields(headers, &.{.{ .name = "a", .value = "1" }});
}

test "invalid HPACK after a local error, in the dropped path, poisons" {
    var out: [1]Header = undefined;
    var out_bytes: [64]u8 = undefined;
    // The first field fills `out`; the rest is read by `drop`. Each tail is
    // invalid: an index past the table, bad Huffman, a truncated string, and a
    // size update after a field.
    const tails = [_][]const u8{ "\xbe", "\x40\x81\xff\x011", "\x40\x01a\x05ab", "\x20" };
    const wants = [_]anyerror{
        error.InvalidIndex,
        error.InvalidHuffman,
        error.Truncated,
        error.TableSizeUpdateNotFirst,
    };
    for (tails, wants) |tail, want| {
        var table_memory: TableStorage.Buffer(64) = undefined;
        var decoder = Decoder.init(try .initBuffer(&table_memory, 64));
        var block: [16]u8 = undefined;
        const joined = try std.fmt.bufPrint(&block, "\x82\x86{s}", .{tail});
        try testing.expectError(want, decoder.decode(joined, &out, &out_bytes));
        try testing.expect(decoder.poisoned);
        try testing.expectError(error.Desynchronized, decoder.decode("\x82", &out, &out_bytes));
    }
}

test "a full field array drops the fields and keeps the table in step" {
    var table_memory: TableStorage.Buffer(256) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 256));

    var out: [1]Header = undefined;
    var out_bytes: [256]u8 = undefined;
    // Three literals with incremental indexing; the second has no slot.
    try testing.expectError(
        error.TooManyHeaders,
        decoder.decode("\x40\x01a\x011\x40\x01b\x012\x40\x01c\x013", &out, &out_bytes),
    );
    try testing.expectEqual(@as(usize, 3), decoder.table.count);

    // Index 62 is the newest entry, the third field, and 64 the first.
    var room: [4]Header = undefined;
    const headers = try decoder.decode("\xbe\xc0", &room, &out_bytes);
    try expectFields(headers, &.{
        .{ .name = "c", .value = "3" },
        .{ .name = "a", .value = "1" },
    });
}

test "a full output buffer drops the fields and keeps the table in step" {
    // A 64-byte table takes an entry of up to 32 bytes, which is all the
    // out_bytes it needs to stage one.
    var table_memory: TableStorage.Buffer(64) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 64));

    var out: [8]Header = undefined;
    var out_bytes: [32]u8 = undefined;
    // Each field is 15 bytes and a 47-byte entry, so the table keeps only the
    // newest. The third field runs past out_bytes.
    const block = "\x40\x01a\x0e" ++ @as([14]u8, @splat('a')) ++
        "\x40\x01b\x0e" ++ @as([14]u8, @splat('b')) ++
        "\x40\x01c\x0e" ++ @as([14]u8, @splat('c'));
    try testing.expectError(error.OutputTooSmall, decoder.decode(block, &out, &out_bytes));
    try testing.expectEqual(@as(usize, 1), decoder.table.count);

    const headers = try decoder.decode("\xbe", &out, &out_bytes);
    try expectFields(headers, &.{.{ .name = "c", .value = &@as([14]u8, @splat('c')) }});
}

test "an entry above the maximum after the output runs out empties the table (RFC 7541 §4.4)" {
    var table_memory: TableStorage.Buffer(64) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 64));

    var out: [8]Header = undefined;
    var out_bytes: [32]u8 = undefined;
    // `a: 1` enters the table. The 41-byte `b` field runs past out_bytes, and
    // its 73-byte entry is above the 64-byte maximum.
    try testing.expectError(
        error.OutputTooSmall,
        decoder.decode(
            "\x40\x01a\x011" ++ "\x40\x01b\x28" ++ @as([40]u8, @splat('b')),
            &out,
            &out_bytes,
        ),
    );
    try testing.expect(decoder.table.isEmpty());
}

test "a decoding error after the fields run out still wins" {
    var table_memory: TableStorage.Buffer(64) = undefined;
    var decoder = Decoder.init(try .initBuffer(&table_memory, 64));

    var out: [1]Header = undefined;
    var out_bytes: [32]u8 = undefined;

    // The second field has no slot; then comes a size update that is not
    // first (§4.2), an index past the empty dynamic table, or a value that
    // ends early.
    try testing.expectError(
        error.TableSizeUpdateNotFirst,
        decoder.decode("\x82\x86\x20", &out, &out_bytes),
    );
    decoder = Decoder.init(try .initBuffer(&table_memory, 64));
    try testing.expectError(error.InvalidIndex, decoder.decode("\x82\x86\xbe", &out, &out_bytes));
    decoder = Decoder.init(try .initBuffer(&table_memory, 64));
    try testing.expectError(
        error.Truncated,
        decoder.decode("\x82\x86\x40\x01a\x05ab", &out, &out_bytes),
    );

    decoder = Decoder.init(try .initBuffer(&table_memory, 64));
    // The first field fills out_bytes but for the name `b`. The value's first
    // code has no room, and its padding is a zero bit (§5.2).
    try testing.expectError(
        error.InvalidHuffman,
        decoder.decode(
            "\x00\x01a\x1e" ++ @as([30]u8, @splat('a')) ++ "\x00\x01b\x82\x00\x00",
            &out,
            &out_bytes,
        ),
    );
}

test "out_bytes smaller than the largest entry stops at a local error" {
    var out: [1]Header = undefined;
    var out_bytes: [32]u8 = undefined;
    // `a: 1` has no slot. With 32 bytes, any entry a 64-byte table takes can
    // be staged, so it still goes in; with 31, the block stops.
    const block = "\x82\x40\x01a\x011";

    var roomy_memory: TableStorage.Buffer(64) = undefined;
    var roomy = Decoder.init(try .initBuffer(&roomy_memory, 64));
    try testing.expectError(error.TooManyHeaders, roomy.decode(block, &out, &out_bytes));
    try testing.expectEqual(@as(usize, 1), roomy.table.count);

    var short_memory: TableStorage.Buffer(64) = undefined;
    var short = Decoder.init(try .initBuffer(&short_memory, 64));
    try testing.expectError(error.TooManyHeaders, short.decode(block, &out, out_bytes[0..31]));
    try testing.expect(short.table.isEmpty());
    // The block stopped early, so no later block may use the table, even a
    // valid one.
    try testing.expect(short.poisoned);
    try testing.expectError(error.Desynchronized, short.decode("\x82", &out, &out_bytes));
    try testing.expect(short.table.isEmpty());
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

fn isLocal(err: Error) bool {
    return err == error.TooManyHeaders or err == error.OutputTooSmall;
}

fn expectSameTable(want: *const DynamicTable, got: *const DynamicTable) !void {
    try testing.expectEqual(want.max_size, got.max_size);
    try testing.expectEqual(want.size, got.size);
    try testing.expectEqual(want.count, got.count);
    for (0..want.count) |index| {
        try testing.expectEqualStrings(want.get(index).?.name, got.get(index).?.name);
        try testing.expectEqualStrings(want.get(index).?.value, got.get(index).?.value);
    }
}

/// A corpus entry for a test that reads its block with `Smith.slice`: the
/// length as four little-endian bytes, then the block.
fn sliceInput(comptime block: []const u8) []const u8 {
    return comptime input: {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, block.len, .little);
        const bytes = len ++ block[0..block.len].*;
        break :input &bytes;
    };
}

test "fuzz decoding: arrays that run out leave the table a roomy decode leaves" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var block_buf: [128]u8 = undefined;
            const block = block_buf[0..smith.slice(&block_buf)];

            var roomy_memory: TableStorage.Buffer(256) = undefined;
            var roomy = Decoder.init(try .initBuffer(&roomy_memory, 256));
            var roomy_out: [128]Header = undefined;
            var roomy_bytes: [8192]u8 = undefined;
            const want = roomy.decode(block, &roomy_out, &roomy_bytes);

            // Two fields, and the least out_bytes that keeps a 256-byte
            // table in step.
            var tight_memory: TableStorage.Buffer(256) = undefined;
            var tight = Decoder.init(try .initBuffer(&tight_memory, 256));
            var tight_out: [2]Header = undefined;
            var tight_bytes: [256 - 32]u8 = undefined;
            const got = tight.decode(block, &tight_out, &tight_bytes);

            // Both see the same decoding error, and only the tight one can
            // run out where the roomy one did not.
            if (want) |want_headers| {
                if (got) |got_headers| {
                    try expectFields(got_headers, want_headers.items);
                } else |err| try testing.expect(isLocal(err));
            } else |want_err| {
                const got_err = if (got) |_| return error.TestUnexpectedResult else |err| err;
                if (isLocal(want_err)) {
                    try testing.expect(isLocal(got_err));
                } else {
                    try testing.expectEqual(want_err, got_err);
                }
            }
            try expectSameTable(&roomy.table, &tight.table);
        }
    }.run, .{
        .corpus = &.{
            // RFC 7541 C.3.1 and C.4.1: the fourth field enters the table.
            sliceInput("\x82\x86\x84\x41\x0fwww.example.com"),
            sliceInput("\x82\x86\x84\x41\x8c\xf1\xe3\xc2\xe5\xf2\x3a\x6b\xa0\xab\x90\xf4\xff"),
            // C.5.1 and C.6.1: four entries in a 256-byte table.
            sliceInput("\x48\x03302\x58\x07private\x61\x1dMon, 21 Oct 2013 20:13:21 GMT" ++
                "\x6e\x17https://www.example.com"),
            sliceInput("\x48\x82\x64\x02\x58\x85\xae\xc3\x77\x1a\x4b" ++
                "\x61\x96\xd0\x7a\xbe\x94\x10\x54\xd4\x44\xa8\x20\x05\x95\x04\x0b" ++
                "\x81\x66\xe0\x82\xa6\x2d\x1b\xff" ++
                "\x6e\x91\x9d\x29\xad\x17\x18\x63\xc7\x8f\x0b\x97\xc8\xe9\xae\x82\xae\x43\xd3"),
            // Copies of a 101-byte entry run past the tight out_bytes; the
            // last field still enters the table.
            sliceInput("\x40\x01a\x64" ++ @as([100]u8, @splat('x')) ++ "\xbe\xbe\x40\x01b\x011"),
            // A size update to 48, then a 49-byte entry after the overflow.
            sliceInput("\x3f\x11\x40\x01b\x011\x82\x86\x40\x01a\x10" ++ @as([16]u8, @splat('x'))),
            // Decoding errors after the overflow: bad Huffman padding, a
            // late size update, an index past the table.
            sliceInput("\x82\x86\x84\x00\x01b\x82\x00\x00"),
            sliceInput("\x82\x86\x84\x20"),
            sliceInput("\x82\x86\x84\xbe"),
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

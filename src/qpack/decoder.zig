//! The QPACK field-section decoder (RFC 9204 §4.5).
//!
//! A field section is a prefix (Required Insert Count and Base) followed by
//! field lines. The decoder owns the dynamic table; the encoder stream feeds
//! it, and a field section reads it. Every field is copied into the caller's
//! buffers, so a table eviction or compaction cannot invalidate a `Header`.
//!
//! A section whose Required Insert Count is ahead of the table is blocked. The
//! decoder reports the count and the Base and changes no state; the caller
//! holds the encoded block and retries when the encoder stream catches up
//! (RFC 9204 §2.1.2).
//!
//! The `N` bit on literal representations means an intermediary must not index
//! the field. `decodeFlags` reports it in a parallel array; `decode` drops it.

const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const Cursor = @import("../Cursor.zig");
const Header = @import("../header.zig").Header;
const Headers = @import("../header.zig").Headers;
const prefix_int = @import("../prefix_int.zig");
const static_table = @import("static_table.zig");
const string = @import("string.zig");
const dynamic_table = @import("dynamic_table.zig");
const DynamicTable = dynamic_table.DynamicTable;
const TableStorage = @import("../TableStorage.zig");

pub const Error = error{
    /// The block ended inside the prefix or a field line.
    Truncated,
    /// The output buffers cannot hold the decoded section.
    NoSpace,
    /// A string literal is not valid.
    InvalidHuffman,
    /// A numeric field does not fit 62 bits.
    InvalidLength,
    /// The Required Insert Count encoding is not one a conformant encoder
    /// could produce (§4.5.1.1).
    InvalidPrefix,
    /// A Base with the sign bit set requires a Required Insert Count above
    /// the Delta Base (§4.5.1.2).
    InvalidBase,
    /// A static or dynamic reference names an entry that is not there.
    InvalidIndex,
};

pub const Blocked = struct {
    /// The Insert Count this section needs. The caller retries once the
    /// dynamic table reaches it.
    required_insert_count: u64,
    /// The Base the section resolved to, for the retry.
    base: u64,
};

pub const Fields = struct {
    headers: Headers,
    /// The Required Insert Count the section declared. The caller sends a
    /// Section Acknowledgment when this is not zero (RFC 9204 §4.4.1).
    required_insert_count: u64,
};

pub const Result = union(enum) {
    fields: Fields,
    blocked: Blocked,
};

pub const Decoder = struct {
    table: DynamicTable,

    pub fn init(storage: TableStorage) Decoder {
        return .{ .table = DynamicTable.init(storage) };
    }

    /// Decode one complete field section. `out` holds the fields and
    /// `out_bytes` holds their names and values; both are caller-owned.
    pub fn decode(
        self: *Decoder,
        block: []const u8,
        out: []Header,
        out_bytes: []u8,
    ) Error!Result {
        return self.decodeFlags(block, out, out_bytes, null);
    }

    /// As `decode`, and fill `flags` with the `N` bit of each field line.
    /// `flags` must be at least as long as `out`.
    pub fn decodeFlags(
        self: *Decoder,
        block: []const u8,
        out: []Header,
        out_bytes: []u8,
        flags: ?[]bool,
    ) Error!Result {
        var cursor = Cursor.init(block);
        const prefix = try self.parsePrefix(&cursor);

        if (prefix.required_insert_count > self.table.insert_count) {
            return .{ .blocked = .{
                .required_insert_count = prefix.required_insert_count,
                .base = prefix.base,
            } };
        }

        var count: usize = 0;
        var used: usize = 0;
        while (!cursor.atEnd()) {
            if (count == out.len) return error.NoSpace;
            if (flags) |bits| {
                if (count == bits.len) return error.NoSpace;
            }

            const field = try self.decodeFieldLine(
                &cursor,
                prefix.required_insert_count,
                prefix.base,
                out_bytes,
                &used,
            );
            out[count] = field.header;
            if (flags) |bits| bits[count] = field.never_indexed;
            count += 1;
        }

        return .{ .fields = .{
            .headers = .{ .items = out[0..count] },
            .required_insert_count = prefix.required_insert_count,
        } };
    }

    const Prefix = struct {
        required_insert_count: u64,
        base: u64,
    };

    fn parsePrefix(self: *Decoder, cursor: *Cursor) Error!Prefix {
        const encoded = try decodeInteger(cursor, 8);

        var required_insert_count: u64 = 0;
        if (encoded != 0) {
            const max_entries: u64 = self.table.max_capacity / dynamic_table.entry_overhead;
            if (max_entries == 0) return error.InvalidPrefix;

            const full_range = 2 * max_entries;
            if (encoded > full_range) return error.InvalidPrefix;

            const max_value = self.table.insert_count + max_entries;
            const max_wrapped = (max_value / full_range) * full_range;
            required_insert_count = max_wrapped + encoded - 1;

            if (required_insert_count > max_value) {
                if (required_insert_count <= full_range) return error.InvalidPrefix;
                required_insert_count -= full_range;
            }
            if (required_insert_count == 0) return error.InvalidPrefix;
        }

        const first = cursor.peek() orelse return error.Truncated;
        const negative = first & 0x80 != 0;
        const delta = try decodeInteger(cursor, 7);

        const base = if (negative) blk: {
            if (required_insert_count <= delta) return error.InvalidBase;
            break :blk required_insert_count - delta - 1;
        } else required_insert_count + delta;

        return .{
            .required_insert_count = required_insert_count,
            .base = base,
        };
    }

    const Field = struct {
        header: Header,
        never_indexed: bool,
    };

    fn decodeFieldLine(
        self: *Decoder,
        cursor: *Cursor,
        required_insert_count: u64,
        base: u64,
        out_bytes: []u8,
        used: *usize,
    ) Error!Field {
        const first = cursor.peek() orelse return error.Truncated;

        if (first & 0x80 != 0) {
            const is_static = first & 0x40 != 0;
            const index = try decodeInteger(cursor, 6);
            const entry = try self.lookup(is_static, index, base, required_insert_count);
            return .{
                .header = try copyHeader(out_bytes, used, entry),
                .never_indexed = false,
            };
        }

        if (first & 0x40 != 0) {
            const never_indexed = first & 0x20 != 0;
            const is_static = first & 0x10 != 0;
            const index = try decodeInteger(cursor, 4);
            const entry = try self.lookup(is_static, index, base, required_insert_count);

            const value = try string.decode(cursor, 8, out_bytes[used.*..]);
            used.* += value.len;
            const name = try copyBytes(out_bytes, used, entry.name);
            return .{
                .header = .{ .name = name, .value = value },
                .never_indexed = never_indexed,
            };
        }

        if (first & 0x20 != 0) {
            const never_indexed = first & 0x10 != 0;
            const name = try string.decode(cursor, 4, out_bytes[used.*..]);
            used.* += name.len;
            const value = try string.decode(cursor, 8, out_bytes[used.*..]);
            used.* += value.len;
            return .{
                .header = .{ .name = name, .value = value },
                .never_indexed = never_indexed,
            };
        }

        if (first & 0x10 != 0) {
            const index = try decodeInteger(cursor, 4);
            const entry = try self.postBase(index, base, required_insert_count);
            return .{
                .header = try copyHeader(out_bytes, used, entry),
                .never_indexed = false,
            };
        }

        const never_indexed = first & 0x08 != 0;
        const index = try decodeInteger(cursor, 3);
        const entry = try self.postBase(index, base, required_insert_count);

        const value = try string.decode(cursor, 8, out_bytes[used.*..]);
        used.* += value.len;
        const name = try copyBytes(out_bytes, used, entry.name);
        return .{
            .header = .{ .name = name, .value = value },
            .never_indexed = never_indexed,
        };
    }

    fn lookup(
        self: *Decoder,
        is_static: bool,
        index: u62,
        base: u64,
        required_insert_count: u64,
    ) Error!Header {
        if (is_static) return static_table.get(index) orelse error.InvalidIndex;

        // A relative index reaches an entry below Base, and the Required
        // Insert Count must cover every dynamic entry the section uses.
        if (index >= base) return error.InvalidIndex;
        const absolute = base - 1 - index;
        if (absolute >= required_insert_count) return error.InvalidIndex;
        return self.table.get(absolute) orelse error.InvalidIndex;
    }

    fn postBase(self: *Decoder, index: u62, base: u64, required_insert_count: u64) Error!Header {
        const absolute = base + index;
        if (absolute < base or absolute >= required_insert_count) return error.InvalidIndex;
        return self.table.get(absolute) orelse error.InvalidIndex;
    }
};

fn decodeInteger(cursor: *Cursor, bits: u4) Error!u62 {
    return prefix_int.decodeWide(cursor, bits) catch |err| switch (err) {
        error.Truncated => error.Truncated,
        error.TooLarge => error.InvalidLength,
    };
}

fn copyHeader(out_bytes: []u8, used: *usize, header: Header) Error!Header {
    const name = try copyBytes(out_bytes, used, header.name);
    const value = try copyBytes(out_bytes, used, header.value);
    return .{ .name = name, .value = value };
}

fn copyBytes(out_bytes: []u8, used: *usize, bytes: []const u8) Error![]const u8 {
    if (bytes.len > out_bytes.len - used.*) return error.NoSpace;
    const start = used.*;
    @memcpy(out_bytes[start..][0..bytes.len], bytes);
    used.* += bytes.len;
    return out_bytes[start..][0..bytes.len];
}

test "RFC 9204 Appendix B.1, a literal line with a static name reference" {
    var memory: TableStorage.Buffer(220) = undefined;
    var decoder = Decoder.init(try TableStorage.initBuffer(&memory, 220));

    const block = [_]u8{
        0x00, 0x00, // Required Insert Count = 0, Base = 0
        0x51, 0x0b,
        '/',  'i',
        'n',  'd',
        'e',  'x',
        '.',  'h',
        't',  'm',
        'l',
    };
    var out: [8]Header = undefined;
    var bytes: [128]u8 = undefined;
    const result = try decoder.decode(&block, &out, &bytes);

    const fields = result.fields.headers;
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings(":path", fields.items[0].name);
    try testing.expectEqualStrings("/index.html", fields.items[0].value);
}

test "RFC 9204 Appendix B.2, two post-base indexed lines" {
    var memory: TableStorage.Buffer(220) = undefined;
    var decoder = Decoder.init(try TableStorage.initBuffer(&memory, 220));
    try decoder.table.setCapacity(220);
    try decoder.table.insert(":authority", "www.example.com");
    try decoder.table.insert(":path", "/sample/path");

    const block = [_]u8{ 0x03, 0x81, 0x10, 0x11 };
    var out: [8]Header = undefined;
    var bytes: [128]u8 = undefined;
    const fields = (try decoder.decode(&block, &out, &bytes)).fields.headers;

    try testing.expectEqual(@as(usize, 2), fields.items.len);
    try testing.expectEqualStrings(":authority", fields.items[0].name);
    try testing.expectEqualStrings("www.example.com", fields.items[0].value);
    try testing.expectEqualStrings(":path", fields.items[1].name);
    try testing.expectEqualStrings("/sample/path", fields.items[1].value);
}

test "RFC 9204 Appendix B.4, relative and static lines after a duplicate" {
    var memory: TableStorage.Buffer(220) = undefined;
    var decoder = Decoder.init(try TableStorage.initBuffer(&memory, 220));
    try decoder.table.setCapacity(220);
    try decoder.table.insert(":authority", "www.example.com");
    try decoder.table.insert(":path", "/sample/path");
    try decoder.table.insert("custom-key", "custom-value");
    // The duplicate of absolute 0 becomes absolute 3.
    try decoder.table.insert(":authority", "www.example.com");

    const block = [_]u8{ 0x05, 0x00, 0x80, 0xc1, 0x81 };
    var out: [8]Header = undefined;
    var bytes: [128]u8 = undefined;
    const fields = (try decoder.decode(&block, &out, &bytes)).fields.headers;

    try testing.expectEqual(@as(usize, 3), fields.items.len);
    try testing.expectEqualStrings(":authority", fields.items[0].name);
    try testing.expectEqualStrings("www.example.com", fields.items[0].value);
    try testing.expectEqualStrings(":path", fields.items[1].name);
    try testing.expectEqualStrings("/", fields.items[1].value);
    try testing.expectEqualStrings("custom-key", fields.items[2].name);
    try testing.expectEqualStrings("custom-value", fields.items[2].value);
}

test "a section ahead of the table is blocked and changes nothing" {
    var memory: TableStorage.Buffer(220) = undefined;
    var decoder = Decoder.init(try TableStorage.initBuffer(&memory, 220));

    // MaxEntries = 6, so Required Insert Count 1 encodes as 2.
    const block = [_]u8{ 0x02, 0x00 };
    var out: [8]Header = undefined;
    var bytes: [128]u8 = undefined;
    const result = try decoder.decode(&block, &out, &bytes);

    try testing.expectEqual(@as(u64, 1), result.blocked.required_insert_count);
    try testing.expectEqual(@as(u64, 1), result.blocked.base);
    try testing.expectEqual(@as(u64, 0), decoder.table.insert_count);
}

fn decodeOne(
    decoder: *Decoder,
    block: []const u8,
    required_insert_count: u64,
    base: u64,
    bytes: []u8,
    used: *usize,
) !Header {
    var cursor = Cursor.init(block);
    used.* = 0;
    return (try decoder.decodeFieldLine(
        &cursor,
        required_insert_count,
        base,
        bytes,
        used,
    )).header;
}

test "the five field-line representations decode" {
    var memory: TableStorage.Buffer(220) = undefined;
    var decoder = Decoder.init(try TableStorage.initBuffer(&memory, 220));
    try decoder.table.setCapacity(220);
    try decoder.table.insert("x-name", "x-value"); // absolute 0
    try decoder.table.insert("y-name", "y-value"); // absolute 1

    var bytes: [256]u8 = undefined;
    var used: usize = 0;

    // Indexed static: :path = / (static 1).
    const indexed_static = try decodeOne(&decoder, &.{0xc1}, 0, 1, &bytes, &used);
    try testing.expectEqualStrings(":path", indexed_static.name);
    try testing.expectEqualStrings("/", indexed_static.value);

    // Indexed dynamic relative: Base 2, relative 0 is absolute 1.
    const indexed_dynamic = try decodeOne(&decoder, &.{0x80}, 2, 2, &bytes, &used);
    try testing.expectEqualStrings("y-name", indexed_dynamic.name);
    try testing.expectEqualStrings("y-value", indexed_dynamic.value);

    // Indexed post-base: Base 1, post-base 0 is absolute 1.
    const post = try decodeOne(&decoder, &.{0x10}, 2, 1, &bytes, &used);
    try testing.expectEqualStrings("y-name", post.name);

    // Literal with a static name reference: :path = GET.
    const literal_static = try decodeOne(
        &decoder,
        &.{ 0x51, 0x03, 'G', 'E', 'T' },
        0,
        1,
        &bytes,
        &used,
    );
    try testing.expectEqualStrings(":path", literal_static.name);
    try testing.expectEqualStrings("GET", literal_static.value);

    // Literal with a post-base name reference: Base 0, post-base 1 is
    // absolute 1.
    const literal_post = try decodeOne(
        &decoder,
        &.{ 0x01, 0x01, 'v' },
        2,
        0,
        &bytes,
        &used,
    );
    try testing.expectEqualStrings("y-name", literal_post.name);
    try testing.expectEqualStrings("v", literal_post.value);

    // Literal with a literal name and value.
    const literal_name = try decodeOne(
        &decoder,
        &.{ 0x24, 'n', 'a', 'm', 'e', 0x01, 'v' },
        0,
        0,
        &bytes,
        &used,
    );
    try testing.expectEqualStrings("name", literal_name.name);
    try testing.expectEqualStrings("v", literal_name.value);
}

test "the N bit reaches decodeFlags" {
    var memory: TableStorage.Buffer(220) = undefined;
    var decoder = Decoder.init(try TableStorage.initBuffer(&memory, 220));

    // Literal with a literal name, N=1: 001 N H len=1, "a", value "b".
    const block = [_]u8{ 0x00, 0x00, 0x31, 'a', 0x01, 'b' };
    var out: [4]Header = undefined;
    var bytes: [32]u8 = undefined;
    var flags: [4]bool = undefined;
    const fields = (try decoder.decodeFlags(&block, &out, &bytes, &flags)).fields.headers;

    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expect(flags[0]);
}

test "an impossible Required Insert Count is InvalidPrefix" {
    var memory: TableStorage.Buffer(220) = undefined;
    var decoder = Decoder.init(try TableStorage.initBuffer(&memory, 220));

    // MaxEntries = 6, FullRange = 12; 13 cannot be produced.
    const block = [_]u8{ 0x0d, 0x00 };
    var out: [4]Header = undefined;
    var bytes: [32]u8 = undefined;
    try testing.expectError(error.InvalidPrefix, decoder.decode(&block, &out, &bytes));
}

test "a negative Base below zero is InvalidBase" {
    var memory: TableStorage.Buffer(220) = undefined;
    var decoder = Decoder.init(try TableStorage.initBuffer(&memory, 220));

    // Required Insert Count 0, sign 1, Delta Base 0.
    const block = [_]u8{ 0x00, 0x80 };
    var out: [4]Header = undefined;
    var bytes: [32]u8 = undefined;
    try testing.expectError(error.InvalidBase, decoder.decode(&block, &out, &bytes));
}

test "a reference to a missing entry is InvalidIndex" {
    var memory: TableStorage.Buffer(220) = undefined;
    var decoder = Decoder.init(try TableStorage.initBuffer(&memory, 220));

    // Indexed static 99 does not exist.
    const static_block = [_]u8{ 0x00, 0x00, 0xff, 0x24 };
    var out: [4]Header = undefined;
    var bytes: [32]u8 = undefined;
    try testing.expectError(error.InvalidIndex, decoder.decode(&static_block, &out, &bytes));

    // Indexed dynamic relative 0 with an empty table.
    const dynamic_block = [_]u8{ 0x00, 0x00, 0x80 };
    try testing.expectError(error.InvalidIndex, decoder.decode(&dynamic_block, &out, &bytes));
}

test "a dynamic reference above the Required Insert Count is InvalidIndex" {
    var memory: TableStorage.Buffer(220) = undefined;
    var decoder = Decoder.init(try TableStorage.initBuffer(&memory, 220));
    try decoder.table.setCapacity(220);
    try decoder.table.insert("x-name", "x-value"); // absolute 0
    try decoder.table.insert("y-name", "y-value"); // absolute 1

    var out: [4]Header = undefined;
    var bytes: [64]u8 = undefined;

    // Required Insert Count 0, Base 1, relative 0 reaches absolute 0, which
    // the count does not cover.
    const relative = [_]u8{ 0x00, 0x01, 0x80 };
    try testing.expectError(error.InvalidIndex, decoder.decode(&relative, &out, &bytes));

    // Required Insert Count 1, Base 1, post-base 0 reaches absolute 1, which
    // the count does not cover either.
    const post = [_]u8{ 0x02, 0x00, 0x10 };
    try testing.expectError(error.InvalidIndex, decoder.decode(&post, &out, &bytes));
}

test "a field larger than the output is NoSpace" {
    var memory: TableStorage.Buffer(220) = undefined;
    var decoder = Decoder.init(try TableStorage.initBuffer(&memory, 220));

    const block = [_]u8{ 0x00, 0x00, 0x20, 0x05, 'n', 'a', 'm', 'e', 'v' };
    var out: [4]Header = undefined;
    var bytes: [4]u8 = undefined;
    try testing.expectError(error.NoSpace, decoder.decode(&block, &out, &bytes));
}

test "fuzz the field-section decoder" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var memory: TableStorage.Buffer(256) = undefined;
            var decoder = Decoder.init(try TableStorage.initBuffer(&memory, 256));
            decoder.table.setCapacity(256) catch unreachable;

            var input: [128]u8 = undefined;
            const block = input[0..smith.slice(&input)];

            var out: [32]Header = undefined;
            var bytes: [1024]u8 = undefined;
            const result = decoder.decode(block, &out, &bytes) catch |err| {
                try testing.expect(err == error.Truncated or
                    err == error.NoSpace or
                    err == error.InvalidHuffman or
                    err == error.InvalidLength or
                    err == error.InvalidPrefix or
                    err == error.InvalidBase or
                    err == error.InvalidIndex);
                return;
            };
            _ = result;
        }
    }.run, .{
        .corpus = &.{
            "",
            "\x00\x00",
            "\x00\x00\xc1",
            "\x02\x00",
            "\x03\x81\x10\x11",
        },
    });
}

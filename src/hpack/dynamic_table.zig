//! The HPACK dynamic table (RFC 7541 §2.3.2, §4).
//!
//! One instance per connection, per direction. The table itself owns nothing:
//! `TableStorage` holds the byte arena, the entry records, and the hash array,
//! and the table reads them. `insert` accounts entries as RFC 7541 §4.1
//! requires (name + value + 32) and evicts from the oldest end (§4.4).
//!
//! `get`, `find`, and `findName` index from the newest entry, 0, the order the
//! wire uses. The ring's `head` is the newest entry, so the live hashes run
//! newest to oldest from `head`; that lets `mem.findScalarPos` return the
//! newest match without a reverse scan.
//!
//! New entries are copied into the low end of the byte arena, below every live
//! entry; eviction drops the high end. That leaves gaps the arena reclaims by
//! compacting when an entry no longer fits below the live data. Compaction
//! moves live entries, so a slice returned by `get` is valid only until the
//! next `insert` or `setMaxSize`. A decoder that hands fields to its caller
//! copies them out for exactly this reason.

const std = @import("std");
const testing = std.testing;
const math = std.math;
const assert = std.debug.assert;
const mem = std.mem;

const Header = @import("../header.zig").Header;
const TableStorage = @import("TableStorage.zig");
const Slot = TableStorage.Slot;

/// The per-entry accounting overhead (RFC 7541 §4.1).
pub const entry_overhead = TableStorage.entry_overhead;

pub const DynamicTable = struct {
    /// Entry names and values. Borrowed from `TableStorage`.
    bytes: []u8,
    /// One record per slot, in a ring.
    slots: []Slot,
    /// One name hash per slot, contiguous for the lookup scan.
    hashes: []u32,
    /// Ring index of the newest entry.
    head: usize,
    count: usize,
    /// Sum of every live entry's size, overhead included (§4.1).
    size: usize,
    /// The current maximum, from the protocol settings and size updates.
    max_size: usize,
    /// Bottom of the used region. Everything below it is free.
    top: usize,

    pub fn init(storage: TableStorage) DynamicTable {
        const views = storage.views();
        return .{
            .bytes = views.bytes,
            .slots = views.slots,
            .hashes = views.hashes,
            .head = 0,
            .count = 0,
            .size = 0,
            .max_size = views.bytes.len,
            .top = views.bytes.len,
        };
    }

    /// The bytes the live entries occupy, which is their accounting size less
    /// the fixed overhead.
    pub fn used(self: *const DynamicTable) usize {
        return self.size - entry_overhead * self.count;
    }

    pub fn isEmpty(self: *const DynamicTable) bool {
        return self.count == 0;
    }

    /// The entry at a dynamic index: 0 is the most recently inserted.
    /// Returns null past the oldest entry.
    pub fn get(self: *const DynamicTable, index: usize) ?Header {
        if (index >= self.count) return null;
        return self.headerAt(self.slotOf(index));
    }

    /// The position of the newest entry whose name and value both match, or
    /// null. A position is 0 for the newest entry, the same basis as `get`.
    pub fn find(self: *const DynamicTable, header: Header) ?usize {
        return self.search(hashName(header.name), header.name, header.value);
    }

    /// The position of the newest entry with this name, or null.
    pub fn findName(self: *const DynamicTable, name: []const u8) ?usize {
        return self.search(hashName(name), name, null);
    }

    /// Add an entry and evict as §4.4 requires. An entry larger than the
    /// maximum empties the table and is not added; that is not an error.
    ///
    /// `name` and `value` must not point into `bytes`; a decoder copies the
    /// strings it decodes before calling this (§4.4 warns about the case).
    pub fn insert(self: *DynamicTable, name: []const u8, value: []const u8) void {
        assert(!self.overlaps(name));
        assert(!self.overlaps(value));

        const bytes = name.len + value.len;
        const entry_size = bytes + entry_overhead;

        // An entry above the maximum empties the table and is not added. The
        // strings need not fit the arena; they are never copied.
        if (entry_size > self.max_size) {
            self.clear();
            return;
        }
        assert(bytes <= self.bytes.len);
        while (self.size > self.max_size - entry_size) self.evictOldest();

        if (self.top < bytes) self.compact();
        self.top -= bytes;

        const name_off: u32 = @intCast(self.top);
        @memcpy(self.bytes[self.top..][0..name.len], name);
        const value_off: u32 = @intCast(self.top + name.len);
        @memcpy(self.bytes[@intCast(value_off)..][0..value.len], value);

        // The newest entry goes just before `head`; `head` then points at it.
        const slot = if (self.head == 0) self.hashes.len - 1 else self.head - 1;
        self.slots[slot] = .{
            .name_off = name_off,
            .name_len = @intCast(name.len),
            .value_off = value_off,
            .value_len = @intCast(value.len),
        };
        self.hashes[slot] = hashName(name);
        self.head = slot;
        self.count += 1;
        self.size += entry_size;
    }

    /// Change the maximum size, evicting until the table fits (RFC 7541
    /// §4.3). A size above the storage is a decoding error for the caller.
    pub fn setMaxSize(self: *DynamicTable, new_max: usize) error{TooLarge}!void {
        if (new_max > self.bytes.len) return error.TooLarge;
        self.max_size = new_max;
        while (self.size > new_max) self.evictOldest();
    }

    pub fn clear(self: *DynamicTable) void {
        self.head = 0;
        self.count = 0;
        self.size = 0;
        self.top = self.bytes.len;
    }

    /// Search the live ring newest-first. The two segments are the part from
    /// `head` to the end and, after a wrap, the part from 0 to the live end.
    fn search(
        self: *const DynamicTable,
        hash: u32,
        name: []const u8,
        value: ?[]const u8,
    ) ?usize {
        if (self.count == 0) return null;

        const end = self.head + self.count;
        if (end <= self.hashes.len) {
            return self.searchSegment(self.hashes[self.head..end], self.head, hash, name, value);
        }
        if (self.searchSegment(self.hashes[self.head..], self.head, hash, name, value)) |position| {
            return position;
        }
        return self.searchSegment(self.hashes[0 .. end - self.hashes.len], 0, hash, name, value);
    }

    /// `mem.findScalarPos` is vectorized, but for a handful of entries its
    /// setup costs more than a scalar pass over the same contiguous hashes.
    const vector_scan_min = 32;

    inline fn searchSegment(
        self: *const DynamicTable,
        segment: []const u32,
        ring_start: usize,
        hash: u32,
        name: []const u8,
        value: ?[]const u8,
    ) ?usize {
        if (segment.len < vector_scan_min) {
            for (segment, 0..) |candidate, at| {
                if (candidate != hash) continue;
                if (self.matchesAt(ring_start + at, name, value)) {
                    return self.positionOf(ring_start + at);
                }
            }
            return null;
        }

        var from: usize = 0;
        while (mem.findScalarPos(u32, segment, from, hash)) |at| {
            const ring = ring_start + at;
            if (self.matchesAt(ring, name, value)) return self.positionOf(ring);
            from = at + 1;
        }
        return null;
    }

    inline fn matchesAt(
        self: *const DynamicTable,
        ring: usize,
        name: []const u8,
        value: ?[]const u8,
    ) bool {
        if (!mem.eql(u8, self.nameAt(ring), name)) return false;
        if (value) |want| return mem.eql(u8, self.valueAt(ring), want);
        return true;
    }

    /// The physical slot of the entry `position` places from the newest.
    fn slotOf(self: *const DynamicTable, position: usize) usize {
        assert(self.hashes.len != 0);
        assert(position < self.hashes.len);
        var at = self.head + position;
        if (at >= self.hashes.len) at -= self.hashes.len;
        return at;
    }

    /// The distance of a ring slot from `head`, which is its dynamic position.
    fn positionOf(self: *const DynamicTable, ring: usize) usize {
        return if (ring >= self.head) ring - self.head else ring + self.hashes.len - self.head;
    }

    fn evictOldest(self: *DynamicTable) void {
        assert(self.count != 0);
        const slot = self.slotOf(self.count - 1);
        self.size -= @as(usize, self.slots[slot].name_len) +
            self.slots[slot].value_len + entry_overhead;

        self.count -= 1;
        if (self.count == 0) {
            self.head = 0;
            self.top = self.bytes.len;
        }
    }

    /// Pack the live entries against the end of the arena, reclaiming the
    /// gaps eviction left above them.
    fn compact(self: *DynamicTable) void {
        const live = self.used();
        const new_top = self.bytes.len - live;
        if (new_top == self.top) return;

        const dst = self.bytes[new_top..][0..live];
        const src = self.bytes[self.top..][0..live];
        @memmove(dst, src);

        const delta: u32 = @intCast(new_top - self.top);
        for (0..self.count) |position| {
            const slot = self.slotOf(position);
            self.slots[slot].name_off += delta;
            self.slots[slot].value_off += delta;
        }
        self.top = new_top;
    }

    fn headerAt(self: *const DynamicTable, slot: usize) Header {
        return .{ .name = self.nameAt(slot), .value = self.valueAt(slot) };
    }

    fn nameAt(self: *const DynamicTable, slot: usize) []const u8 {
        const record = self.slots[slot];
        return self.bytes[@intCast(record.name_off)..][0..@intCast(record.name_len)];
    }

    fn valueAt(self: *const DynamicTable, slot: usize) []const u8 {
        const record = self.slots[slot];
        return self.bytes[@intCast(record.value_off)..][0..@intCast(record.value_len)];
    }

    fn overlaps(self: *const DynamicTable, bytes: []const u8) bool {
        if (bytes.len == 0 or self.bytes.len == 0) return false;
        const outer = @intFromPtr(self.bytes.ptr);
        const inner = @intFromPtr(bytes.ptr);
        return inner >= outer and inner + bytes.len <= outer + self.bytes.len;
    }
};

/// The name hash cached in a slot. Any collision falls through to `mem.eql`.
fn hashName(name: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(0, name));
}

/// A table over fixed caller storage. Included so tests and callers read the
/// same shape; the decoder owns one of these.
fn arena(
    comptime size: usize,
    memory: *TableStorage.Buffer(size),
) !DynamicTable {
    return .init(try .initBuffer(memory, size));
}

test "empty: no entries, no size" {
    var memory: TableStorage.Buffer(64) = undefined;
    const table = try arena(64, &memory);

    try testing.expect(table.isEmpty());
    try testing.expectEqual(0, table.count);
    try testing.expectEqual(0, table.size);
    try testing.expectEqual(0, table.used());
    try testing.expect(table.get(0) == null);
}

test "insert: newest is index 0, and the size carries the 32-byte overhead" {
    var memory: TableStorage.Buffer(512) = undefined;
    var table = try arena(512, &memory);

    table.insert("a", "1");
    table.insert("bb", "22");

    try testing.expectEqual(@as(usize, 2), table.count);
    // 1 + 1 + 32, then 2 + 2 + 32.
    try testing.expectEqual(@as(usize, 70), table.size);
    try testing.expectEqual(@as(usize, 6), table.used());

    try testing.expectEqualStrings("bb", table.get(0).?.name);
    try testing.expectEqualStrings("22", table.get(0).?.value);
    try testing.expectEqualStrings("a", table.get(1).?.name);
    try testing.expectEqualStrings("1", table.get(1).?.value);
    try testing.expect(table.get(2) == null);
}

test "insert: the oldest entry evicts to make room (RFC 7541 §4.4)" {
    // One name octet plus the 32-byte overhead is 33 an entry; ten fill 330.
    var memory: TableStorage.Buffer(330) = undefined;
    var table = try arena(330, &memory);

    for (0..10) |i| {
        var name: [1]u8 = .{@intCast('a' + i)};
        table.insert(&name, "");
    }
    try testing.expectEqual(@as(usize, 10), table.count);
    try testing.expectEqual(@as(usize, 330), table.size);

    // The eleventh pushes out the first.
    table.insert("k", "");
    try testing.expectEqual(@as(usize, 10), table.count);
    try testing.expectEqual(@as(usize, 330), table.size);
    try testing.expectEqualStrings("k", table.get(0).?.name);
    try testing.expectEqualStrings("b", table.get(9).?.name);
    try testing.expect(table.get(10) == null);
}

test "insert: an entry larger than the maximum empties the table" {
    var memory: TableStorage.Buffer(128) = undefined;
    var table = try arena(128, &memory);

    table.insert("a", "b");
    try testing.expectEqual(@as(usize, 1), table.count);

    // 160 bytes of name and value: entry size 192, above the 128 maximum.
    var big: [160]u8 = undefined;
    @memset(&big, 'x');
    table.insert(&big, "");
    try testing.expect(table.isEmpty());
    try testing.expectEqual(0, table.size);
}

test "find and findName: newest first, and an eviction forgets" {
    var memory: TableStorage.Buffer(128) = undefined;
    var table = try arena(128, &memory);

    table.insert("a", "1");
    table.insert("b", "2");
    table.insert("a", "3");

    try testing.expectEqual(@as(?usize, 0), table.find(.{ .name = "a", .value = "3" }));
    try testing.expectEqual(@as(?usize, 2), table.find(.{ .name = "a", .value = "1" }));
    try testing.expectEqual(@as(?usize, 1), table.find(.{ .name = "b", .value = "2" }));
    try testing.expect(table.find(.{ .name = "a", .value = "9" }) == null);
    try testing.expectEqual(@as(?usize, 0), table.findName("a"));
    try testing.expectEqual(@as(?usize, 1), table.findName("b"));
    try testing.expect(table.findName("c") == null);

    // Three 34-byte entries fill 102 of 128; the fourth evicts the oldest.
    table.insert("c", "4");
    try testing.expect(table.find(.{ .name = "a", .value = "1" }) == null);
    try testing.expectEqual(@as(?usize, 1), table.findName("a"));
    try testing.expectEqual(@as(?usize, 0), table.findName("c"));
    try testing.expectEqual(@as(?usize, 0), table.find(.{ .name = "c", .value = "4" }));
}

test "setMaxSize: evicts down to the new maximum and refuses growth past the arena" {
    var memory: TableStorage.Buffer(128) = undefined;
    var table = try arena(128, &memory);

    table.insert("aa", "bb"); // 36
    table.insert("cc", "dd"); // 36
    try testing.expectEqual(@as(usize, 72), table.size);

    try table.setMaxSize(40);
    try testing.expectEqual(@as(usize, 1), table.count);
    try testing.expectEqualStrings("cc", table.get(0).?.name);

    try table.setMaxSize(0);
    try testing.expect(table.isEmpty());

    try table.setMaxSize(128);
    try testing.expectError(error.TooLarge, table.setMaxSize(129));
}

test "the slot ring wraps and indexing stays newest first" {
    var memory: TableStorage.Buffer(128) = undefined;
    var table = try arena(128, &memory);

    // 34 bytes per entry: three fit, four evict.
    var i: u8 = 0;
    while (i < 100) : (i += 1) {
        var name: [1]u8 = .{@intCast('a' + i % 26)};
        var value: [1]u8 = .{i};
        table.insert(&name, &value);
        try testing.expect(table.count <= 3);
        try testing.expectEqual(@as(u8, i), table.get(0).?.value[0]);
    }
    try testing.expectEqual(@as(usize, 3), table.count);
}

test "compaction reclaims the gaps eviction leaves, keeping entries intact" {
    // Small entries against a large arena: the table always holds about
    // thirty, so it never empties and the bottom of the arena must be reused.
    var memory: TableStorage.Buffer(1024) = undefined;
    var table = try arena(1024, &memory);

    var i: u32 = 0;
    while (i < 600) : (i += 1) {
        var name: [1]u8 = .{'k'};
        var value: [4]u8 = undefined;
        mem.writeInt(u32, &value, i, .little);
        table.insert(&name, &value);

        const newest = table.get(0).?;
        try testing.expectEqual(i, mem.readInt(u32, newest.value[0..4], .little));
        try testing.expectEqual(@min(@as(usize, i) + 1, 1024 / 37), table.count);

        // Compaction moves the entry bytes; the cached hash and offsets follow.
        try testing.expectEqual(@as(?usize, 0), table.findName("k"));
        try testing.expectEqual(
            @as(?usize, 0),
            table.find(.{ .name = "k", .value = newest.value }),
        );
    }
    try testing.expectEqual(@as(usize, 1024 / 37), table.count);
    try testing.expectEqual(1024 / 37 * 5, table.used());
}

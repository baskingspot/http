//! The QPACK dynamic table (RFC 9204 §3.2).
//!
//! One instance per connection, per direction. The table owns nothing:
//! `TableStorage` holds the byte arena, the entry records, and the hash array.
//! `insert` accounts entries as §3.2.1 requires (name + value + 32) and evicts
//! from the oldest end to fit the current capacity.
//!
//! The index space is QPACK's, not HPACK's. Entries have absolute indices that
//! start at zero and never rewind: `insert_count` is the next absolute index,
//! the oldest live entry is `insert_count - count`, and a field section reaches
//! an entry by absolute index, by relative index from Base, or by post-base
//! index (RFC 9204 §3.2.4–3.2.6). A capacity change evicts entries but leaves
//! `insert_count` alone.
//!
//! The initial capacity is zero (§3.2.2). The encoder must send Set Dynamic
//! Table Capacity before it inserts. An entry larger than the capacity is
//! `error.EntryTooLarge`, which the caller maps to QPACK_ENCODER_STREAM_ERROR;
//! the table is left as it was.
//!
//! Compaction moves live entries, so a slice returned by `get` is valid only
//! until the next `insert` or `setCapacity`. The decoder copies fields out.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const mem = std.mem;

const Header = @import("../header.zig").Header;
const TableStorage = @import("../TableStorage.zig");
const Slot = TableStorage.Slot;

/// The per-entry accounting overhead (RFC 9204 §3.2.1).
pub const entry_overhead = TableStorage.entry_overhead;

pub const Error = error{
    /// The entry is larger than the current capacity (§3.2.2).
    EntryTooLarge,
    /// The capacity is above the decoder's SETTINGS limit (§3.2.3).
    CapacityTooLarge,
};

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
    /// Sum of every live entry's size, overhead included.
    size: usize,
    /// The capacity the encoder set, from zero up to `max_capacity`.
    capacity: usize,
    /// The largest capacity this endpoint advertised in SETTINGS.
    max_capacity: usize,
    /// Bottom of the used region. Everything below it is free.
    top: usize,
    /// The next absolute index. Never decreases.
    insert_count: u64,

    pub fn init(storage: TableStorage) DynamicTable {
        const views = storage.views();
        return .{
            .bytes = views.bytes,
            .slots = views.slots,
            .hashes = views.hashes,
            .head = 0,
            .count = 0,
            .size = 0,
            .capacity = 0,
            .max_capacity = views.bytes.len,
            .top = views.bytes.len,
            .insert_count = 0,
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

    /// The absolute index of the oldest live entry. Equal to `insert_count`
    /// when the table is empty.
    pub fn dropped(self: *const DynamicTable) u64 {
        return self.insert_count - self.count;
    }

    /// The entry at an absolute index, or null when it is not live.
    pub fn get(self: *const DynamicTable, absolute: u64) ?Header {
        if (absolute >= self.insert_count) return null;
        if (absolute < self.dropped()) return null;
        const position: usize = @intCast(self.insert_count - 1 - absolute);
        return self.headerAt(self.slotOf(position));
    }

    /// The entry at a relative index from `base`: 0 is `base - 1`
    /// (RFC 9204 §3.2.5).
    pub fn getRelative(self: *const DynamicTable, relative: u64, base: u64) ?Header {
        if (relative >= base) return null;
        return self.get(base - 1 - relative);
    }

    /// The entry at a post-base index from `base`: 0 is `base`
    /// (RFC 9204 §3.2.6).
    pub fn getPostBase(self: *const DynamicTable, post: u64, base: u64) ?Header {
        const absolute = base + post;
        if (absolute < base) return null;
        return self.get(absolute);
    }

    /// The absolute index of the newest entry whose name and value both match.
    pub fn find(self: *const DynamicTable, header: Header) ?u64 {
        const position = self.search(hashName(header.name), header.name, header.value) orelse
            return null;
        return self.absoluteOf(position);
    }

    /// The absolute index of the newest entry with this name.
    pub fn findName(self: *const DynamicTable, name: []const u8) ?u64 {
        const position = self.search(hashName(name), name, null) orelse return null;
        return self.absoluteOf(position);
    }

    /// Add an entry, evicting the oldest until it fits. An entry larger than
    /// the current capacity is `error.EntryTooLarge` and changes nothing.
    ///
    /// `name` and `value` must not point into `bytes`; the caller copies a
    /// referenced name before calling this (§3.2.2 warns about the case).
    pub fn insert(self: *DynamicTable, name: []const u8, value: []const u8) Error!void {
        assert(!self.overlaps(name));
        assert(!self.overlaps(value));

        const bytes = name.len + value.len;
        const entry_size = bytes + entry_overhead;
        if (entry_size > self.capacity) return error.EntryTooLarge;
        assert(bytes <= self.bytes.len);

        while (self.size > self.capacity - entry_size) self.evictOldest();

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
        self.insert_count += 1;
    }

    /// Set the table capacity, evicting down to it (§3.2.2). A capacity above
    /// the decoder's SETTINGS limit is `error.CapacityTooLarge`.
    pub fn setCapacity(self: *DynamicTable, new_capacity: usize) Error!void {
        if (new_capacity > self.max_capacity) return error.CapacityTooLarge;
        self.capacity = new_capacity;
        while (self.size > new_capacity) self.evictOldest();
    }

    pub fn clear(self: *DynamicTable) void {
        self.head = 0;
        self.count = 0;
        self.size = 0;
        self.top = self.bytes.len;
    }

    fn absoluteOf(self: *const DynamicTable, position: usize) u64 {
        assert(position < self.count);
        return self.insert_count - 1 - position;
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

fn arena(comptime size: usize, memory: *TableStorage.Buffer(size)) !DynamicTable {
    return .init(try .initBuffer(memory, size));
}

test "the initial capacity is zero (RFC 9204 §3.2.2)" {
    var memory: TableStorage.Buffer(220) = undefined;
    var table = try arena(220, &memory);

    try testing.expect(table.isEmpty());
    try testing.expectEqual(0, table.capacity);
    try testing.expectEqual(220, table.max_capacity);
    try testing.expectError(error.EntryTooLarge, table.insert("a", "b"));
    try testing.expectEqual(@as(u64, 0), table.insert_count);
}

test "RFC 9204 Appendix B.2, the two inserts and their accounting" {
    var memory: TableStorage.Buffer(220) = undefined;
    var table = try arena(220, &memory);

    try table.setCapacity(220);
    try table.insert(":authority", "www.example.com");
    try table.insert(":path", "/sample/path");

    try testing.expectEqual(@as(u64, 2), table.insert_count);
    try testing.expectEqual(@as(u64, 0), table.dropped());
    // 10 + 15 + 32, then 5 + 12 + 32.
    try testing.expectEqual(@as(usize, 106), table.size);
    try testing.expectEqual(@as(usize, 42), table.used());

    try testing.expectEqualStrings(":authority", table.get(0).?.name);
    try testing.expectEqualStrings("www.example.com", table.get(0).?.value);
    try testing.expectEqualStrings(":path", table.get(1).?.name);
    try testing.expectEqualStrings("/sample/path", table.get(1).?.value);
    try testing.expect(table.get(2) == null);
}

test "relative and post-base indices resolve against Base (RFC 9204 §3.2.5, §3.2.6)" {
    var memory: TableStorage.Buffer(220) = undefined;
    var table = try arena(220, &memory);
    try table.setCapacity(220);
    try table.insert(":authority", "www.example.com"); // absolute 0
    try table.insert(":path", "/sample/path"); // absolute 1

    // Base = 2: relative 0 is absolute 1, relative 1 is absolute 0.
    try testing.expectEqualStrings(":path", table.getRelative(0, 2).?.name);
    try testing.expectEqualStrings(":authority", table.getRelative(1, 2).?.name);
    try testing.expect(table.getRelative(2, 2) == null);
    try testing.expect(table.getRelative(0, 0) == null);

    // Base = 0: post-base 0 is absolute 0.
    try testing.expectEqualStrings(":authority", table.getPostBase(0, 0).?.name);
    try testing.expectEqualStrings(":path", table.getPostBase(1, 0).?.name);
    try testing.expect(table.getPostBase(2, 0) == null);
}

test "eviction advances dropped but not insert_count" {
    // 34 bytes per one-byte name; a capacity of 68 holds two.
    var memory: TableStorage.Buffer(68) = undefined;
    var table = try arena(68, &memory);
    try table.setCapacity(68);

    try table.insert("a", "");
    try table.insert("b", "");
    try table.insert("c", "");

    try testing.expectEqual(@as(u64, 3), table.insert_count);
    try testing.expectEqual(@as(u64, 1), table.dropped());
    try testing.expect(table.get(0) == null);
    try testing.expectEqualStrings("b", table.get(1).?.name);
    try testing.expectEqualStrings("c", table.get(2).?.name);
    try testing.expectEqual(@as(?u64, 2), table.findName("c"));
    try testing.expect(table.findName("a") == null);
}

test "a capacity change evicts down to the new limit and never rewinds indices" {
    var memory: TableStorage.Buffer(220) = undefined;
    var table = try arena(220, &memory);
    try table.setCapacity(220);
    try table.insert(":authority", "www.example.com");
    try table.insert(":path", "/sample/path");

    try table.setCapacity(0);
    try testing.expect(table.isEmpty());
    try testing.expectEqual(@as(u64, 2), table.insert_count);
    try testing.expectEqual(@as(u64, 2), table.dropped());

    try table.setCapacity(220);
    try table.insert("x", "y");
    try testing.expectEqual(@as(u64, 3), table.insert_count);
    try testing.expectEqualStrings("x", table.get(2).?.name);
    try testing.expect(table.get(0) == null);
    try testing.expect(table.get(1) == null);

    try testing.expectError(error.CapacityTooLarge, table.setCapacity(221));
}

test "an entry larger than the capacity is an error and changes nothing" {
    var memory: TableStorage.Buffer(128) = undefined;
    var table = try arena(128, &memory);
    try table.setCapacity(128);
    try table.insert("a", "b");
    try testing.expectEqual(@as(usize, 1), table.count);

    var big: [160]u8 = undefined;
    @memset(&big, 'x');
    try testing.expectError(error.EntryTooLarge, table.insert(&big, ""));
    try testing.expectEqual(@as(usize, 1), table.count);
    try testing.expectEqual(@as(u64, 1), table.insert_count);
    try testing.expectEqualStrings("a", table.get(0).?.name);
}

test "the slot ring wraps and absolute indices stay correct" {
    var memory: TableStorage.Buffer(128) = undefined;
    var table = try arena(128, &memory);
    try table.setCapacity(128);

    var i: u8 = 0;
    while (i < 100) : (i += 1) {
        var name: [1]u8 = .{@intCast('a' + i % 26)};
        var value: [1]u8 = .{i};
        try table.insert(&name, &value);

        try testing.expectEqual(@as(u64, i + 1), table.insert_count);
        try testing.expectEqual(i, table.get(i).?.value[0]);
        try testing.expectEqual(@as(?u64, i), table.findName(&name));
        try testing.expect(table.count <= 3);
    }
    try testing.expectEqual(@as(usize, 3), table.count);
    try testing.expectEqual(@as(u64, 100), table.insert_count);
    try testing.expectEqual(@as(u64, 97), table.dropped());
    try testing.expectEqual(@as(?u64, 99), table.findName("v"));
}

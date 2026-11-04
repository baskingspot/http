//! The HPACK dynamic table (RFC 7541 §2.3.2, §4).
//!
//! One instance per connection, per direction. It owns nothing: the caller
//! supplies the byte arena and the slot metadata, sized from the table size
//! this endpoint advertises. `insert` accounts entries as RFC 7541 §4.1
//! requires (name + value + 32) and evicts from the oldest end (§4.4).
//!
//! New entries are copied into the low end of the arena, below every live
//! entry; eviction drops the high end. That leaves gaps the arena reclaims by
//! compacting when an entry no longer fits below the live data. Compaction
//! moves live entries, so a slice returned by `get` is valid only until the
//! next `insert` or `setMaxSize`. A decoder that hands fields to its caller
//! copies them out for exactly this reason.
//!
//! Slots need `arena.len / 32` entries: every entry costs at least 32 bytes of
//! accounting, so the table can never hold more.

const std = @import("std");
const testing = std.testing;
const math = std.math;
const assert = std.debug.assert;
const mem = std.mem;

const Header = @import("../header.zig").Header;

/// The per-entry accounting overhead (RFC 7541 §4.1).
pub const entry_overhead = 32;

/// Where one entry lives in the arena. Treat it as opaque: only the table
/// reads or writes these fields.
pub const Slot = struct {
    name_off: u32,
    name_len: u32,
    value_off: u32,
    value_len: u32,
};

pub const DynamicTable = struct {
    /// Caller-owned byte arena. Its length is the largest table size a size
    /// update can request.
    buf: []u8,
    /// Caller-owned metadata; `slotCount` values.
    slots: []Slot,
    /// Ring index of the oldest entry.
    head: usize = 0,
    count: usize = 0,
    /// Sum of every live entry's size, overhead included (§4.1).
    size: usize = 0,
    /// The current maximum, from the protocol settings and size updates.
    max_size: usize,
    /// Bottom of the used region. Everything below it is free.
    top: usize,

    /// The slots `arena` needs: one per 32 bytes of accounting.
    pub fn slotCount(arena_len: usize) usize {
        return arena_len / entry_overhead;
    }

    pub fn init(buf: []u8, slots: []Slot) DynamicTable {
        assert(buf.len <= math.maxInt(u32));
        assert(slots.len >= slotCount(buf.len));
        return .{ .buf = buf, .slots = slots, .max_size = buf.len, .top = buf.len };
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
        const slot = self.slots[self.slotOf(self.count - 1 - index)];
        return .{
            .name = self.buf[@intCast(slot.name_off)..][0..@intCast(slot.name_len)],
            .value = self.buf[@intCast(slot.value_off)..][0..@intCast(slot.value_len)],
        };
    }

    /// Add an entry and evict as §4.4 requires. An entry larger than the
    /// maximum empties the table and is not added; that is not an error.
    ///
    /// `name` and `value` must not point into `buf`; a decoder copies the
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
        assert(bytes <= self.buf.len);
        while (self.size > self.max_size - entry_size) self.evictOldest();

        if (self.top < bytes) self.compact();
        self.top -= bytes;

        const name_off: u32 = @intCast(self.top);
        @memcpy(self.buf[self.top..][0..name.len], name);
        const value_off: u32 = @intCast(self.top + name.len);
        @memcpy(self.buf[@intCast(value_off)..][0..value.len], value);

        const slot = &self.slots[self.slotOf(self.count)];
        slot.* = .{
            .name_off = name_off,
            .name_len = @intCast(name.len),
            .value_off = value_off,
            .value_len = @intCast(value.len),
        };
        self.count += 1;
        self.size += entry_size;
    }

    /// Change the maximum size, evicting until the table fits (RFC 7541
    /// §4.3). A size above the arena is a decoding error for the caller.
    pub fn setMaxSize(self: *DynamicTable, new_max: usize) error{TooLarge}!void {
        if (new_max > self.buf.len) return error.TooLarge;
        self.max_size = new_max;
        while (self.size > new_max) self.evictOldest();
    }

    pub fn clear(self: *DynamicTable) void {
        self.head = 0;
        self.count = 0;
        self.size = 0;
        self.top = self.buf.len;
    }

    /// The physical slot of the entry `position` places from the oldest.
    fn slotOf(self: *const DynamicTable, position: usize) usize {
        assert(self.slots.len != 0);
        assert(position < self.slots.len);
        var at = self.head + position;
        if (at >= self.slots.len) at -= self.slots.len;
        return at;
    }

    fn evictOldest(self: *DynamicTable) void {
        assert(self.count != 0);
        const slot = self.slots[self.slotOf(0)];
        self.size -= @as(usize, slot.name_len) + slot.value_len + entry_overhead;

        self.head += 1;
        if (self.head == self.slots.len) self.head = 0;
        self.count -= 1;
        if (self.count == 0) self.top = self.buf.len;
    }

    /// Pack the live entries against the end of the arena, reclaiming the
    /// gaps eviction left above them.
    fn compact(self: *DynamicTable) void {
        const live = self.used();
        const new_top = self.buf.len - live;
        if (new_top == self.top) return;

        const dst = self.buf[new_top..][0..live];
        const src = self.buf[self.top..][0..live];
        @memmove(dst, src);

        const delta: u32 = @intCast(new_top - self.top);
        for (0..self.count) |position| {
            const slot = &self.slots[self.slotOf(position)];
            slot.name_off += delta;
            slot.value_off += delta;
        }
        self.top = new_top;
    }

    fn overlaps(self: *const DynamicTable, bytes: []const u8) bool {
        if (bytes.len == 0 or self.buf.len == 0) return false;
        const outer = @intFromPtr(self.buf.ptr);
        const inner = @intFromPtr(bytes.ptr);
        return inner >= outer and inner + bytes.len <= outer + self.buf.len;
    }
};

/// A table over a fixed arena. Included so tests and callers read the same
/// shape; the decoder owns one of these.
fn arena(
    comptime size: usize,
    buf: *[size]u8,
    slots: *[DynamicTable.slotCount(size)]Slot,
) DynamicTable {
    return .init(buf, slots);
}

test "empty: no entries, no size" {
    var buf: [64]u8 = undefined;
    var slots: [DynamicTable.slotCount(64)]Slot = undefined;
    const table = arena(64, &buf, &slots);

    try testing.expect(table.isEmpty());
    try testing.expectEqual(0, table.count);
    try testing.expectEqual(0, table.size);
    try testing.expectEqual(0, table.used());
    try testing.expect(table.get(0) == null);
}

test "insert: newest is index 0, and the size carries the 32-byte overhead" {
    var buf: [512]u8 = undefined;
    var slots: [DynamicTable.slotCount(512)]Slot = undefined;
    var table = arena(512, &buf, &slots);

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
    // One name octet plus the 32-byte overhead is 33 a entry; ten fill 330.
    var buf: [330]u8 = undefined;
    var slots: [DynamicTable.slotCount(330)]Slot = undefined;
    var table = arena(330, &buf, &slots);

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
    var buf: [128]u8 = undefined;
    var slots: [DynamicTable.slotCount(128)]Slot = undefined;
    var table = arena(128, &buf, &slots);

    table.insert("a", "b");
    try testing.expectEqual(@as(usize, 1), table.count);

    // 160 bytes of name and value: entry size 192, above the 128 maximum.
    var big: [160]u8 = undefined;
    @memset(&big, 'x');
    table.insert(&big, "");
    try testing.expect(table.isEmpty());
    try testing.expectEqual(0, table.size);
}

test "setMaxSize: evicts down to the new maximum and refuses growth past the arena" {
    var buf: [128]u8 = undefined;
    var slots: [DynamicTable.slotCount(128)]Slot = undefined;
    var table = arena(128, &buf, &slots);

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
    var buf: [128]u8 = undefined;
    var slots: [DynamicTable.slotCount(128)]Slot = undefined;
    var table = arena(128, &buf, &slots);

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
    var buf: [1024]u8 = undefined;
    var slots: [DynamicTable.slotCount(1024)]Slot = undefined;
    var table = arena(1024, &buf, &slots);

    var i: u32 = 0;
    while (i < 600) : (i += 1) {
        var name: [1]u8 = .{'k'};
        var value: [4]u8 = undefined;
        mem.writeInt(u32, &value, i, .little);
        table.insert(&name, &value);

        const newest = table.get(0).?;
        try testing.expectEqual(i, mem.readInt(u32, newest.value[0..4], .little));
        try testing.expectEqual(@min(@as(usize, i) + 1, 1024 / 37), table.count);
    }
    try testing.expectEqual(@as(usize, 1024 / 37), table.count);
    try testing.expectEqual(1024 / 37 * 5, table.used());
}

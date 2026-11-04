//! The storage a dynamic table reads: one opaque byte blob.
//!
//! HPACK's table maximum is runtime (SETTINGS_HEADER_TABLE_SIZE), so the
//! storage is sized at runtime too. `init` allocates the blob; `initBuffer`
//! wraps a caller buffer for a stack or fixed-size server. `deinit` frees the
//! blob, so call it only for a storage from `init`: a caller that used
//! `initBuffer` frees its own memory, exactly as with `std.array_list.Aligned`.
//!
//! The blob is laid out as the byte arena, padding to the slot alignment, the
//! slot records, and the hashes. The blob's own alignment is not trusted: the
//! views start at the next `@alignOf(Slot)` boundary, and `bytesNeeded`
//! includes that slack. Nothing else is stored, so a table is one slice and one
//! `u32` rather than a set of fat pointers.
//!
//! The records stay an array of structs and the hashes are split out: the
//! lookup scans the contiguous hashes, then reads one 16-byte record on a hit.
//! Putting the hash in the record makes the scan stride over 20 bytes to read 4.

const std = @import("std");
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;

const TableStorage = @This();

/// The per-entry accounting overhead (RFC 7541 §4.1).
pub const entry_overhead: usize = 32;

/// Where one entry lives in the byte region.
pub const Slot = struct {
    name_off: u32,
    name_len: u32,
    value_off: u32,
    value_len: u32,
};

/// The whole storage: arena, records, and hashes, in one blob.
memory: []u8,
/// The length of the byte arena at the front of the blob.
max_size: u32,

/// How many entries a table of `max_size` bytes can hold. Every entry costs at
/// least `entry_overhead` bytes of accounting.
pub fn slotCount(max_size: anytype) usize {
    return @as(usize, max_size) / entry_overhead;
}

/// The blob type `initBuffer` needs for a table that can grow to `max_size`
/// bytes: `var memory: TableStorage.Buffer(4096) = undefined;`.
pub fn Buffer(comptime max_size: usize) type {
    return [bytesNeeded(max_size)]u8;
}

/// The bytes a table of `max_size` bytes needs, including the slack to align
/// the blob's start to a `Slot`.
pub fn bytesNeeded(max_size: usize) usize {
    const n = slotCount(max_size);
    const slots_at = mem.alignForward(usize, max_size, @alignOf(Slot));
    const usable = slots_at + n * @sizeOf(Slot) + n * @sizeOf(u32);
    return usable + @alignOf(Slot) - 1;
}

pub const Error = Allocator.Error || error{
    /// The caller's blob is shorter than `bytesNeeded(max_size)`.
    BufferTooSmall,
    /// `max_size` does not fit the `u32` the table stores.
    TooLarge,
};

/// Allocate one blob for a table that can grow to `max_size` bytes.
pub fn init(allocator: Allocator, max_size: usize) Error!TableStorage {
    if (max_size > math.maxInt(u32)) return error.TooLarge;
    return .{
        .memory = try allocator.alloc(u8, bytesNeeded(max_size)),
        .max_size = @intCast(max_size),
    };
}

/// Wrap a caller's blob. It needs `bytesNeeded(max_size)` bytes; a shorter
/// one is `error.BufferTooSmall`, not an assertion.
pub fn initBuffer(memory: []u8, max_size: usize) Error!TableStorage {
    if (max_size > math.maxInt(u32)) return error.TooLarge;
    if (memory.len < bytesNeeded(max_size)) return error.BufferTooSmall;
    return .{ .memory = memory, .max_size = @intCast(max_size) };
}

/// Release the blob. Call this only for a storage from `init`; a caller that
/// used `initBuffer` owns and frees its own memory.
pub fn deinit(self: *TableStorage, allocator: Allocator) void {
    allocator.free(self.memory);
    self.* = undefined;
}

pub const Views = struct {
    bytes: []u8,
    slots: []Slot,
    hashes: []u32,
};

/// The three slices, aligned and laid out inside `memory`.
pub fn views(self: *const TableStorage) Views {
    const max_size: usize = self.max_size;
    const n = slotCount(max_size);
    const base: [*]u8 = @ptrFromInt(mem.alignForward(
        usize,
        @intFromPtr(self.memory.ptr),
        @alignOf(Slot),
    ));
    const slots_at = mem.alignForward(usize, max_size, @alignOf(Slot));
    const slots_ptr: [*]Slot = @ptrCast(@alignCast(base + slots_at));
    const hashes_ptr: [*]u32 = @ptrCast(@alignCast(base + slots_at + n * @sizeOf(Slot)));
    return .{
        .bytes = base[0..max_size],
        .slots = slots_ptr[0..n],
        .hashes = hashes_ptr[0..n],
    };
}

test "init owns one blob and deinit frees it" {
    var storage: TableStorage = try .init(testing.allocator, 256);
    defer storage.deinit(testing.allocator);

    const v = storage.views();
    try testing.expectEqual(@as(usize, 256), v.bytes.len);
    try testing.expectEqual(TableStorage.slotCount(256), v.slots.len);
    try testing.expectEqual(TableStorage.slotCount(256), v.hashes.len);

    // Every view lives inside the blob.
    const base = @intFromPtr(storage.memory.ptr);
    const end = base + storage.memory.len;
    for ([_][]const u8{
        mem.sliceAsBytes(v.bytes),
        mem.sliceAsBytes(v.slots),
        mem.sliceAsBytes(v.hashes),
    }) |view| {
        try testing.expect(@intFromPtr(view.ptr) >= base);
        try testing.expect(@intFromPtr(view.ptr) + view.len <= end);
    }
}

test "initBuffer wraps caller bytes and frees nothing" {
    var memory: TableStorage.Buffer(128) = undefined;
    var storage: TableStorage = try .initBuffer(&memory, 128);

    const v = storage.views();
    try testing.expectEqual(@as(usize, 128), v.bytes.len);
    try testing.expectEqual(TableStorage.slotCount(128), v.slots.len);
    try testing.expectEqual(TableStorage.slotCount(128), v.hashes.len);
}

test "the caller's blob need not be Slot-aligned" {
    var memory: [TableStorage.bytesNeeded(128) + 1]u8 = undefined;
    var storage: TableStorage = try .initBuffer(memory[1..], 128);
    const v = storage.views();
    try testing.expectEqual(@as(usize, 128), v.bytes.len);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(v.slots.ptr) % @alignOf(TableStorage.Slot));
}

test "size zero still has valid views" {
    var storage: TableStorage = try .init(testing.allocator, 0);
    defer storage.deinit(testing.allocator);

    const v = storage.views();
    try testing.expectEqual(@as(usize, 0), v.bytes.len);
    try testing.expectEqual(@as(usize, 0), v.slots.len);
    try testing.expectEqual(@as(usize, 0), v.hashes.len);
}

test "initBuffer reports a short blob instead of asserting" {
    var memory: [TableStorage.bytesNeeded(128) - 1]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, TableStorage.initBuffer(&memory, 128));
}

test "a max size beyond u32 is an error" {
    var memory: [16]u8 = undefined;
    try testing.expectError(
        error.TooLarge,
        TableStorage.initBuffer(&memory, @as(usize, math.maxInt(u32)) + 1),
    );
    try testing.expectError(
        error.TooLarge,
        TableStorage.init(testing.allocator, @as(usize, math.maxInt(u32)) + 1),
    );
}

test "Buffer(max_size) is the blob type initBuffer takes" {
    var memory: TableStorage.Buffer(128) = undefined;
    try testing.expectEqual(TableStorage.bytesNeeded(128), memory.len);
    var storage = try TableStorage.initBuffer(&memory, 128);
    _ = storage.views();
}

test "a table smaller than one entry has no slots" {
    try testing.expectEqual(@as(usize, 0), TableStorage.slotCount(31));
    try testing.expectEqual(@as(usize, 1), TableStorage.slotCount(32));
    try testing.expectEqual(@as(usize, 0), TableStorage.slotCount(0));
}

//! Types shared by the readiness wait backends.

const std = @import("std");

pub const Owner = union(enum) {
    stop,
    listener,
    slot: usize,
};

/// What the waiter should watch for.
pub const Interest = std.enums.EnumSet(enum { read, write });

/// What the waiter saw.
pub const Flags = std.enums.EnumSet(enum { readable, writable, failed, hup });

/// One ready descriptor, translated out of the backend's native event form.
pub const Ready = struct {
    owner: Owner,
    flags: Flags,
};

/// The backend table has one entry for the stop event, one for the listener,
/// then one per connection slot.
pub fn ownerIndex(owner: Owner) usize {
    return switch (owner) {
        .stop => 0,
        .listener => 1,
        .slot => |index| index + 2,
    };
}

pub fn ownerFromIndex(index: usize) Owner {
    return switch (index) {
        0 => .stop,
        1 => .listener,
        else => .{ .slot = index - 2 },
    };
}

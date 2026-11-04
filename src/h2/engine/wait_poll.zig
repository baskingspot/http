//! poll(2) registration and wait.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const types = @import("wait.zig");

pub const Wait = struct {
    allocator: Allocator,
    entries: []Entry,
    pollfds: []posix.pollfd,
    owners: []types.Owner,
    ready: []types.Ready,

    const Entry = struct {
        fd: posix.fd_t = -1,
        interest: types.Interest = .{},
        active: bool = false,
    };

    pub fn init(allocator: Allocator, max_entries: usize) !Wait {
        const entries = try allocator.alloc(Entry, max_entries);
        errdefer allocator.free(entries);
        @memset(entries, .{});

        const pollfds = try allocator.alloc(posix.pollfd, max_entries);
        errdefer allocator.free(pollfds);
        const owners = try allocator.alloc(types.Owner, max_entries);
        errdefer allocator.free(owners);
        const ready = try allocator.alloc(types.Ready, max_entries);
        errdefer allocator.free(ready);

        return .{
            .allocator = allocator,
            .entries = entries,
            .pollfds = pollfds,
            .owners = owners,
            .ready = ready,
        };
    }

    pub fn deinit(self: *Wait) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.pollfds);
        self.allocator.free(self.owners);
        self.allocator.free(self.ready);
        self.* = undefined;
    }

    pub fn set(self: *Wait, owner: types.Owner, fd: posix.fd_t, interest: types.Interest) !void {
        self.entries[types.ownerIndex(owner)] = .{
            .fd = fd,
            .interest = interest,
            .active = true,
        };
    }

    pub fn remove(self: *Wait, owner: types.Owner) void {
        self.entries[types.ownerIndex(owner)].active = false;
    }

    pub fn wait(self: *Wait, timeout_ms: i32) ![]types.Ready {
        var count: usize = 0;
        for (self.entries, 0..) |entry, index| {
            if (!entry.active) continue;
            var events: i16 = 0;
            if (entry.interest.contains(.read)) events |= posix.POLL.IN;
            if (entry.interest.contains(.write)) events |= posix.POLL.OUT;
            if (events == 0) continue;
            self.pollfds[count] = .{ .fd = entry.fd, .events = events, .revents = 0 };
            self.owners[count] = types.ownerFromIndex(index);
            count += 1;
        }

        _ = try posix.poll(self.pollfds[0..count], timeout_ms);
        var ready: usize = 0;
        for (self.pollfds[0..count], self.owners[0..count]) |fd, owner| {
            if (fd.revents == 0) continue;
            var flags: types.Flags = .empty;
            if (fd.revents & posix.POLL.IN != 0) flags.insert(.readable);
            if (fd.revents & posix.POLL.OUT != 0) flags.insert(.writable);
            if (fd.revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) flags.insert(.failed);
            if (fd.revents & posix.POLL.HUP != 0) flags.insert(.hup);
            self.ready[ready] = .{ .owner = owner, .flags = flags };
            ready += 1;
        }
        return self.ready[0..ready];
    }
};

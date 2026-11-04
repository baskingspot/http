//! epoll(7) registration and wait.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const types = @import("wait.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("h1.engine.epoll is Linux-only");
}

pub const Wait = struct {
    allocator: Allocator,
    entries: []Entry,
    epfd: linux.fd_t,
    events: []linux.epoll_event,
    ready: []types.Ready,

    const Entry = struct {
        fd: linux.fd_t = -1,
        interest: types.Interest = .{},
        active: bool = false,
    };

    pub fn init(allocator: Allocator, max_entries: usize) !Wait {
        const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.EpollCreateFailed;
        const epfd: linux.fd_t = @intCast(rc);
        errdefer _ = linux.close(epfd);

        const entries = try allocator.alloc(Entry, max_entries);
        errdefer allocator.free(entries);
        @memset(entries, .{});

        const events = try allocator.alloc(linux.epoll_event, max_entries);
        errdefer allocator.free(events);
        const ready = try allocator.alloc(types.Ready, max_entries);
        errdefer allocator.free(ready);

        return .{
            .allocator = allocator,
            .entries = entries,
            .epfd = epfd,
            .events = events,
            .ready = ready,
        };
    }

    pub fn deinit(self: *Wait) void {
        _ = linux.close(self.epfd);
        self.allocator.free(self.entries);
        self.allocator.free(self.events);
        self.allocator.free(self.ready);
        self.* = undefined;
    }

    pub fn set(self: *Wait, owner: types.Owner, fd: linux.fd_t, interest: types.Interest) !void {
        const index = types.ownerIndex(owner);
        const entry = &self.entries[index];
        const mask = eventMask(interest);
        if (mask == 0) {
            self.remove(owner);
            return;
        }
        if (entry.active and entry.fd == fd and eventMask(entry.interest) == mask) return;

        var event: linux.epoll_event = .{
            .events = mask,
            .data = .{ .u64 = index },
        };

        if (entry.active and entry.fd != fd) {
            self.remove(owner);
        }

        const op: u32 = if (entry.active) linux.EPOLL.CTL_MOD else linux.EPOLL.CTL_ADD;
        const rc = linux.epoll_ctl(self.epfd, op, fd, &event);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .EXIST => {
                const mod = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_MOD, fd, &event);
                if (linux.errno(mod) != .SUCCESS) return error.EpollCtlFailed;
            },
            else => return error.EpollCtlFailed,
        }

        entry.* = .{ .fd = fd, .interest = interest, .active = true };
    }

    pub fn remove(self: *Wait, owner: types.Owner) void {
        const entry = &self.entries[types.ownerIndex(owner)];
        if (!entry.active) return;
        _ = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_DEL, entry.fd, null);
        entry.active = false;
    }

    pub fn wait(self: *Wait, timeout_ms: i32) ![]types.Ready {
        const rc = linux.epoll_wait(
            self.epfd,
            self.events.ptr,
            @intCast(self.events.len),
            timeout_ms,
        );
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => return self.ready[0..0],
            else => return error.EpollWaitFailed,
        }

        const n: usize = @intCast(rc);
        for (self.events[0..n], 0..) |event, index| {
            var flags: types.Flags = .empty;
            if (event.events & linux.EPOLL.IN != 0) flags.insert(.readable);
            if (event.events & linux.EPOLL.OUT != 0) flags.insert(.writable);
            if (event.events & linux.EPOLL.ERR != 0) flags.insert(.failed);
            if (event.events & (linux.EPOLL.HUP | linux.EPOLL.RDHUP) != 0) flags.insert(.hup);
            self.ready[index] = .{
                .owner = types.ownerFromIndex(@intCast(event.data.u64)),
                .flags = flags,
            };
        }
        return self.ready[0..n];
    }
};

fn eventMask(interest: types.Interest) u32 {
    var mask: u32 = 0;
    if (interest.contains(.read)) mask |= linux.EPOLL.IN;
    if (interest.contains(.write)) mask |= linux.EPOLL.OUT;
    return mask;
}

//! kqueue registration and wait for the Darwin readiness engine.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const types = @import("wait.zig");
const platform = @import("platform_darwin.zig");

comptime {
    if (builtin.os.tag != .macos) @compileError("h1.engine.kqueue is macOS-only for now");
}

pub const Wait = struct {
    pub const Platform = platform;
    allocator: Allocator,
    entries: []Entry,
    kq: c.fd_t,
    events: []c.Kevent,
    ready: []types.Ready,

    const Entry = struct {
        fd: c.fd_t = -1,
        interest: types.Interest = .empty,
        active: bool = false,
    };

    pub fn init(allocator: Allocator, max_entries: usize) !Wait {
        const rc = c.kqueue();
        if (posix.errno(rc) != .SUCCESS) return error.KqueueCreateFailed;
        const kq: c.fd_t = @intCast(rc);
        errdefer _ = c.close(kq);

        const entries = try allocator.alloc(Entry, max_entries);
        errdefer allocator.free(entries);
        @memset(entries, .{});

        const events = try allocator.alloc(c.Kevent, max_entries);
        errdefer allocator.free(events);
        const ready = try allocator.alloc(types.Ready, max_entries);
        errdefer allocator.free(ready);

        return .{
            .allocator = allocator,
            .entries = entries,
            .kq = kq,
            .events = events,
            .ready = ready,
        };
    }

    pub fn deinit(self: *Wait) void {
        _ = c.close(self.kq);
        self.allocator.free(self.entries);
        self.allocator.free(self.events);
        self.allocator.free(self.ready);
        self.* = undefined;
    }

    pub fn set(self: *Wait, owner: types.Owner, fd: c.fd_t, interest: types.Interest) !void {
        const index = types.ownerIndex(owner);
        const entry = &self.entries[index];
        if (interest.count() == 0) {
            self.remove(owner);
            return;
        }

        if (entry.active and entry.fd == fd and sameInterest(entry.interest, interest)) return;
        if (entry.active and entry.fd != fd) self.remove(owner);

        if (entry.active) {
            if (entry.interest.contains(.read) != interest.contains(.read)) {
                try self.apply(fd, c.EVFILT.READ, index, if (interest.contains(.read))
                    c.EV.ADD | c.EV.ENABLE
                else
                    c.EV.DELETE);
            }
            if (entry.interest.contains(.write) != interest.contains(.write)) {
                try self.apply(fd, c.EVFILT.WRITE, index, if (interest.contains(.write))
                    c.EV.ADD | c.EV.ENABLE
                else
                    c.EV.DELETE);
            }
        } else {
            if (interest.contains(.read)) {
                try self.apply(fd, c.EVFILT.READ, index, c.EV.ADD | c.EV.ENABLE);
            }
            if (interest.contains(.write)) {
                try self.apply(fd, c.EVFILT.WRITE, index, c.EV.ADD | c.EV.ENABLE);
            }
        }

        entry.* = .{ .fd = fd, .interest = interest, .active = true };
    }

    pub fn remove(self: *Wait, owner: types.Owner) void {
        const entry = &self.entries[types.ownerIndex(owner)];
        if (!entry.active) return;
        const index = types.ownerIndex(owner);
        self.apply(entry.fd, c.EVFILT.READ, index, c.EV.DELETE) catch |err| {
            _ = @errorName(err);
        };
        self.apply(entry.fd, c.EVFILT.WRITE, index, c.EV.DELETE) catch |err| {
            _ = @errorName(err);
        };
        entry.active = false;
    }

    pub fn wait(self: *Wait, timeout_ms: i32) ![]types.Ready {
        const changes: [0]c.Kevent = .{};
        var timeout: posix.timespec = undefined;
        const timeout_ptr: ?*const posix.timespec = if (timeout_ms < 0) null else blk: {
            timeout = .{
                .sec = @divTrunc(timeout_ms, 1000),
                .nsec = @as(c_long, @intCast(@mod(timeout_ms, 1000))) * 1_000_000,
            };
            break :blk &timeout;
        };

        const rc = c.kevent(
            self.kq,
            &changes,
            0,
            self.events.ptr,
            @intCast(self.events.len),
            timeout_ptr,
        );
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => return self.ready[0..0],
            .NOMEM => return error.SystemResources,
            else => return error.KqueueWaitFailed,
        }

        const n: usize = @intCast(rc);
        for (self.events[0..n], 0..) |event, i| {
            var flags: types.Flags = .empty;
            if (event.filter == c.EVFILT.READ) flags.insert(.readable);
            if (event.filter == c.EVFILT.WRITE) flags.insert(.writable);
            if (event.flags & c.EV.ERROR != 0) flags.insert(.failed);
            if (event.flags & c.EV.EOF != 0) flags.insert(.hup);
            self.ready[i] = .{
                .owner = types.ownerFromIndex(event.udata),
                .flags = flags,
            };
        }
        return self.ready[0..n];
    }

    fn apply(self: *Wait, fd: c.fd_t, filter: i16, index: usize, flags: u16) !void {
        var change: c.Kevent = .{
            .ident = @intCast(fd),
            .filter = filter,
            .flags = flags,
            .fflags = 0,
            .data = 0,
            .udata = index,
        };
        const empty: [0]c.Kevent = .{};
        const changes: [*]const c.Kevent = @ptrCast(&change);
        while (true) {
            const rc = c.kevent(self.kq, changes, 1, &empty, 0, null);
            switch (posix.errno(rc)) {
                .SUCCESS, .NOENT => return,
                .INTR => continue,
                else => return error.KqueueCtlFailed,
            }
        }
    }
};

fn sameInterest(a: types.Interest, b: types.Interest) bool {
    return a.contains(.read) == b.contains(.read) and
        a.contains(.write) == b.contains(.write);
}

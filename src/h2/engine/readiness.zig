//! The readiness engine shared by the poll(2), epoll(7), and kqueue(2) backends.
//!
//! Fixed connection slots, nonblocking sockets, one thread, and no deadlines
//! yet. Each slot drives the sans-I/O `Connection` core; the socket is only
//! read when the waiter says so, and output is drained through a per-slot
//! buffer. The `Waiter.Platform` edge supplies the listener, stop descriptor,
//! accept, read, send, and close for the host.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fd_t = std.posix.fd_t;

const session_mod = @import("../session.zig");
const SessionOptions = session_mod.Options;
const connection_mod = @import("connection.zig");
const Connection = connection_mod.Connection;
const common = @import("common.zig");
pub const Exchange = common.Exchange;
pub const Handler = common.Handler;
const wait = @import("../../transport/wait.zig");

// ast-grep-ignore: public-struct-field-default -- options bag; defaults are the policy
pub const Config = struct {
    allocator: Allocator,
    max_connections: usize,
    read_buffer_bytes: usize = 16 * 1024,
    write_buffer_bytes: usize = 16 * 1024,
    max_streams: u16 = 128,
    body_bytes: usize = 64 * 1024,
    arena_retain_bytes: usize = 4 * 1024,
    session: SessionOptions = .{ .role = .server },
};

const State = enum { free, read, write };

const Slot = struct {
    conn: Connection = undefined,
    fd: fd_t = -1,
    state: State = .free,
    read_buffer: []u8,
    out_buffer: []u8,
    out_start: usize = 0,
    out_end: usize = 0,
};

pub fn Server(comptime Wait: type) type {
    const P = Wait.Platform;
    return struct {
        const Self = @This();

        io: Io,
        allocator: Allocator,
        handler: Handler,
        config: Config,
        listener: P.Listener,
        stop: P.Stop,
        slots: []Slot,
        wait: Wait,
        active: usize,

        pub fn init(
            io: Io,
            bind_address: Io.net.IpAddress,
            handler: Handler,
            config: Config,
        ) !Self {
            if (config.max_connections == 0) return error.NoConnections;
            if (config.read_buffer_bytes == 0 or config.write_buffer_bytes == 0) {
                return error.NoBuffer;
            }

            var listener = try P.openListener(bind_address, false);
            errdefer listener.deinit();

            const stop = try P.Stop.init();
            errdefer stop.deinit();

            const slots = try config.allocator.alloc(Slot, config.max_connections);
            errdefer config.allocator.free(slots);
            var initialized: usize = 0;
            errdefer for (slots[0..initialized]) |*slot| {
                config.allocator.free(slot.read_buffer);
                config.allocator.free(slot.out_buffer);
            };
            for (slots) |*slot| {
                slot.* = .{
                    .read_buffer = try config.allocator.alloc(u8, config.read_buffer_bytes),
                    .out_buffer = try config.allocator.alloc(u8, config.write_buffer_bytes),
                };
                initialized += 1;
            }

            var waiter = try Wait.init(config.allocator, config.max_connections + 2);
            errdefer waiter.deinit();
            try waiter.set(.stop, stop.read_fd, .initOne(.read));
            try waiter.set(.listener, listener.fd, .initOne(.read));

            return .{
                .io = io,
                .allocator = config.allocator,
                .handler = handler,
                .config = config,
                .listener = listener,
                .stop = stop,
                .slots = slots,
                .wait = waiter,
                .active = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.slots, 0..) |*slot, index| {
                if (slot.state != .free) self.closeSlot(index);
                self.allocator.free(slot.read_buffer);
                self.allocator.free(slot.out_buffer);
            }
            self.wait.deinit();
            self.stop.deinit();
            self.listener.deinit();
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        pub fn address(self: *const Self) Io.net.IpAddress {
            return self.listener.address;
        }

        pub fn requestStop(self: *Self) void {
            self.stop.wake();
        }

        pub fn run(self: *Self) !void {
            while (true) {
                const ready = try self.wait.wait(-1);
                for (ready) |event| switch (event.owner) {
                    .stop => return,
                    .listener => {
                        if (event.flags.contains(.readable)) try self.acceptAll();
                    },
                    .slot => |index| self.handleSlot(index, event.flags),
                };
            }
        }

        fn acceptAll(self: *Self) !void {
            while (true) {
                const index = self.freeSlot() orelse {
                    const maybe = P.accept(self.listener.fd) catch return;
                    if (maybe) |fd| P.close(fd);
                    return;
                };
                const maybe = P.accept(self.listener.fd) catch |err| switch (err) {
                    error.ConnectionAborted => continue,
                    error.ListenerFailed, error.SystemResources => return error.AcceptFailed,
                };
                const fd = maybe orelse return;

                const slot = &self.slots[index];
                slot.fd = fd;
                slot.out_start = 0;
                slot.out_end = 0;
                slot.conn = Connection.init(.{
                    .allocator = self.allocator,
                    .handler = self.handler,
                    .max_streams = self.config.max_streams,
                    .body_bytes = self.config.body_bytes,
                    .arena_retain_bytes = self.config.arena_retain_bytes,
                    .session = self.config.session,
                }) catch |err| {
                    P.close(fd);
                    slot.state = .free;
                    self.handler.vtable.report_error(self.handler.ptr, err);
                    continue;
                };
                slot.state = .read;
                self.active += 1;
                try self.wait.set(.{ .slot = index }, fd, .initOne(.read));
            }
        }

        fn handleSlot(self: *Self, index: usize, flags: wait.Flags) void {
            const slot = &self.slots[index];
            if (slot.state == .free) return;

            if (flags.contains(.failed) or flags.contains(.hup)) {
                self.closeSlot(index);
                return;
            }

            if (slot.state == .read and flags.contains(.readable)) {
                self.readSlot(index);
                return;
            }
            if (slot.state == .write and flags.contains(.writable)) {
                self.writeSlot(index);
            }
        }

        fn readSlot(self: *Self, index: usize) void {
            const slot = &self.slots[index];
            while (true) {
                const n = P.read(slot.fd, slot.read_buffer) catch |err| switch (err) {
                    error.WouldBlock => return,
                    error.ReadFailed => {
                        self.closeSlot(index);
                        return;
                    },
                };
                if (n == 0) {
                    if (slot.conn.hasPendingOutput()) {
                        self.transition(index, .write);
                    } else {
                        self.closeSlot(index);
                    }
                    return;
                }

                var offset: usize = 0;
                while (offset < n) {
                    const consumed = slot.conn.receive(slot.read_buffer[offset..n]);
                    if (consumed == 0) break;
                    offset += consumed;
                }
                _ = slot.conn.drive() catch |err| {
                    self.handler.vtable.report_error(self.handler.ptr, err);
                    self.closeSlot(index);
                    return;
                };
                self.afterRead(index);
                if (slot.state != .read) return;
            }
        }

        fn afterRead(self: *Self, index: usize) void {
            const slot = &self.slots[index];
            if (slot.conn.isClosed()) {
                if (slot.conn.hasPendingOutput()) {
                    self.transition(index, .write);
                } else {
                    self.closeSlot(index);
                }
                return;
            }
            if (slot.conn.hasPendingOutput()) {
                self.transition(index, .write);
            } else {
                self.transition(index, .read);
            }
        }

        fn writeSlot(self: *Self, index: usize) void {
            const slot = &self.slots[index];
            while (true) {
                if (slot.out_start == slot.out_end) {
                    slot.out_start = 0;
                    slot.out_end = slot.conn.send(slot.out_buffer);
                    if (slot.out_end == 0) {
                        _ = slot.conn.drive() catch |err| {
                            self.handler.vtable.report_error(self.handler.ptr, err);
                            self.closeSlot(index);
                            return;
                        };
                        slot.out_end = slot.conn.send(slot.out_buffer);
                        if (slot.out_end == 0) {
                            if (slot.conn.isClosed()) {
                                self.closeSlot(index);
                            } else {
                                self.transition(index, .read);
                            }
                            return;
                        }
                    }
                }

                const bytes = slot.out_buffer[slot.out_start..slot.out_end];
                const n = P.send(slot.fd, &.{}, bytes) catch |err| switch (err) {
                    error.WouldBlock => return,
                    error.BrokenPipe => {
                        self.closeSlot(index);
                        return;
                    },
                };
                if (n == 0) {
                    self.closeSlot(index);
                    return;
                }
                slot.out_start += n;
                if (slot.out_start < slot.out_end) return;
            }
        }

        fn transition(self: *Self, index: usize, state: State) void {
            const slot = &self.slots[index];
            slot.state = state;
            if (state == .free) {
                self.wait.remove(.{ .slot = index });
                return;
            }
            const interest = if (state == .write)
                wait.Interest.initOne(.write)
            else
                wait.Interest.initOne(.read);
            self.wait.set(.{ .slot = index }, slot.fd, interest) catch {
                self.closeSlot(index);
            };
        }

        fn closeSlot(self: *Self, index: usize) void {
            const slot = &self.slots[index];
            if (slot.state == .free) return;
            slot.conn.deinit();
            P.close(slot.fd);
            slot.fd = -1;
            slot.state = .free;
            slot.out_start = 0;
            slot.out_end = 0;
            self.wait.remove(.{ .slot = index });
            self.active -= 1;
        }

        fn freeSlot(self: *Self) ?usize {
            for (self.slots, 0..) |*slot, index| {
                if (slot.state == .free) return index;
            }
            return null;
        }
    };
}

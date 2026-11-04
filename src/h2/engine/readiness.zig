//! The readiness engine shared by the poll(2) and epoll backends.
//!
//! Fixed connection slots, nonblocking sockets, one thread, and no deadlines
//! yet. Each slot drives the sans-I/O `Connection` core; the socket is only
//! read when poll says so, and output is drained through a per-slot buffer.
//! Linux-only for now.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const posix = std.posix;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const session_mod = @import("../session.zig");
const SessionOptions = session_mod.Options;
const connection_mod = @import("connection.zig");
const Connection = connection_mod.Connection;
const common = @import("common.zig");
pub const Exchange = common.Exchange;
pub const Handler = common.Handler;
const wait = @import("wait.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("the readiness engine is Linux-only for now");
}

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
    fd: linux.fd_t = -1,
    state: State = .free,
    read_buffer: []u8,
    out_buffer: []u8,
    out_start: usize = 0,
    out_end: usize = 0,
};

pub fn Server(comptime Wait: type) type {
    return struct {
        const Self = @This();

        io: Io,
        allocator: Allocator,
        handler: Handler,
        config: Config,
        listener: Io.net.Server,
        stop_fd: linux.fd_t,
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

            var listener = try openListener(bind_address);
            errdefer listener.deinit(io);

            const stop_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
            if (linux.errno(stop_rc) != .SUCCESS) return error.EventfdFailed;
            const stop_fd: linux.fd_t = @intCast(stop_rc);
            errdefer _ = linux.close(stop_fd);

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
            try waiter.set(.stop, stop_fd, .initOne(.read));
            try waiter.set(.listener, listener.socket.handle, .initOne(.read));

            return .{
                .io = io,
                .allocator = config.allocator,
                .handler = handler,
                .config = config,
                .listener = listener,
                .stop_fd = stop_fd,
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
            _ = linux.close(self.stop_fd);
            self.listener.deinit(self.io);
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        pub fn address(self: *const Self) Io.net.IpAddress {
            return self.listener.socket.address;
        }

        pub fn requestStop(self: *Self) void {
            const one: [8]u8 = .{ 1, 0, 0, 0, 0, 0, 0, 0 };
            _ = linux.write(self.stop_fd, &one);
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
                    const rc = linux.accept4(
                        self.listener.socket.handle,
                        null,
                        null,
                        linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
                    );
                    if (linux.errno(rc) == .SUCCESS) _ = linux.close(@intCast(rc));
                    return;
                };
                const rc = linux.accept4(
                    self.listener.socket.handle,
                    null,
                    null,
                    linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
                );
                switch (linux.errno(rc)) {
                    .SUCCESS => {},
                    .AGAIN => return,
                    .INTR, .CONNABORTED, .PROTO, .PERM => continue,
                    else => return error.AcceptFailed,
                }
                const fd: linux.fd_t = @intCast(rc);

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
                    _ = linux.close(fd);
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
                const n = posix.read(slot.fd, slot.read_buffer) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => {
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
                const n = sendBytes(slot.fd, bytes) catch |err| switch (err) {
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
            _ = linux.close(slot.fd);
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

const SendError = error{ WouldBlock, BrokenPipe };

fn sendBytes(fd: linux.fd_t, bytes: []const u8) SendError!usize {
    var iov: [1]posix.iovec_const = .{
        .{ .base = bytes.ptr, .len = bytes.len },
    };
    const msg: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    while (true) {
        const rc = linux.sendmsg(fd, &msg, linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => return error.BrokenPipe,
        }
    }
}

fn openListener(address: Io.net.IpAddress) !Io.net.Server {
    const family: u32 = switch (address) {
        .ip4 => linux.AF.INET,
        .ip6 => linux.AF.INET6,
    };
    const fd_rc = linux.socket(
        family,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
    );
    if (linux.errno(fd_rc) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(fd_rc);
    errdefer _ = linux.close(fd);

    const one: u32 = 1;
    const opt_rc = linux.setsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.REUSEADDR,
        mem.asBytes(&one),
        @sizeOf(u32),
    );
    if (linux.errno(opt_rc) != .SUCCESS) return error.SocketOptionFailed;

    switch (address) {
        .ip4 => |a| {
            var sa: linux.sockaddr.in = .{
                .port = mem.nativeToBig(u16, a.port),
                .addr = @bitCast(a.bytes),
            };
            const bind_rc = linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
            if (linux.errno(bind_rc) != .SUCCESS) return error.BindFailed;
        },
        .ip6 => |a| {
            var sa: linux.sockaddr.in6 = .{
                .port = mem.nativeToBig(u16, a.port),
                .flowinfo = a.flow,
                .addr = a.bytes,
                .scope_id = a.interface.index,
            };
            const bind_rc = linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in6));
            if (linux.errno(bind_rc) != .SUCCESS) return error.BindFailed;
        },
    }

    const listen_rc = linux.listen(fd, 128);
    if (linux.errno(listen_rc) != .SUCCESS) return error.ListenFailed;

    var storage: linux.sockaddr.storage = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.storage);
    const name_rc = linux.getsockname(fd, @ptrCast(&storage), &len);
    if (linux.errno(name_rc) != .SUCCESS) return error.GetsocknameFailed;
    const bound: Io.net.IpAddress = switch (address) {
        .ip4 => blk: {
            const sa: *const linux.sockaddr.in = @ptrCast(&storage);
            break :blk .{ .ip4 = .{
                .bytes = @bitCast(sa.addr),
                .port = mem.bigToNative(u16, sa.port),
            } };
        },
        .ip6 => blk: {
            const sa: *const linux.sockaddr.in6 = @ptrCast(&storage);
            break :blk .{ .ip6 = .{
                .bytes = sa.addr,
                .port = mem.bigToNative(u16, sa.port),
                .flow = sa.flowinfo,
                .interface = .{ .index = sa.scope_id },
            } };
        },
    };

    return .{
        .socket = .{ .handle = fd, .address = bound },
        .options = {},
    };
}

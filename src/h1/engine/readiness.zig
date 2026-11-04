//! The readiness engine shared by the poll(2) and epoll backends.
//!
//! Fixed slots, nonblocking sockets, absolute deadlines, accept backoff, and a
//! stop eventfd. A `Waiter` owns registration and the wait; the slot state
//! machine does not change. io_uring is a separate completion engine.
//!
//! This module is Linux-only for now. It uses raw descriptors for readiness and
//! `std.Io` only for the listener, the clock, and closing the listener.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const posix = std.posix;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");

const Header = @import("../../header.zig").Header;
const h1 = @import("../root.zig");
pub const Exchange = @import("common.zig").Exchange;

const wait = @import("wait.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("the readiness engine is Linux-only for now");
}

// ast-grep-ignore: public-struct-field-default -- options bag; the defaults are the buffer policy
pub const Config = struct {
    allocator: Allocator,
    max_connections: usize,
    request_buffer_bytes: usize = 16 * 1024,
    headers: usize = 64,
    response_head_bytes: usize = 1024,
    response_body_bytes: usize = 8 * 1024,
    drain_bytes: usize = 4 * 1024,
    body_bytes: usize = 64 * 1024,
    limits: h1.ServerConn.Limits = .{},
    accept_backoff: Io.Duration = .fromMilliseconds(50),
    /// Linux `TCP_DEFER_ACCEPT`. The listener wakes only when the peer sends
    /// data, not when the handshake completes.
    tcp_defer_accept: bool = false,
};

const State = enum { free, read, write, drain };

const Slot = struct {
    conn: h1.ServerConn,
    fd: linux.fd_t = -1,
    state: State = .free,
    request: []u8,
    headers: []Header,
    response_head: []u8,
    response_body: []u8,
    drain: []u8,
    exchange: Exchange,
    exchange_active: bool = false,

    fn bindExchange(self: *Slot, id: usize) void {
        self.exchange = .{
            .id = id,
            .conn = &self.conn,
            .request = undefined,
            .response_body = self.response_body,
        };
    }

    fn initConn(self: *Slot, config: Config) void {
        self.conn = .init(.{
            .request_buffer = self.request,
            .headers = self.headers,
            .response_buffer = self.response_head,
            .limits = limits(config),
        });
    }
};

pub fn Server(comptime Handler: type, comptime Waiter: type) type {
    return struct {
        const Self = @This();

        io: Io,
        allocator: Allocator,
        handler: *Handler,
        config: Config,
        listener: Io.net.Server,
        stop_fd: linux.fd_t,
        slots: []Slot,
        wait: Waiter,
        active: usize,
        accept_paused_until: ?Io.Timestamp,

        pub fn init(
            io: Io,
            address: Io.net.IpAddress,
            handler: *Handler,
            config: Config,
        ) !Self {
            assert(config.max_connections > 0);
            assert(config.response_head_bytes >= 64);
            const allocator = config.allocator;

            var listener = try openListener(address, config);
            errdefer listener.deinit(io);

            const stop_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
            if (linux.errno(stop_rc) != .SUCCESS) return error.EventfdFailed;
            const stop_fd: linux.fd_t = @intCast(stop_rc);
            errdefer _ = linux.close(stop_fd);

            const slots = try allocator.alloc(Slot, config.max_connections);
            errdefer allocator.free(slots);
            var initialized: usize = 0;
            errdefer for (slots[0..initialized]) |*slot| freeSlotBuffers(allocator, slot);
            for (slots, 0..) |*slot, index| {
                slot.* = try makeSlot(allocator, config);
                slot.bindExchange(index);
                initialized += 1;
            }

            var waiter = try Waiter.init(allocator, config.max_connections + 2);
            errdefer waiter.deinit();

            return .{
                .io = io,
                .allocator = allocator,
                .handler = handler,
                .config = config,
                .listener = listener,
                .stop_fd = stop_fd,
                .slots = slots,
                .wait = waiter,
                .active = 0,
                .accept_paused_until = null,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.slots) |*slot| {
                self.finishExchange(slot);
                if (slot.state != .free) {
                    _ = linux.close(slot.fd);
                    slot.state = .free;
                }
                freeSlotBuffers(self.allocator, slot);
            }
            self.allocator.free(self.slots);
            self.wait.deinit();
            _ = linux.close(self.stop_fd);
            self.listener.deinit(self.io);
            self.* = undefined;
        }

        pub fn port(self: *const Self) u16 {
            return self.listener.socket.address.getPort();
        }

        /// Wake `run` and make it return. Safe to call from another thread.
        pub fn stop(self: *const Self) void {
            var one: u64 = 1;
            _ = linux.write(self.stop_fd, mem.asBytes(&one), @sizeOf(u64));
        }

        pub fn run(self: *Self) !void {
            while (true) {
                const now = clock(self.io);
                self.expire(now);

                try self.syncWait();
                const ready = self.wait.wait(self.pollTimeout(now)) catch |err| switch (err) {
                    error.SystemResources => {
                        self.io.sleep(self.config.accept_backoff, .awake) catch |sleep_err| {
                            switch (sleep_err) {
                                error.Canceled => return,
                            }
                        };
                        continue;
                    },
                    else => return err,
                };
                if (ready.len == 0) continue;

                const after = clock(self.io);
                for (ready) |event| {
                    switch (event.owner) {
                        .stop => return,
                        .listener => {
                            if (event.flags.contains(.failed) or event.flags.contains(.hup)) {
                                return error.ListenerFailed;
                            }
                            if (event.flags.contains(.readable)) try self.acceptAll(after);
                        },
                        .slot => |index| {
                            const slot = &self.slots[index];
                            if (slot.state == .free) continue;
                            self.service(slot, event, after);
                        },
                    }
                }
            }
        }

        fn syncWait(self: *Self) !void {
            try self.wait.set(.stop, self.stop_fd, .initOne(.read));

            if (self.active < self.config.max_connections and self.accept_paused_until == null) {
                try self.wait.set(
                    .listener,
                    self.listener.socket.handle,
                    .initOne(.read),
                );
            } else {
                self.wait.remove(.listener);
            }

            for (self.slots, 0..) |*slot, index| {
                if (slot.state == .free) {
                    self.wait.remove(.{ .slot = index });
                    continue;
                }
                const interest: wait.Interest = switch (slot.state) {
                    .read, .drain => .initOne(.read),
                    .write => .initOne(.write),
                    .free => unreachable,
                };
                try self.wait.set(.{ .slot = index }, slot.fd, interest);
            }
        }

        fn pollTimeout(self: *const Self, now: Io.Timestamp) i32 {
            var deadline: ?Io.Timestamp = self.accept_paused_until;
            for (self.slots) |*slot| {
                if (slot.state == .free) continue;
                if (slot.conn.deadline()) |at| {
                    deadline = earliest(deadline, at);
                }
            }
            const at = deadline orelse return -1;
            const ns = now.durationTo(at).nanoseconds;
            if (ns <= 0) return 0;
            const ms = @divTrunc(ns + 999_999, 1_000_000);
            return @intCast(@min(ms, std.math.maxInt(i32)));
        }

        fn expire(self: *Self, now: Io.Timestamp) void {
            if (self.accept_paused_until) |until| {
                if (now.durationTo(until).nanoseconds <= 0) self.accept_paused_until = null;
            }
            for (self.slots) |*slot| {
                if (slot.state == .free) continue;
                const at = slot.conn.deadline() orelse continue;
                if (now.durationTo(at).nanoseconds > 0) continue;
                switch (slot.conn.tick(now)) {
                    .none => {},
                    .reject => slot.state = .write,
                    .close => self.closeSlot(slot),
                }
            }
        }

        fn acceptAll(self: *Self, now: Io.Timestamp) !void {
            var accepted: usize = 0;
            while (accepted < self.config.max_connections) : (accepted += 1) {
                const slot = self.freeSlot() orelse return;
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
                    .BADF, .FAULT, .INVAL, .NOTSOCK => return error.ListenerFailed,
                    else => {
                        self.accept_paused_until = now.addDuration(self.config.accept_backoff);
                        return;
                    },
                }

                const fd: linux.fd_t = @intCast(rc);
                slot.fd = fd;
                slot.state = .read;
                slot.initConn(self.config);
                slot.conn.start(now);
                self.active += 1;
            }
        }

        fn freeSlot(self: *Self) ?*Slot {
            for (self.slots) |*slot| {
                if (slot.state == .free) return slot;
            }
            return null;
        }

        fn closeSlot(self: *Self, slot: *Slot) void {
            if (slot.state == .free) return;
            self.finishExchange(slot);
            _ = linux.close(slot.fd);
            slot.fd = -1;
            slot.state = .free;
            assert(self.active > 0);
            self.active -= 1;
        }

        fn finishExchange(self: *Self, slot: *Slot) void {
            if (!slot.exchange_active) return;
            slot.exchange_active = false;
            if (@hasDecl(Handler, "onExchangeComplete")) {
                self.handler.onExchangeComplete(&slot.exchange);
            }
            slot.exchange.request = undefined;
        }

        fn service(self: *Self, slot: *Slot, ready: wait.Ready, now: Io.Timestamp) void {
            switch (slot.state) {
                .free => return,
                .read => {
                    if (ready.flags.contains(.readable) or ready.flags.contains(.hup)) {
                        self.readSlot(slot, now);
                    }
                    if (slot.state == .free) return;
                    if (ready.flags.contains(.failed)) {
                        self.closeSlot(slot);
                        return;
                    }
                    if (slot.state == .read and ready.flags.contains(.hup)) self.closeSlot(slot);
                },
                .write => {
                    if (ready.flags.contains(.writable) or
                        ready.flags.contains(.failed) or
                        ready.flags.contains(.hup))
                    {
                        self.writeSlot(slot, now);
                    }
                    if (slot.state == .free) return;
                    if (ready.flags.contains(.failed) or ready.flags.contains(.hup)) {
                        self.closeSlot(slot);
                    }
                },
                .drain => {
                    if (ready.flags.contains(.readable) or ready.flags.contains(.hup)) {
                        self.drainSlot(slot);
                    }
                    if (slot.state == .free) return;
                    if (ready.flags.contains(.failed) or ready.flags.contains(.hup)) {
                        self.closeSlot(slot);
                    }
                },
            }
        }

        fn readSlot(self: *Self, slot: *Slot, now: Io.Timestamp) void {
            while (true) {
                const dst = slot.conn.recvBuffer();
                if (dst.len == 0) {
                    self.closeSlot(slot);
                    return;
                }
                const n = posix.read(slot.fd, dst) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => {
                        self.closeSlot(slot);
                        return;
                    },
                };
                if (n == 0) {
                    const event = slot.conn.eof(now);
                    if (self.handleReadEvent(slot, event)) return;
                    return;
                }
                const event = slot.conn.received(n, now);
                if (self.handleReadEvent(slot, event)) return;
            }
        }

        /// Returns true when the read loop must stop.
        fn handleReadEvent(self: *Self, slot: *Slot, event: h1.ServerConn.Event) bool {
            switch (event) {
                .need_more => {
                    if (slot.conn.sendSlices().head.len != 0) {
                        slot.state = .write;
                        return true;
                    }
                    return false;
                },
                .request => |request| {
                    if (self.handleRequest(slot, request)) {
                        slot.state = .write;
                    }
                    return true;
                },
                .reject => {
                    slot.state = .write;
                    return true;
                },
                .closed => {
                    self.closeSlot(slot);
                    return true;
                },
            }
        }

        fn handleRequest(self: *Self, slot: *Slot, request: h1.ServerConn.Request) bool {
            assert(!slot.exchange_active);
            slot.exchange.request = request;
            slot.exchange.response_body = slot.response_body;
            slot.exchange_active = true;
            self.handler.handle(&slot.exchange) catch |err| {
                self.report(err);
            };
            if (slot.conn.sendSlices().head.len == 0) {
                slot.exchange.respond(.{ .status = .internal_server_error }, "") catch {
                    self.closeSlot(slot);
                    return false;
                };
            }
            return true;
        }

        fn writeSlot(self: *Self, slot: *Slot, now: Io.Timestamp) void {
            while (true) {
                const slices = slot.conn.sendSlices();
                if (slices.head.len == 0 and slices.body.len == 0) {
                    self.closeSlot(slot);
                    return;
                }
                const n = send(slot.fd, slices.head, slices.body) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => {
                        self.closeSlot(slot);
                        return;
                    },
                };
                if (n == 0) {
                    self.closeSlot(slot);
                    return;
                }

                switch (slot.conn.sent(n, now)) {
                    .more => continue,
                    .read => {
                        slot.state = .read;
                        return;
                    },
                    .keep_alive => {
                        self.finishExchange(slot);
                        const event = slot.conn.advance(now);
                        self.afterKeepAlive(slot, event);
                        return;
                    },
                    .close => {
                        self.finishExchange(slot);
                        self.closeSlot(slot);
                        return;
                    },
                    .close_after_drain => {
                        self.finishExchange(slot);
                        slot.state = .drain;
                        return;
                    },
                }
            }
        }

        fn afterKeepAlive(self: *Self, slot: *Slot, event: h1.ServerConn.Event) void {
            switch (event) {
                .request => |request| {
                    if (self.handleRequest(slot, request)) slot.state = .write;
                },
                .need_more => {
                    slot.state = if (slot.conn.sendSlices().head.len != 0) .write else .read;
                },
                .reject => slot.state = .write,
                .closed => self.closeSlot(slot),
            }
        }

        fn drainSlot(self: *Self, slot: *Slot) void {
            while (true) {
                const n = posix.read(slot.fd, slot.drain) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => {
                        self.closeSlot(slot);
                        return;
                    },
                };
                if (n == 0) {
                    self.closeSlot(slot);
                    return;
                }
            }
        }

        fn report(self: *Self, err: anyerror) void {
            if (@hasDecl(Handler, "onError")) self.handler.onError(err);
        }
    };
}

fn makeSlot(allocator: Allocator, config: Config) !Slot {
    const request = try allocator.alloc(u8, config.request_buffer_bytes);
    errdefer allocator.free(request);
    const headers = try allocator.alloc(Header, config.headers);
    errdefer allocator.free(headers);
    const response_head = try allocator.alloc(u8, config.response_head_bytes);
    errdefer allocator.free(response_head);
    const response_body = try allocator.alloc(u8, config.response_body_bytes);
    errdefer allocator.free(response_body);
    const drain = try allocator.alloc(u8, config.drain_bytes);
    errdefer allocator.free(drain);

    return .{
        .conn = .init(.{
            .request_buffer = request,
            .headers = headers,
            .response_buffer = response_head,
            .limits = limits(config),
        }),
        .request = request,
        .headers = headers,
        .response_head = response_head,
        .response_body = response_body,
        .drain = drain,
        .exchange = undefined,
    };
}

fn limits(config: Config) h1.ServerConn.Limits {
    var value = config.limits;
    value.body_bytes = config.body_bytes;
    return value;
}

fn freeSlotBuffers(allocator: Allocator, slot: *Slot) void {
    allocator.free(slot.request);
    allocator.free(slot.headers);
    allocator.free(slot.response_head);
    allocator.free(slot.response_body);
    allocator.free(slot.drain);
}

const SendError = error{ WouldBlock, BrokenPipe };

fn send(fd: linux.fd_t, head: []const u8, body: []const u8) SendError!usize {
    var iov: [2]posix.iovec_const = undefined;
    var iov_len: usize = 0;
    if (head.len != 0) {
        iov[iov_len] = .{ .base = head.ptr, .len = head.len };
        iov_len += 1;
    }
    if (body.len != 0) {
        iov[iov_len] = .{ .base = body.ptr, .len = body.len };
        iov_len += 1;
    }
    const msg: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = iov_len,
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
            .PIPE, .CONNRESET => return error.BrokenPipe,
            else => return error.BrokenPipe,
        }
    }
}

fn openListener(address: Io.net.IpAddress, config: Config) !Io.net.Server {
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

    if (config.tcp_defer_accept) {
        const seconds: u32 = 1;
        const defer_rc = linux.setsockopt(
            fd,
            linux.IPPROTO.TCP,
            linux.TCP.DEFER_ACCEPT,
            mem.asBytes(&seconds),
            @sizeOf(u32),
        );
        if (linux.errno(defer_rc) != .SUCCESS) return error.SocketOptionFailed;
    }

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

fn earliest(a: ?Io.Timestamp, b: Io.Timestamp) Io.Timestamp {
    const at = a orelse return b;
    return if (at.nanoseconds <= b.nanoseconds) at else b;
}

fn clock(io: Io) Io.Timestamp {
    return Io.Clock.awake.now(io);
}

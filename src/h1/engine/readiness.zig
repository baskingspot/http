//! The readiness engine shared by the wait backends.
//!
//! Fixed slots, nonblocking sockets, absolute deadlines, accept backoff, and a
//! stop descriptor. A `Waiter` owns registration, the wait, and the platform
//! edge. The slot state machine does not change. io_uring is a separate
//! completion engine.

const std = @import("std");
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const fd_t = std.posix.fd_t;
const Header = @import("../../header.zig").Header;
const h1 = @import("../root.zig");
pub const Exchange = @import("common.zig").Exchange;
pub const Handler = @import("common.zig").Handler;
const wait = @import("wait.zig");

// ast-grep-ignore: public-struct-field-default -- options bag; the defaults are the buffer policy
pub const Config = struct {
    allocator: Allocator,
    max_connections: usize,
    request_buffer_bytes: usize = 16 * 1024,
    headers: usize = 64,
    response_head_bytes: usize = 1024,
    arena_retain_bytes: usize = 16 * 1024,
    drain_bytes: usize = 4 * 1024,
    body_bytes: usize = 64 * 1024,
    limits: h1.ServerConn.Limits = .{},
    accept_backoff: Io.Duration = .fromMilliseconds(50),
    /// Linux `TCP_DEFER_ACCEPT`. The listener wakes only when the peer sends
    /// data, not when the handshake completes. Other platforms ignore it.
    tcp_defer_accept: bool = false,
};

const State = enum { free, read, write, drain };

const Slot = struct {
    conn: h1.ServerConn,
    fd: fd_t = -1,
    state: State = .free,
    request: []u8,
    headers: []Header,
    response_head: []u8,
    arena: ArenaAllocator,
    drain: []u8,
    exchange: Exchange,
    exchange_active: bool = false,

    fn bindExchange(self: *Slot, id: usize) void {
        self.exchange = .{
            .id = id,
            .conn = &self.conn,
            .request = undefined,
            .arena = self.arena.allocator(),
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

pub fn Server(comptime Waiter: type) type {
    const P = Waiter.Platform;
    return struct {
        const Self = @This();

        io: Io,
        allocator: Allocator,
        handler: Handler,
        config: Config,
        listener: P.Listener,
        stop_event: P.Stop,
        slots: []Slot,
        wait: Waiter,
        active: usize,
        accept_paused_until: ?Io.Timestamp,

        pub fn init(
            io: Io,
            address: Io.net.IpAddress,
            handler: Handler,
            config: Config,
        ) !Self {
            assert(config.max_connections > 0);
            assert(config.response_head_bytes >= 64);
            const allocator = config.allocator;

            var listener = try P.openListener(address, config.tcp_defer_accept);
            errdefer listener.deinit();

            var stop_event = try P.Stop.init();
            errdefer stop_event.deinit();

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
                .stop_event = stop_event,
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
                    P.close(slot.fd);
                    slot.state = .free;
                }
                freeSlotBuffers(self.allocator, slot);
            }
            self.allocator.free(self.slots);
            self.wait.deinit();
            self.stop_event.deinit();
            self.listener.deinit();
            self.* = undefined;
        }

        pub fn port(self: *const Self) u16 {
            return self.listener.address.getPort();
        }

        /// Wake `run` and make it return. Safe to call from another thread.
        pub fn stop(self: *const Self) void {
            self.stop_event.wake();
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
            try self.wait.set(.stop, self.stop_event.read_fd, .initOne(.read));

            if (self.active < self.config.max_connections and self.accept_paused_until == null) {
                try self.wait.set(
                    .listener,
                    self.listener.fd,
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
                const maybe_fd = P.accept(self.listener.fd) catch |err| switch (err) {
                    error.ConnectionAborted => continue,
                    error.ListenerFailed => return error.ListenerFailed,
                    error.SystemResources => {
                        self.accept_paused_until = now.addDuration(self.config.accept_backoff);
                        return;
                    },
                };
                const fd = maybe_fd orelse return;
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
            self.wait.remove(.{ .slot = slot.exchange.id });
            P.close(slot.fd);
            slot.fd = -1;
            slot.state = .free;
            assert(self.active > 0);
            self.active -= 1;
        }

        fn finishExchange(self: *Self, slot: *Slot) void {
            if (!slot.exchange_active) return;
            slot.exchange_active = false;
            self.handler.vtable.complete(self.handler.ptr, &slot.exchange);
            _ = slot.arena.reset(.{ .retain_with_limit = self.config.arena_retain_bytes });
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
                const n = P.read(slot.fd, dst) catch |err| switch (err) {
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
            slot.exchange_active = true;
            self.handler.vtable.handle(self.handler.ptr, &slot.exchange) catch |err| {
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
                const n = P.send(slot.fd, slices.head, slices.body) catch |err| switch (err) {
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
                const n = P.read(slot.fd, slot.drain) catch |err| switch (err) {
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
            self.handler.vtable.report_error(self.handler.ptr, err);
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
    var arena: ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
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
        .arena = arena,
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
    slot.arena.deinit();
    allocator.free(slot.drain);
}

fn earliest(a: ?Io.Timestamp, b: Io.Timestamp) Io.Timestamp {
    const at = a orelse return b;
    return if (at.nanoseconds <= b.nanoseconds) at else b;
}

fn clock(io: Io) Io.Timestamp {
    return Io.Clock.awake.now(io);
}

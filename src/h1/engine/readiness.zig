//! The readiness engine shared by the wait backends.
//!
//! Fixed slots, nonblocking sockets, absolute deadlines, accept backoff, and a
//! stop descriptor. A `Waiter` owns registration, the wait, and the platform
//! edge. The slot state machine does not change. io_uring is a separate
//! completion engine.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const fd_t = std.posix.fd_t;
const Header = @import("../../header.zig").Header;
const Status = @import("../../status.zig").Status;
const h1 = @import("../root.zig");
pub const Exchange = @import("common.zig").Exchange;
pub const Handler = @import("common.zig").Handler;
pub const PolicyContext = @import("common.zig").PolicyContext;
pub const PolicyResponse = @import("common.zig").PolicyResponse;
const wait = @import("../../transport/wait.zig");
const wait_poll_test = @import("../../transport/wait_poll.zig");
const wait_kqueue_test = @import("../../transport/wait_kqueue.zig");
const common = @import("../../engine/common.zig");
const api = @import("common.zig");
const stream_mod = @import("../../engine/stream.zig");

// ast-grep-ignore: public-struct-field-default -- options bag; the defaults are the buffer policy
pub const Config = struct {
    allocator: Allocator,
    max_connections: usize,
    common: common.Config = .{},
    request_buffer_bytes: usize = 16 * 1024,
    headers: usize = 64,
    response_head_bytes: usize = 1024,
    /// Coalesce and cap response chunks. Zero preserves separate head/body.
    write_chunk_bytes: usize = 0,
    /// Scratch for the close-after-drain phase. Zero skips the allocation;
    /// a zero `Limits.drain_timeout` also skips the phase and this buffer.
    drain_bytes: usize = 4 * 1024,
    limits: h1.ServerConn.Limits = .{},
    accept_backoff: Io.Duration = .fromMilliseconds(50),
    /// When every slot is busy, new connections stay in the accept backlog
    /// until one frees; they are not accepted and closed.
    ///
    /// Linux `TCP_DEFER_ACCEPT`. The listener wakes only when the peer sends
    /// data, not when the handshake completes. Other platforms ignore it.
    tcp_defer_accept: bool = false,
};

const State = enum { free, read, write, stream_wait, drain };

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
    response_stream: ?stream_mod.ResponseStream = null,
    response_options: ?h1.ServerConn.ResponseOptions = null,
    stream_head_len: usize = 0,
    stream_head_sent: usize = 0,
    stream_body: []const u8 = &.{},
    stream_body_sent: usize = 0,

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
            .write_chunk_bytes = config.write_chunk_bytes,
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
                    .read, .drain, .stream_wait => .initOne(.read),
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
                if (slot.state == .stream_wait) {
                    deadline = earliest(deadline, now.addDuration(.fromMilliseconds(50)));
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
                if (slot.state == .stream_wait) {
                    slot.state = .write;
                    self.writeStreamSlot(slot, now);
                    continue;
                }
                if (slot.response_stream != null) continue;
                const at = slot.conn.deadline() orelse continue;
                if (now.durationTo(at).nanoseconds > 0) continue;
                switch (slot.conn.tick(now)) {
                    .none => {},
                    .reject => |rejection| {
                        self.reviewPolicy(slot, rejection);
                        slot.state = .write;
                    },
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
            if (slot.response_stream) |source| {
                source.stream.close();
                slot.response_stream = null;
                slot.response_options = null;
            }
            slot.exchange.response_stream = null;
            slot.exchange.response_options = null;
            self.finishExchange(slot);
            self.wait.remove(.{ .slot = slot.exchange.id });
            P.close(slot.fd);
            slot.fd = -1;
            slot.state = .free;
            assert(self.active > 0);
            self.active -= 1;
        }

        fn finishExchange(self: *Self, slot: *Slot) void {
            if (!slot.exchange_active) {
                common.resetArena(&slot.arena, self.config.common.arena_retain_bytes);
                return;
            }
            slot.exchange_active = false;
            self.handler.vtable.complete(self.handler.ptr, &slot.exchange);
            common.resetArena(&slot.arena, self.config.common.arena_retain_bytes);
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
                .stream_wait => {
                    if (ready.flags.contains(.failed) or
                        ready.flags.contains(.hup) or
                        ready.flags.contains(.readable))
                    {
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
                .request_head => {
                    return self.handleReadEvent(slot, slot.conn.bufferBody());
                },
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
                .reject => |rejection| {
                    self.reviewPolicy(slot, rejection);
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
                if (slot.exchange.response_stream) |source| {
                    source.stream.close();
                    slot.exchange.response_stream = null;
                    slot.exchange.response_options = null;
                }
            };
            if (slot.exchange.response_stream) |source| {
                if (!self.startStream(slot, source)) {
                    self.closeSlot(slot);
                    return false;
                }
                return true;
            }
            if (slot.conn.sendSlices().head.len == 0) {
                slot.exchange.respond(.{ .status = .internal_server_error }, "") catch {
                    self.closeSlot(slot);
                    return false;
                };
                self.reviewPolicy(slot, .{
                    .status = .internal_server_error,
                    .reason = .internal_error,
                });
            }
            return true;
        }

        fn reviewPolicy(self: *Self, slot: *Slot, rejection: h1.ServerConn.Rejection) void {
            api.review(
                self.handler,
                slot.exchange.id,
                slot.arena.allocator(),
                &slot.conn,
                rejection,
            ) catch self.closeSlot(slot);
        }

        fn writeSlot(self: *Self, slot: *Slot, now: Io.Timestamp) void {
            if (slot.response_stream != null) {
                self.writeStreamSlot(slot, now);
                return;
            }
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
                    .switched => {
                        self.finishExchange(slot);
                        self.closeSlot(slot);
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

        fn startStream(
            self: *Self,
            slot: *Slot,
            source: stream_mod.ResponseStream,
        ) bool {
            _ = self;
            const options = slot.exchange.response_options orelse return false;
            var fixed = Io.Writer.fixed(slot.response_head);
            var writer: h1.Writer = .init(&fixed);
            writer.statusLine(.@"HTTP/1.1", options.status) catch return false;
            if (options.content_type) |value| {
                writer.field("Content-Type", value) catch return false;
            }
            for (options.headers) |header| {
                writer.field(header.name, header.value) catch return false;
            }
            writer.field("Connection", "close") catch return false;
            if (source.content_length) |length| {
                writer.contentLength(length) catch return false;
            }
            writer.endFields() catch return false;

            slot.response_stream = source;
            slot.response_options = options;
            slot.stream_head_len = fixed.buffered().len;
            slot.stream_head_sent = 0;
            slot.stream_body = &.{};
            slot.stream_body_sent = 0;
            slot.state = .write;
            return true;
        }

        fn writeStreamSlot(self: *Self, slot: *Slot, now: Io.Timestamp) void {
            _ = now;
            const source = slot.response_stream orelse {
                self.closeSlot(slot);
                return;
            };
            while (true) {
                if (slot.stream_head_sent < slot.stream_head_len) {
                    const n = P.send(
                        slot.fd,
                        slot.response_head[slot.stream_head_sent..slot.stream_head_len],
                        "",
                    ) catch |err| switch (err) {
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
                    slot.stream_head_sent += n;
                    continue;
                }

                if (slot.stream_body_sent < slot.stream_body.len) {
                    const n = P.send(
                        slot.fd,
                        "",
                        slot.stream_body[slot.stream_body_sent..],
                    ) catch |err| switch (err) {
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
                    slot.stream_body_sent += n;
                    continue;
                }

                const result = source.stream.next() catch |err| switch (err) {
                    error.EndOfStream => {
                        self.closeSlot(slot);
                        return;
                    },
                    error.Pending => {
                        slot.state = .stream_wait;
                        return;
                    },
                    else => {
                        self.closeSlot(slot);
                        return;
                    },
                };
                if (result.data.len == 0) {
                    self.closeSlot(slot);
                    return;
                }
                slot.stream_body = result.data;
                slot.stream_body_sent = 0;
            }
        }

        fn afterKeepAlive(self: *Self, slot: *Slot, event: h1.ServerConn.Event) void {
            switch (event) {
                .request_head => self.afterKeepAlive(slot, slot.conn.bufferBody()),
                .request => |request| {
                    if (self.handleRequest(slot, request)) slot.state = .write;
                },
                .need_more => {
                    slot.state = if (slot.conn.sendSlices().head.len != 0) .write else .read;
                },
                .reject => |rejection| {
                    self.reviewPolicy(slot, rejection);
                    slot.state = .write;
                },
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
    const drain: []u8 = if (config.drain_bytes == 0 or
        limits(config).drain_timeout.nanoseconds == 0)
        @constCast(&.{})
    else
        try allocator.alloc(u8, config.drain_bytes);

    return .{
        .conn = .init(.{
            .request_buffer = request,
            .headers = headers,
            .response_buffer = response_head,
            .limits = limits(config),
            .write_chunk_bytes = config.write_chunk_bytes,
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
    value.body_bytes = config.common.body_bytes;
    return value;
}

fn freeSlotBuffers(allocator: Allocator, slot: *Slot) void {
    allocator.free(slot.request);
    allocator.free(slot.headers);
    allocator.free(slot.response_head);
    slot.arena.deinit();
    if (slot.drain.len != 0) allocator.free(slot.drain);
}

fn earliest(a: ?Io.Timestamp, b: Io.Timestamp) Io.Timestamp {
    const at = a orelse return b;
    return if (at.nanoseconds <= b.nanoseconds) at else b;
}

fn clock(io: Io) Io.Timestamp {
    return Io.Clock.awake.now(io);
}

const DeadListenerHandler = struct {
    fn handle(_: *anyopaque, _: *Exchange) anyerror!void {}
    fn complete(_: *anyopaque, _: *Exchange) void {}
    fn report(_: *anyopaque, _: anyerror) void {}
    fn policy(
        _: *anyopaque,
        context: common.PolicyContext,
    ) anyerror!common.PolicyResponse {
        return .{ .options = .{ .status = context.status }, .body = "" };
    }

    fn value() Handler {
        return .{ .ptr = undefined, .vtable = &.{
            .handle = handle,
            .complete = complete,
            .report_error = report,
            .policy_response = policy,
        } };
    }
};

fn testDeadListener(comptime Wait: type) !void {
    const ServerType = Server(Wait);
    var server = try ServerType.init(
        testing.io,
        try .parseLiteral("127.0.0.1:0"),
        DeadListenerHandler.value(),
        .{
            .allocator = testing.allocator,
            .max_connections = 1,
        },
    );
    defer server.deinit();

    const fd = server.listener.fd;
    Wait.Platform.close(fd);
    server.listener.fd = -1;
    try testing.expectError(error.ListenerFailed, server.acceptAll(Io.Timestamp.zero));
}

test "a dead listener returns ListenerFailed" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .linux) {
        try testDeadListener(wait_poll_test.Wait);
    } else if (builtin.os.tag == .macos) {
        try testDeadListener(wait_kqueue_test.Wait);
    } else {
        return error.SkipZigTest;
    }
}

//! The readiness engine shared by the poll(2), epoll(7), and kqueue(2)
//! backends, for h2c and h2 over TLS.
//!
//! Fixed connection slots, nonblocking sockets, one thread. Each slot owns a
//! byte transport and drives the sans-I/O `Connection` core above it. The
//! `Waiter.Platform` edge supplies the listener, stop descriptor, accept,
//! read, send, and close for the host. The `Transport` parameter supplies the
//! h2c socket transport or the TLS record transport.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fd_t = std.posix.fd_t;

const session_mod = @import("../session.zig");
const SessionOptions = session_mod.Options;
const connection_mod = @import("connection.zig");
const Connection = connection_mod.Connection;
const common = @import("common.zig");
const shared = @import("../../engine/common.zig");
pub const Exchange = common.Exchange;
pub const Handler = common.Handler;
const wait = @import("../../transport/wait.zig");
const wait_poll_test = @import("../../transport/wait_poll.zig");
const wait_kqueue_test = @import("../../transport/wait_kqueue.zig");
const PlainTransport = @import("transport/plain.zig").Transport;
const transport_events = @import("transport.zig");
const Event = transport_events.Event;

// ast-grep-ignore: public-struct-field-default -- options bag; defaults are the policy
pub fn Config(comptime Transport: type) type {
    // ast-grep-ignore: public-struct-field-default -- options bag; call sites override one knob
    return struct {
        allocator: Allocator,
        max_connections: usize,
        /// Read storage for the plaintext transport. TLS owns its record
        /// storage and ignores this.
        read_buffer_bytes: usize = 16 * 1024,
        /// Staging for h2 output, and the plaintext transport's write
        /// storage. TLS encrypts from this staging buffer.
        write_buffer_bytes: usize = 16 * 1024,
        max_streams: u16 = 128,
        common: shared.Config = .{ .arena_retain_bytes = 4 * 1024 },
        session: SessionOptions = .{ .role = .server },
        /// Zero disables the deadline.
        idle_timeout: Io.Duration = .zero,
        write_timeout: Io.Duration = .zero,
        total_timeout: Io.Duration = .zero,
        head_timeout: Io.Duration = .zero,
        body_timeout: Io.Duration = .zero,
        accept_backoff: Io.Duration = .fromMilliseconds(50),
        /// How long a stop waits for active streams to finish before closing.
        drain_timeout: Io.Duration = .fromSeconds(5),
        /// Transport options. The plaintext transport has defaults; TLS
        /// requires credentials and a handshake template.
        transport: ?Transport.Options = null,
    };
}

pub fn Server(comptime Wait: type, comptime Transport: type) type {
    const P = Wait.Platform;
    const ConfigType = Config(Transport);
    return struct {
        const Self = @This();

        pub const Config = ConfigType;

        const Slot = struct {
            used: bool = false,
            conn: Connection = undefined,
            transport: Transport.Slot = undefined,
            fd: fd_t = -1,
            send_buffer: []u8,
            send_start: usize = 0,
            send_end: usize = 0,
            started: Io.Timestamp = .zero,
            last_active: Io.Timestamp = .zero,
            write_started: ?Io.Timestamp = null,
            input_closed: bool = false,
            allow_write: bool = false,
        };

        io: Io,
        allocator: Allocator,
        handler: Handler,
        config: ConfigType,
        listener: P.Listener,
        stop: P.Stop,
        slots: []Slot,
        wait: Wait,
        active: usize,
        accept_paused_until: ?Io.Timestamp,
        draining: bool,
        drain_deadline: ?Io.Timestamp,

        pub fn init(
            io: Io,
            bind_address: Io.net.IpAddress,
            handler: Handler,
            config: ConfigType,
        ) !Self {
            if (config.max_connections == 0) return error.NoConnections;
            if (config.read_buffer_bytes == 0 or config.write_buffer_bytes == 0) {
                return error.NoBuffer;
            }
            if (config.transport == null and Transport.defaultOptions() == null) {
                return error.MissingTransportOptions;
            }

            var listener = try P.openListener(bind_address, false);
            errdefer listener.deinit();

            const stop = try P.Stop.init();
            errdefer stop.deinit();

            const slots = try config.allocator.alloc(Slot, config.max_connections);
            errdefer config.allocator.free(slots);
            var initialized: usize = 0;
            errdefer for (slots[0..initialized]) |*slot| {
                config.allocator.free(slot.send_buffer);
            };
            for (slots) |*slot| {
                slot.* = .{
                    .send_buffer = try config.allocator.alloc(u8, config.write_buffer_bytes),
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
                .accept_paused_until = null,
                .draining = false,
                .drain_deadline = null,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.slots, 0..) |*slot, index| {
                if (slot.used) self.closeSlot(index);
                self.allocator.free(slot.send_buffer);
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
                if (self.draining and self.active == 0) return;
                const now = clock(self.io);
                try self.expire(now);

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
                for (ready) |event| switch (event.owner) {
                    .stop => {
                        if (!self.draining) {
                            self.beginDrain(after) catch |err| {
                                self.handler.vtable.report_error(self.handler.ptr, err);
                                self.draining = true;
                            };
                        }
                    },
                    .listener => {
                        if (event.flags.contains(.readable)) try self.acceptAll(after);
                    },
                    .slot => |index| self.handleSlot(index, event.flags, after),
                };
            }
        }

        fn beginDrain(self: *Self, now: Io.Timestamp) !void {
            self.draining = true;
            self.accept_paused_until = null;
            self.wait.remove(.listener);
            if (self.config.drain_timeout.nanoseconds > 0) {
                self.drain_deadline = now.addDuration(self.config.drain_timeout);
            }

            for (self.slots, 0..) |*slot, index| {
                if (!slot.used) continue;
                slot.allow_write = true;
                slot.conn.beginDrain() catch |err| {
                    self.handler.vtable.report_error(self.handler.ptr, err);
                    self.closeSlot(index);
                    continue;
                };
                self.refresh(index, now);
            }
        }

        fn acceptAll(self: *Self, now: Io.Timestamp) !void {
            while (true) {
                const index = self.freeSlot() orelse {
                    const maybe = P.accept(self.listener.fd) catch return;
                    if (maybe) |fd| P.close(fd);
                    return;
                };
                const maybe = P.accept(self.listener.fd) catch |err| switch (err) {
                    error.ConnectionAborted => continue,
                    error.ListenerFailed => return error.ListenerFailed,
                    error.SystemResources => {
                        self.accept_paused_until = now.addDuration(self.config.accept_backoff);
                        self.wait.remove(.listener);
                        return;
                    },
                };
                const fd = maybe orelse return;

                const options = self.config.transport orelse Transport.defaultOptions() orelse {
                    P.close(fd);
                    self.handler.vtable.report_error(
                        self.handler.ptr,
                        error.MissingTransportOptions,
                    );
                    continue;
                };

                var transport = Transport.init(
                    self.allocator,
                    self.io,
                    fd,
                    options,
                    self.config.read_buffer_bytes,
                    self.config.write_buffer_bytes,
                ) catch |err| {
                    P.close(fd);
                    self.handler.vtable.report_error(self.handler.ptr, err);
                    continue;
                };

                const conn = Connection.init(.{
                    .allocator = self.allocator,
                    .handler = self.handler,
                    .max_streams = self.config.max_streams,
                    .body_bytes = self.config.common.body_bytes,
                    .arena_retain_bytes = self.config.common.arena_retain_bytes,
                    .session = self.config.session,
                    .head_timeout = self.config.head_timeout,
                    .body_timeout = self.config.body_timeout,
                }) catch |err| {
                    transport.deinit();
                    P.close(fd);
                    self.handler.vtable.report_error(self.handler.ptr, err);
                    continue;
                };

                const slot = &self.slots[index];
                slot.fd = fd;
                slot.used = true;
                slot.conn = conn;
                slot.transport = transport;
                slot.send_start = 0;
                slot.send_end = 0;
                slot.input_closed = false;
                slot.started = now;
                slot.last_active = now;
                slot.write_started = null;
                slot.allow_write = false;
                slot.conn.start(now);
                self.active += 1;

                self.refresh(index, now);
                if (!slot.used) continue;
            }
        }

        fn handleSlot(self: *Self, index: usize, flags: wait.Flags, now: Io.Timestamp) void {
            const slot = &self.slots[index];
            if (!slot.used) return;
            if (flags.contains(.failed)) {
                self.closeSlot(index);
                return;
            }

            if (flags.contains(.readable)) {
                slot.transport.receive(P) catch |err| {
                    self.handler.vtable.report_error(self.handler.ptr, err);
                    self.closeSlot(index);
                    return;
                };
                slot.last_active = now;
                slot.allow_write = true;
                self.driveSlot(index, now);
                if (!slot.used) return;
            }
            if (flags.contains(.writable)) {
                slot.transport.send(P) catch |err| {
                    self.handler.vtable.report_error(self.handler.ptr, err);
                    self.closeSlot(index);
                    return;
                };
                slot.last_active = now;
                slot.allow_write = true;
                self.driveSlot(index, now);
                if (!slot.used) return;
            }
            if (flags.contains(.hup)) {
                slot.input_closed = true;
                self.refresh(index, now);
            }
        }

        fn driveSlot(self: *Self, index: usize, now: Io.Timestamp) void {
            const slot = &self.slots[index];
            if (!slot.used) return;

            while (!slot.conn.isClosed()) {
                const event = slot.transport.next() catch |err| {
                    self.handler.vtable.report_error(self.handler.ptr, err);
                    self.closeSlot(index);
                    return;
                };
                switch (event) {
                    .need_input, .need_output => break,
                    .progress => continue,
                    .handshake_complete => {
                        slot.allow_write = true;
                        continue;
                    },
                    .application_data => |bytes| {
                        if (!self.feed(index, bytes, now)) return;
                    },
                    .closed => {
                        slot.input_closed = true;
                        break;
                    },
                }
            }

            _ = slot.conn.drive(now) catch |err| {
                self.handler.vtable.report_error(self.handler.ptr, err);
                self.closeSlot(index);
                return;
            };
            if (!slot.used) return;

            self.refresh(index, now);
        }

        /// Copy borrowed plaintext into the h2 session. A full session input
        /// buffer forces a drive before the remainder can move.
        fn feed(self: *Self, index: usize, bytes: []const u8, now: Io.Timestamp) bool {
            const slot = &self.slots[index];
            var offset: usize = 0;
            while (offset < bytes.len) {
                if (slot.conn.isClosed()) {
                    // A connection error already queued GOAWAY. Drop the rest
                    // of this plaintext and let the output drain.
                    slot.transport.consume(bytes.len);
                    slot.last_active = now;
                    return true;
                }

                const taken = slot.conn.receive(bytes[offset..]);
                if (taken == 0) {
                    _ = slot.conn.drive(now) catch |err| {
                        self.handler.vtable.report_error(self.handler.ptr, err);
                        self.closeSlot(index);
                        return false;
                    };
                    if (slot.conn.isClosed()) {
                        slot.transport.consume(bytes.len);
                        slot.last_active = now;
                        return true;
                    }
                    const retry = slot.conn.receive(bytes[offset..]);
                    if (retry == 0) {
                        self.closeSlot(index);
                        return false;
                    }
                    offset += retry;
                } else {
                    offset += taken;
                }

                _ = slot.conn.drive(now) catch |err| {
                    self.handler.vtable.report_error(self.handler.ptr, err);
                    self.closeSlot(index);
                    return false;
                };
                if (!slot.used) return false;
            }
            slot.transport.consume(bytes.len);
            slot.last_active = now;
            return true;
        }

        fn refresh(self: *Self, index: usize, now: Io.Timestamp) void {
            const slot = &self.slots[index];
            if (!slot.used) return;

            if (slot.allow_write and slot.transport.canWrite()) self.pump(index);
            if (!slot.used) return;

            var interest = slot.transport.interest();
            if (slot.conn.isClosed() or slot.input_closed) {
                interest.remove(.read);
            }
            if (interest.count() == 0) {
                if (slot.conn.isClosed() or slot.input_closed) {
                    self.closeSlot(index);
                    return;
                }
                interest.insert(.read);
            }

            if (interest.contains(.write)) {
                if (slot.write_started == null) slot.write_started = now;
            } else {
                slot.write_started = null;
            }

            self.wait.set(.{ .slot = index }, slot.fd, interest) catch {
                self.closeSlot(index);
            };
        }

        /// Move queued h2 bytes into the transport. The transport accepts a
        /// prefix and keeps its wire output; the tail stays in `send_buffer`.
        fn pump(self: *Self, index: usize) void {
            const slot = &self.slots[index];
            while (true) {
                if (slot.send_start == slot.send_end) {
                    slot.send_start = 0;
                    slot.send_end = slot.conn.send(slot.send_buffer);
                    if (slot.send_end == 0) break;
                }

                const n = slot.transport.write(
                    slot.send_buffer[slot.send_start..slot.send_end],
                ) catch |err| {
                    self.handler.vtable.report_error(self.handler.ptr, err);
                    self.closeSlot(index);
                    return;
                };
                if (n == 0) break;
                slot.send_start += n;
                if (slot.send_start < slot.send_end) break;
            }

            if (slot.send_start == slot.send_end) {
                slot.send_start = 0;
                slot.send_end = 0;
            }
        }

        fn closeSlot(self: *Self, index: usize) void {
            const slot = &self.slots[index];
            if (!slot.used) return;
            slot.conn.deinit();
            slot.transport.deinit();
            P.close(slot.fd);
            slot.fd = -1;
            slot.used = false;
            slot.send_start = 0;
            slot.send_end = 0;
            slot.started = .zero;
            slot.last_active = .zero;
            slot.write_started = null;
            slot.input_closed = false;
            slot.allow_write = false;
            self.wait.remove(.{ .slot = index });
            self.active -= 1;
        }

        fn expire(self: *Self, now: Io.Timestamp) !void {
            if (self.draining) {
                if (self.drain_deadline) |until| {
                    if (now.durationTo(until).nanoseconds <= 0) {
                        for (self.slots, 0..) |*slot, index| {
                            if (slot.used) self.closeSlot(index);
                        }
                        self.drain_deadline = null;
                    }
                }
            }

            if (self.accept_paused_until) |until| {
                if (now.durationTo(until).nanoseconds <= 0) {
                    self.accept_paused_until = null;
                    try self.wait.set(.listener, self.listener.fd, .initOne(.read));
                }
            }

            for (self.slots, 0..) |*slot, index| {
                if (!slot.used) continue;
                const deadline = self.slotDeadline(slot) orelse continue;
                if (now.durationTo(deadline).nanoseconds > 0) continue;
                self.closeSlot(index);
            }
        }

        fn slotDeadline(self: *const Self, slot: *const Slot) ?Io.Timestamp {
            var deadline: ?Io.Timestamp = null;
            if (self.config.total_timeout.nanoseconds > 0) {
                deadline = slot.started.addDuration(self.config.total_timeout);
            }
            if (self.config.idle_timeout.nanoseconds > 0) {
                deadline = earliest(
                    deadline,
                    slot.last_active.addDuration(self.config.idle_timeout),
                );
            }
            if (self.config.write_timeout.nanoseconds > 0 and slot.write_started != null) {
                const start = slot.write_started orelse slot.last_active;
                deadline = earliest(
                    deadline,
                    start.addDuration(self.config.write_timeout),
                );
            }
            if (slot.conn.deadline()) |at| {
                deadline = earliest(deadline, at);
            }
            return deadline;
        }

        fn pollTimeout(self: *const Self, now: Io.Timestamp) i32 {
            var deadline: ?Io.Timestamp = self.accept_paused_until;
            if (self.drain_deadline) |at| deadline = earliest(deadline, at);
            for (self.slots) |*slot| {
                if (!slot.used) continue;
                if (self.slotDeadline(slot)) |at| {
                    deadline = earliest(deadline, at);
                }
            }
            const at = deadline orelse return -1;
            const ns = now.durationTo(at).nanoseconds;
            if (ns <= 0) return 0;
            const ms = @divTrunc(ns + 999_999, 1_000_000);
            return @intCast(@min(ms, std.math.maxInt(i32)));
        }

        fn freeSlot(self: *Self) ?usize {
            for (self.slots, 0..) |*slot, index| {
                if (!slot.used) return index;
            }
            return null;
        }
    };
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
    const ServerType = Server(Wait, PlainTransport);
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

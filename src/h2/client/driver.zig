//! A blocking byte-transport driver for a multiplexed HTTP/2 client.
//!
//! `Driver` owns no protocol state. It flushes `Connection` output, reads
//! plaintext, and retains bytes the connection did not accept. The caller
//! polls events, controls leases, and decides what a deadline means.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Connection = @import("connection.zig").Connection;

pub const Driver = struct {
    conn: *Connection,
    reader: *Io.Reader,
    writer: *Io.Writer,
    read_buffer: []u8,
    frame_buffer: []u8,
    wait: Wait,
    read_deadline: ?ReadDeadline,
    pending_start: usize,
    pending_end: usize,
    failure: ?anyerror = null,

    /// Where transport reads wait.
    pub const Wait = union(enum) {
        /// Read raw bytes from this socket. Consume prefetched reader bytes
        /// before the next socket read. Never use this mode for a decrypting reader.
        socket: struct {
            io: Io,
            fd: std.posix.fd_t,
        },
        /// Use the supplied reader for plaintext. `read_deadline` supplies
        /// the owner's timed-read operations without a raw ciphertext read.
        reader,
    };

    /// The reader owner's absolute deadline and concrete read-error cause.
    /// The context remains valid for this driver's lifetime.
    pub const ReadDeadline = struct {
        context: *anyopaque,
        set: *const fn (*anyopaque, ?i96) void,
        cause: *const fn (*const anyopaque) ?anyerror,
    };

    // ast-grep-ignore: public-struct-field-default -- caller-owned buffers and wait mode
    pub const Options = struct {
        read_buffer: []u8,
        /// One maximum-size frame: 9 header bytes and 16 KiB of payload.
        frame_buffer: []u8,
        wait: Wait = .reader,
        read_deadline: ?ReadDeadline = null,
    };

    pub const ReadResult = enum {
        /// A read or input feed completed. Poll before the next read.
        ready,
        /// The transport read reached the caller's absolute deadline.
        timeout,
        /// The peer ended the plaintext stream.
        eof,
    };

    /// Borrow the connection, byte interfaces, and buffers for this driver's
    /// lifetime. Keep the driver in place so its pending input survives calls.
    pub fn init(
        self: *Driver,
        conn: *Connection,
        reader: *Io.Reader,
        writer: *Io.Writer,
        options: Options,
    ) void {
        assert(options.read_buffer.len != 0);
        assert(options.frame_buffer.len >= 9 + 16 * 1024);
        self.* = .{
            .conn = conn,
            .reader = reader,
            .writer = writer,
            .read_buffer = options.read_buffer,
            .frame_buffer = options.frame_buffer,
            .wait = options.wait,
            .read_deadline = options.read_deadline,
            .pending_start = 0,
            .pending_end = 0,
        };
    }

    /// Write every queued preface byte and complete frame, then flush.
    /// `Io.Writer.writeAll` handles successful short writes. A writer error
    /// after a partial frame closes this driver. Later reads and writes fail
    /// without advancing the transport because no output cursor survives.
    pub fn flush(self: *Driver) !void {
        if (self.failure != null) return error.ConnectionClosed;
        self.flushOutput() catch |err| {
            self.failure = err;
            return err;
        };
    }

    fn flushOutput(self: *Driver) !void {
        while (true) {
            const n = try self.conn.nextFrame(self.frame_buffer);
            if (n == 0) break;
            try self.writer.writeAll(self.frame_buffer[0..n]);
        }
        try self.writer.flush();
    }

    /// Absorb pending input, or perform one read bounded by an absolute
    /// monotonic deadline. Any pending input returns `.ready` immediately, so
    /// the caller can poll before another blocking read.
    ///
    /// In `.reader` mode the optional hooks set the owner's read deadline and
    /// identify its timeout cause. Cancellation and other failures stay errors.
    /// A non-null reader deadline requires those hooks.
    /// A timeout without a supplied deadline is a terminal read failure.
    pub fn read(self: *Driver, deadline_ns: ?i96) !ReadResult {
        if (self.failure != null) return error.ConnectionClosed;
        const result = self.readNext(deadline_ns) catch |err| switch (err) {
            error.Timeout, error.TimedOut => {
                if (deadline_ns != null) return .timeout;
                self.failure = err;
                return err;
            },
            error.WouldBlock => return .ready,
            error.Canceled, error.DeadlineUnsupported, error.NoReadCompletion => return err,
            error.ConcurrencyUnavailable => return error.DeadlineUnsupported,
            error.EndOfStream => {
                self.failure = err;
                return .eof;
            },
            else => {
                self.failure = err;
                return err;
            },
        };
        if (result == .eof) self.failure = error.EndOfStream;
        return result;
    }

    /// The first terminal read or write failure. Clean EOF is `EndOfStream`.
    pub fn failureCause(self: *const Driver) ?anyerror {
        return self.failure;
    }

    pub fn isClosed(self: *const Driver) bool {
        return self.failure != null;
    }

    pub fn supportsDeadline(self: *const Driver) bool {
        return self.wait == .socket or self.read_deadline != null;
    }

    fn readNext(self: *Driver, deadline_ns: ?i96) !ReadResult {
        if (self.pending_start < self.pending_end) {
            self.absorbPending();
            return .ready;
        }

        switch (self.wait) {
            .reader => {
                const owner = self.read_deadline orelse {
                    if (deadline_ns != null) return error.DeadlineUnsupported;
                    return self.readPlaintext();
                };
                owner.set(owner.context, deadline_ns);
                return self.readPlaintext() catch |err| {
                    if (err == error.ReadFailed) return owner.cause(owner.context) orelse err;
                    return err;
                };
            },
            .socket => |wait| {
                if (self.absorbBuffered()) return .ready;
                return self.readSocket(wait.io, wait.fd, deadline_ns);
            },
        }
    }

    pub fn hasPendingInput(self: *const Driver) bool {
        return self.pending_start < self.pending_end;
    }

    fn readPlaintext(self: *Driver) !ReadResult {
        var iovecs: [1][]u8 = .{self.read_buffer};
        const n = self.reader.readVec(&iovecs) catch |err| switch (err) {
            error.EndOfStream => return .eof,
            error.ReadFailed => return error.ReadFailed,
        };
        if (n == 0) {
            // Zero is not EOF in Io.Reader. A refill can instead expose bytes
            // through its internal buffer or advance a decoder without bytes.
            _ = self.absorbBuffered();
            return .ready;
        }
        self.absorb(n);
        return .ready;
    }

    fn absorbBuffered(self: *Driver) bool {
        const buffered = self.reader.buffered();
        if (buffered.len == 0) return false;
        const take = @min(buffered.len, self.read_buffer.len);
        @memcpy(self.read_buffer[0..take], buffered[0..take]);
        self.reader.toss(take);
        self.absorb(take);
        return true;
    }

    fn readSocket(self: *Driver, io: Io, fd: std.posix.fd_t, deadline: ?i96) !ReadResult {
        const instant = deadline orelse {
            var data: [1][]u8 = .{self.read_buffer};
            const n = if (comptime @hasField(Io.VTable, "netRead"))
                try io.vtable.netRead(io.userdata, fd, &data)
            else blk: {
                const result = try io.operate(.{ .net_read = .{
                    .socket_handle = fd,
                    .data = &data,
                } });
                break :blk (try result.net_read).data_len;
            };
            if (n == 0) return .eof;
            self.absorb(n);
            return .ready;
        };
        const now = Io.Clock.now(.awake, io).nanoseconds;
        if (now >= instant) return .timeout;
        const timeout: Io.Timeout = .{ .deadline = Io.Timestamp
            .fromNanoseconds(instant)
            .withClock(Io.Clock.awake) };

        if (comptime @hasField(Io.Operation, "net_read")) {
            return self.readSocket17(io, fd, timeout);
        } else {
            return self.readSocket16(io, fd, timeout);
        }
    }

    fn readSocket17(self: *Driver, io: Io, fd: std.posix.fd_t, timeout: Io.Timeout) !ReadResult {
        var storage: [1]Io.Operation.Storage = undefined;
        var batch: Io.Batch = .init(&storage);
        var iovecs: [1][]u8 = .{self.read_buffer};
        _ = batch.add(.{ .net_read = .{
            .socket_handle = fd,
            .data = &iovecs,
        } });
        const wait_error: ?Io.Batch.AwaitConcurrentError = wait: {
            batch.awaitConcurrent(io, timeout) catch |err| break :wait err;
            break :wait null;
        };
        // Evented backends retain pending reads after timeout. Reap them before
        // the stack storage dies, and keep any bytes that won the cancel race.
        batch.cancel(io);
        while (batch.next()) |completion| {
            switch (completion.result) {
                .net_read => |result| {
                    const ready = try result;
                    if (ready.data_len != 0) self.absorb(ready.data_len);
                    if (wait_error != null and wait_error.? == error.Canceled) {
                        return error.Canceled;
                    }
                    if (ready.data_len == 0) return .eof;
                    return .ready;
                },
                else => {},
            }
        }
        if (wait_error) |err| return switch (err) {
            error.Timeout => .timeout,
            error.Canceled => error.Canceled,
            error.ConcurrencyUnavailable => error.DeadlineUnsupported,
        };
        return error.NoReadCompletion;
    }

    fn readSocket16(
        self: *Driver,
        io: Io,
        fd: std.posix.fd_t,
        timeout: Io.Timeout,
    ) !ReadResult {
        const socket: Io.net.Socket = .{ .handle = fd, .address = undefined };
        const message = socket.receiveTimeout(
            io,
            self.read_buffer,
            timeout,
        ) catch |err| switch (err) {
            error.Timeout => return .timeout,
            else => return err,
        };
        if (message.data.len == 0) return .eof;
        self.absorb(message.data.len);
        return .ready;
    }

    fn absorb(self: *Driver, n: usize) void {
        self.pending_start = 0;
        self.pending_end = n;
        self.absorbPending();
    }

    fn absorbPending(self: *Driver) void {
        while (self.pending_start < self.pending_end) {
            const taken = self.conn.receive(self.read_buffer[self.pending_start..self.pending_end]);
            if (taken == 0) return;
            self.pending_start += taken;
        }
        self.pending_start = 0;
        self.pending_end = 0;
    }
};

const testing = std.testing;
const frame = @import("../frame.zig");
const session_mod = @import("../session.zig");
const Session = session_mod.Session;
const Header = @import("../../header.zig").Header;

fn transferToServer(conn: *Connection, server: *Session, out: []u8) !void {
    while (true) {
        const n = try conn.nextFrame(out);
        if (n == 0) break;
        var offset: usize = 0;
        while (offset < n) {
            const taken = server.receive(out[offset..n]);
            if (taken == 0) return error.InputFull;
            offset += taken;
        }
    }
}

fn transferToClient(server: *Session, conn: *Connection, out: []u8) !void {
    while (true) {
        const n = server.send(out);
        if (n == 0) break;
        var offset: usize = 0;
        while (offset < n) {
            const taken = conn.receive(out[offset..n]);
            if (taken == 0) return error.InputFull;
            offset += taken;
        }
    }
}

fn pendingSettingsDriver(driver: *Driver) void {
    const settings = "\x00\x00\x00\x04\x00\x00\x00\x00\x00";
    @memcpy(driver.read_buffer[0..settings.len], settings);
    driver.pending_start = 0;
    driver.pending_end = settings.len;
}

test "driver pending input yields before another transport read" {
    var conn: Connection = undefined;
    try conn.init(.{ .allocator = testing.allocator });
    defer conn.deinit();

    var reader = Io.Reader.fixed("");
    var output: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    var read_buffer: [64]u8 = undefined;
    var frame_buffer: [16 * 1024 + 9]u8 = undefined;
    var driver: Driver = undefined;
    driver.init(&conn, &reader, &writer, .{
        .read_buffer = &read_buffer,
        .frame_buffer = &frame_buffer,
    });

    pendingSettingsDriver(&driver);
    // A driver that tried the empty reader here would report EOF and hide the
    // SETTINGS already waiting in its own buffer.
    try testing.expectEqual(Driver.ReadResult.ready, try driver.read(null));
    try testing.expect(!driver.hasPendingInput());
    _ = try conn.poll();
}

test "driver retains input the connection did not accept" {
    var conn: Connection = undefined;
    try conn.init(.{ .allocator = testing.allocator });
    defer conn.deinit();
    const chunk: [4096]u8 = @splat(0);
    var used: usize = 0;
    while (used < 128 * 1024) {
        const taken = conn.receive(&chunk);
        if (taken == 0) break;
        used += taken;
    }
    try testing.expectEqual(@as(usize, 0), conn.receive(&chunk));

    var reader = Io.Reader.fixed("tail");
    var output: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    var read_buffer: [64]u8 = undefined;
    var frame_buffer: [16 * 1024 + 9]u8 = undefined;
    var driver: Driver = undefined;
    driver.init(&conn, &reader, &writer, .{
        .read_buffer = &read_buffer,
        .frame_buffer = &frame_buffer,
    });
    try testing.expectEqual(Driver.ReadResult.ready, try driver.read(null));
    try testing.expect(driver.hasPendingInput());
    const pending = driver.read_buffer[driver.pending_start..driver.pending_end];
    try testing.expectEqualStrings("tail", pending);
    try testing.expectEqual(Driver.ReadResult.ready, try driver.read(null));
}

test "driver timeout is an outcome without interpreting stream state" {
    const address: Io.net.IpAddress = try .parseLiteral("127.0.0.1:0");
    var listener = try address.listen(testing.io, .{ .mode = .stream, .reuse_address = true });
    defer listener.deinit(testing.io);
    var client_address = address;
    client_address.setPort(listener.socket.address.getPort());
    const socket = try client_address.connect(testing.io, .{ .mode = .stream });
    defer socket.close(testing.io);
    const accepted = try listener.accept(testing.io);
    defer accepted.close(testing.io);

    var conn: Connection = undefined;
    try conn.init(.{ .allocator = testing.allocator });
    defer conn.deinit();
    var reader = socket.reader(testing.io, &.{});
    var output: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    var read_buffer: [64]u8 = undefined;
    var frame_buffer: [16 * 1024 + 9]u8 = undefined;
    var driver: Driver = undefined;
    driver.init(&conn, &reader.interface, &writer, .{
        .read_buffer = &read_buffer,
        .frame_buffer = &frame_buffer,
        .wait = .{ .socket = .{
            .io = testing.io,
            .fd = socket.socket.handle,
        } },
    });

    const past = Io.Clock.now(.awake, testing.io).nanoseconds - 1;
    try testing.expectEqual(Driver.ReadResult.timeout, try driver.read(past));
    const soon = Io.Clock.now(.awake, testing.io).nanoseconds + std.time.ns_per_ms;
    try testing.expectEqual(Driver.ReadResult.timeout, try driver.read(soon));
    try testing.expect(conn.wantsInput());
    try testing.expect(!conn.isPoisoned());
    var peer_writer = accepted.writer(testing.io, &.{});
    try peer_writer.interface.writeAll("\x00\x00\x00\x04\x00\x00\x00\x00\x00");
    try peer_writer.interface.flush();
    const later = Io.Clock.now(.awake, testing.io).nanoseconds + std.time.ns_per_s;
    try testing.expectEqual(Driver.ReadResult.ready, try driver.read(later));
    _ = try conn.poll();
    try testing.expect(conn.session.settings_received);
}

const ShortWriter = struct {
    writer: Io.Writer,
    chunk: usize,
    output: []u8,
    used: usize = 0,
    fail_after: ?usize = null,

    const vtable: Io.Writer.VTable = .{
        .drain = drain,
        .flush = flush,
    };

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *ShortWriter = @fieldParentPtr("writer", w);
        if (data.len == 0) return 0;
        const bytes = data[0];
        const remaining = if (self.fail_after) |end| end - self.used else bytes.len;
        if (remaining == 0) return error.WriteFailed;
        const take = @min(self.chunk, bytes.len, remaining);
        @memcpy(self.output[self.used..][0..take], bytes[0..take]);
        self.used += take;
        _ = splat;
        return take;
    }

    fn flush(_: *Io.Writer) Io.Writer.Error!void {}
};

test "driver flush completes successful short writes exactly once" {
    var conn: Connection = undefined;
    try conn.init(.{ .allocator = testing.allocator });
    defer conn.deinit();
    var expected: [4096]u8 = undefined;
    var expected_len = try conn.nextFrame(&expected);
    try testing.expect(expected_len != 0);
    while (true) {
        const n = try conn.nextFrame(expected[expected_len..]);
        if (n == 0) break;
        expected_len += n;
    }
    try testing.expect(expected_len > frame.preface.len);

    var replay: Connection = undefined;
    try replay.init(.{ .allocator = testing.allocator });
    defer replay.deinit();
    var storage: [4096]u8 = undefined;
    var short: ShortWriter = .{
        .writer = .{ .vtable = &ShortWriter.vtable, .buffer = &.{} },
        .chunk = 1,
        .output = &storage,
    };
    var reader = Io.Reader.fixed("");
    var read_buffer: [64]u8 = undefined;
    var frame_buffer: [16 * 1024 + 9]u8 = undefined;
    var driver: Driver = undefined;
    driver.init(&replay, &reader, &short.writer, .{
        .read_buffer = &read_buffer,
        .frame_buffer = &frame_buffer,
    });
    try driver.flush();
    try testing.expectEqualSlices(u8, expected[0..expected_len], storage[0..short.used]);
}

test "driver reads a non-gRPC response with trailers" {
    var conn: Connection = undefined;
    try conn.init(.{ .allocator = testing.allocator });
    defer conn.deinit();
    var server = try Session.init(testing.allocator, .{ .role = .server });
    defer server.deinit(testing.allocator);
    var exchange: [16 * 1024]u8 = undefined;
    try transferToClient(&server, &conn, &exchange);
    try transferToServer(&conn, &server, &exchange);
    _ = try server.nextEvent(testing.allocator);
    try transferToClient(&server, &conn, &exchange);
    _ = try conn.poll();

    _ = try conn.open(.{
        .method_token = "GET",
        .scheme = .http,
        .authority = "example.com",
        .target = "/result",
    }, true);
    try transferToServer(&conn, &server, &exchange);
    const request = (try server.nextEvent(testing.allocator)) orelse return error.NoRequest;
    const id = switch (request) {
        .request => |value| value.stream_id,
        else => return error.ExpectedRequest,
    };
    try server.submitResponse(testing.allocator, id, .{ .status = .ok }, false);
    _ = try server.submitData(testing.allocator, id, "answer", false);
    const trailers = [_]Header{.{ .name = "x-result", .value = "done" }};
    try server.submitTrailers(testing.allocator, id, &trailers);

    var incoming: [16 * 1024]u8 = undefined;
    var incoming_len: usize = 0;
    while (true) {
        const n = server.send(incoming[incoming_len..]);
        if (n == 0) break;
        incoming_len += n;
    }
    var reader = Io.Reader.fixed(incoming[0..incoming_len]);
    var output: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    var read_buffer: [4096]u8 = undefined;
    var frame_buffer: [16 * 1024 + 9]u8 = undefined;
    var driver: Driver = undefined;
    driver.init(&conn, &reader, &writer, .{
        .read_buffer = &read_buffer,
        .frame_buffer = &frame_buffer,
    });
    try testing.expectEqual(Driver.ReadResult.ready, try driver.read(null));

    var saw_head = false;
    var saw_data = false;
    var saw_trailers = false;
    while (try conn.poll()) |event| {
        switch (event) {
            .head => |value| {
                try testing.expectEqual(id, value.stream);
                saw_head = true;
            },
            .data => |value| {
                try testing.expectEqualStrings("answer", value.bytes);
                try value.lease.release();
                saw_data = true;
            },
            .trailers => |value| {
                try testing.expectEqualStrings("done", value.headers.get("x-result").?);
                saw_trailers = true;
            },
            else => {},
        }
    }
    try testing.expect(saw_head);
    try testing.expect(saw_data);
    try testing.expect(saw_trailers);
}

test "driver refuses all progress after a partial frame write fails" {
    var conn: Connection = undefined;
    try conn.init(.{ .allocator = testing.allocator });
    defer conn.deinit();
    var output: [4096]u8 = undefined;
    var writer: ShortWriter = .{
        .writer = .{ .vtable = &ShortWriter.vtable, .buffer = &.{} },
        .chunk = 7,
        .output = &output,
        .fail_after = frame.preface.len + 3,
    };
    var reader = Io.Reader.fixed("");
    var read_buffer: [64]u8 = undefined;
    var frame_buffer: [16 * 1024 + 9]u8 = undefined;
    var driver: Driver = undefined;
    driver.init(&conn, &reader, &writer.writer, .{
        .read_buffer = &read_buffer,
        .frame_buffer = &frame_buffer,
    });
    try testing.expectError(error.WriteFailed, driver.flush());
    const written = writer.used;
    try testing.expectEqual(frame.preface.len + 3, written);
    _ = try conn.open(.{
        .method_token = "GET",
        .scheme = .http,
        .authority = "example.com",
        .target = "/after-failure",
    }, true);
    writer.fail_after = null;
    try testing.expectError(error.ConnectionClosed, driver.flush());
    try testing.expectError(error.ConnectionClosed, driver.read(null));
    try testing.expectEqual(written, writer.used);
}

test "zero reader progress is not EOF" {
    const Source = struct {
        const Self = @This();
        reader: Io.Reader = .{
            .vtable = &.{ .stream = stream },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        },
        reads: usize = 0,

        fn stream(reader: *Io.Reader, _: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
            const self: *Self = @fieldParentPtr("reader", reader);
            self.reads += 1;
            if (self.reads == 1) return 0;
            return error.EndOfStream;
        }
    };
    var source: Source = .{};
    var conn: Connection = undefined;
    try conn.init(.{ .allocator = testing.allocator });
    defer conn.deinit();
    var writer = Io.Writer.failing;
    var read_buffer: [64]u8 = undefined;
    var frame_buffer: [16 * 1024 + 9]u8 = undefined;
    var driver: Driver = undefined;
    driver.init(&conn, &source.reader, &writer, .{
        .read_buffer = &read_buffer,
        .frame_buffer = &frame_buffer,
    });
    try testing.expectEqual(Driver.ReadResult.ready, try driver.read(null));
    try testing.expect(!driver.isClosed());
    try testing.expectEqual(Driver.ReadResult.eof, try driver.read(null));
    try testing.expect(driver.isClosed());
}

const ReadCauseProbe = struct {
    observed: ?i96 = null,
    read_error: anyerror,

    fn set(context: *anyopaque, deadline_ns: ?i96) void {
        const self: *ReadCauseProbe = @ptrCast(@alignCast(context));
        self.observed = deadline_ns;
    }

    fn cause(context: *const anyopaque) ?anyerror {
        const self: *const ReadCauseProbe = @ptrCast(@alignCast(context));
        return self.read_error;
    }
};

test "reader hooks preserve deadlines and classify recoverable and terminal failures" {
    const failures = [_]anyerror{
        error.Timeout,
        error.TimedOut,
        error.Canceled,
        error.WouldBlock,
        error.DeadlineUnsupported,
        error.NoReadCompletion,
        error.ReadFailed,
        error.UnexpectedEof,
        error.PeerAlert,
        error.ConnectionResetByPeer,
    };
    for (failures) |failure| {
        for ([_]?i96{ 12345, null }) |deadline_ns| {
            var conn: Connection = undefined;
            try conn.init(.{ .allocator = testing.allocator });
            defer conn.deinit();
            var reader = Io.Reader.failing;
            var writer = Io.Writer.failing;
            var read_buffer: [64]u8 = undefined;
            var frame_buffer: [16 * 1024 + 9]u8 = undefined;
            var driver: Driver = undefined;
            driver.init(&conn, &reader, &writer, .{
                .read_buffer = &read_buffer,
                .frame_buffer = &frame_buffer,
            });
            try testing.expectError(error.DeadlineUnsupported, driver.read(12345));
            var owner: ReadCauseProbe = .{ .read_error = failure };
            driver.read_deadline = .{
                .context = &owner,
                .set = ReadCauseProbe.set,
                .cause = ReadCauseProbe.cause,
            };
            const result = driver.read(deadline_ns);
            switch (failure) {
                error.Timeout, error.TimedOut => if (deadline_ns != null)
                    try testing.expectEqual(Driver.ReadResult.timeout, try result)
                else
                    try testing.expectError(failure, result),
                error.WouldBlock => try testing.expectEqual(Driver.ReadResult.ready, try result),
                else => try testing.expectError(failure, result),
            }
            try testing.expectEqual(deadline_ns, owner.observed);
            const terminal = switch (failure) {
                error.Timeout, error.TimedOut => deadline_ns == null,
                error.Canceled,
                error.WouldBlock,
                error.DeadlineUnsupported,
                error.NoReadCompletion,
                => false,
                else => true,
            };
            try testing.expectEqual(terminal, driver.isClosed());
            if (terminal) {
                try testing.expectEqual(failure, driver.failureCause().?);
                try testing.expectError(error.ConnectionClosed, driver.read(null));
                try testing.expectError(error.ConnectionClosed, driver.flush());
            }
        }
    }
}

test "untimed socket reads preserve reset and cancellation causes" {
    const Probe = struct {
        const Self = @This();
        canceled: bool,
        reads: usize = 0,

        fn operate(
            context: ?*anyopaque,
            operation: Io.Operation,
        ) Io.Cancelable!Io.Operation.Result {
            const self: *Self = @ptrCast(@alignCast(context.?));
            assert(operation == .net_read);
            self.reads += 1;
            if (self.canceled) return error.Canceled;
            return .{ .net_read = error.ConnectionResetByPeer };
        }

        fn netRead(
            context: ?*anyopaque,
            _: Io.net.Socket.Handle,
            _: [][]u8,
        ) Io.net.Stream.Reader.Error!usize {
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.reads += 1;
            if (self.canceled) return error.Canceled;
            return error.ConnectionResetByPeer;
        }
    };
    for ([_]bool{ false, true }) |canceled| {
        var probe: Probe = .{ .canceled = canceled };
        var vtable = testing.io.vtable.*;
        if (comptime @hasField(Io.VTable, "netRead")) {
            vtable.netRead = Probe.netRead;
        } else {
            vtable.operate = Probe.operate;
        }
        const io: Io = .{ .userdata = &probe, .vtable = &vtable };
        var conn: Connection = undefined;
        try conn.init(.{ .allocator = testing.allocator });
        defer conn.deinit();
        var reader = Io.Reader.fixed("\x00\x00\x00\x04\x00\x00\x00\x00\x00");
        var writer = Io.Writer.failing;
        var read_buffer: [64]u8 = undefined;
        var frame_buffer: [16 * 1024 + 9]u8 = undefined;
        var driver: Driver = undefined;
        driver.init(&conn, &reader, &writer, .{
            .read_buffer = &read_buffer,
            .frame_buffer = &frame_buffer,
            .wait = .{ .socket = .{ .io = io, .fd = -1 } },
        });
        try testing.expectEqual(Driver.ReadResult.ready, try driver.read(null));
        try testing.expectEqual(@as(usize, 0), probe.reads);
        try testing.expectEqual(@as(usize, 0), reader.bufferedLen());
        _ = try conn.poll();
        try testing.expect(conn.session.settings_received);
        const failure = if (canceled) error.Canceled else error.ConnectionResetByPeer;
        try testing.expectError(failure, driver.read(null));
        try testing.expectEqual(@as(usize, 1), probe.reads);
        try testing.expectEqual(!canceled, driver.isClosed());
        if (!canceled) try testing.expectEqual(failure, driver.failureCause().?);
    }
}

test "timed reads reap pending batches and retain completions that race cancellation" {
    if (comptime @hasField(Io.Operation, "net_read")) {
        const Probe = @import("driver_test_io.zig").BatchProbe;
        const Scenario = enum {
            timeout,
            canceled,
            unsupported,
            missing,
            timeout_race,
            canceled_race,
        };
        for (std.enums.values(Scenario)) |scenario| {
            var probe: Probe = .init(
                switch (scenario) {
                    .timeout, .timeout_race => error.Timeout,
                    .canceled, .canceled_race => error.Canceled,
                    .unsupported => error.ConcurrencyUnavailable,
                    .missing => null,
                },
                switch (scenario) {
                    .timeout_race, .canceled_race => 0,
                    else => null,
                },
            );
            var vtable = testing.io.vtable.*;
            vtable.batchAwaitConcurrent = Probe.awaitConcurrent;
            vtable.batchCancel = Probe.cancel;
            const io: Io = .{ .userdata = &probe, .vtable = &vtable };
            var conn: Connection = undefined;
            try conn.init(.{ .allocator = testing.allocator });
            defer conn.deinit();
            var reader = Io.Reader.fixed("");
            var writer = Io.Writer.failing;
            var read_buffer: [64]u8 = undefined;
            var frame_buffer: [16 * 1024 + 9]u8 = undefined;
            var driver: Driver = undefined;
            driver.init(&conn, &reader, &writer, .{
                .read_buffer = &read_buffer,
                .frame_buffer = &frame_buffer,
            });
            const result = driver.readSocket17(io, -1, .none);
            switch (scenario) {
                .timeout => try testing.expectEqual(Driver.ReadResult.timeout, try result),
                .canceled, .canceled_race => try testing.expectError(error.Canceled, result),
                .unsupported => try testing.expectError(error.DeadlineUnsupported, result),
                .missing => try testing.expectError(error.NoReadCompletion, result),
                .timeout_race => try testing.expectEqual(Driver.ReadResult.ready, try result),
            }
            try testing.expect(probe.cancel_called);
            if (probe.complete_on_cancel != null) {
                // The racing byte is the first byte of SETTINGS. Its remaining
                // eight bytes must complete that frame, not a shifted header.
                const rest = "\x00\x00\x04\x00\x00\x00\x00\x00";
                try testing.expectEqual(rest.len, conn.receive(rest));
                _ = try conn.poll();
                try testing.expect(conn.session.settings_received);
            }
        }
    } else return error.SkipZigTest;
}

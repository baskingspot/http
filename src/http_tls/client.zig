//! A blocking plaintext connection over TLS.
//!
//! The step-shaped `transport.tls_client` is the primitive; this is the
//! convenience a caller holding a socket actually wants: an `Io.Reader` and an
//! `Io.Writer` that speak plaintext, with one deadline for the whole call. This
//! is the same service `transport/plain.zig` provides over a bare socket, one
//! decryption later, so an HTTP/1.1 client can use it unchanged.
//!
//! An `Io.Reader` has no timeout of its own and no way to report one, so the
//! connection owns the deadline and the caller reads `expired` after a failure.
//!
//! Four rules hold this together, each one learned from a silent failure:
//!
//! 1. The deadline belongs here, never at the socket. Polling the fd under TLS
//!    hands whatever reads next a raw record; an HTTP/2 parser reads `17 03 03`
//!    as a 24-bit frame length and fails with `FRAME_SIZE_ERROR` that points
//!    nowhere near the fault.
//! 2. Socket bytes go into `wireBuffer`, which is the storage the record layer
//!    decrypts from, and never into a buffer of this module's own.
//! 3. A frame does not fit one TLS record. `write` takes a prefix, so the
//!    writer tracks an offset and never moves on with bytes still queued.
//! 4. Flush before every blocking read. During the handshake the peer is
//!    waiting on our ClientHello and will not answer until it arrives.
//! 5. `endInput` is not how a wait ends. It means the transport saw EOF and
//!    surfaces as `error.UnexpectedEof`; a deadline stops driving and releases
//!    the slot, nothing more.
//!
//! There is no plaintext copy here. The transport keeps the delivered slice
//! pinned until it is consumed, and a partial consume keeps the tail, so the
//! reader hands over what fits and consumes exactly that much.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = @import("http");
const http_tls = @import("http_tls");

const Transport = http_tls.h2.transport.tls_client.Transport;
const builtin = @import("builtin");

/// The platform syscall module the transport's `send` and `receive` want.
const Platform = switch (builtin.os.tag) {
    .linux => http.h2.engine.wait_poll.Wait.Platform,
    .macos => http.h2.engine.wait_kqueue.Wait.Platform,
    else => http.h2.engine.wait_poll.Wait.Platform,
};

pub const Error = error{
    /// The handshake finished without the ALPN protocol this client requires.
    WrongAlpn,
    /// The peer closed before the handshake completed.
    HandshakeClosed,
};

// ast-grep-ignore: public-struct-field-default -- init sets identity, rest is buffers
pub const Connection = struct {
    io: Io,
    allocator: Allocator,
    socket: Io.net.Stream,
    slot: Transport.Slot = undefined,
    bundle: http_tls.Bundle = undefined,
    input: Io.Reader = undefined,
    output: Io.Writer = undefined,
    /// Absolute monotonic nanoseconds for the next socket wait.
    deadline_ns: ?i96 = null,
    /// Set when a wait ended because the deadline passed. `Io.Reader.Error` has
    /// no timeout to report, so the caller reads this after a failed call.
    expired: bool = false,
    open: bool = false,
    required_alpn: []const u8 = "h2",

    /// Fields a caller controls.
    // ast-grep-ignore: public-struct-field-default -- options bag; alpn defaults to h2
    pub const Options = struct {
        /// PEM certificate blocks, as handed by a caller that already holds
        /// them. At least one anchor must load.
        ca_pem: []const u8,
        /// ASCII DNS name for SNI and the DNS-ID check. The caller owns the
        /// bytes and must keep them alive for the connection's lifetime.
        host_name: []const u8,
        /// Current time in seconds since the Unix epoch, for certificate
        /// validity.
        now_sec: i64,
        /// The one ALPN protocol to require.
        alpn: []const u8 = "h2",
    };

    pub fn init(
        self: *Connection,
        allocator: Allocator,
        io: Io,
        socket: Io.net.Stream,
        options: Options,
    ) !void {
        self.* = .{
            .io = io,
            .allocator = allocator,
            .socket = socket,
            .required_alpn = options.alpn,
        };

        self.bundle = try http_tls.anchors.build(allocator, options.ca_pem, options.now_sec);
        errdefer self.bundle.deinit(allocator);

        self.slot = try Transport.init(
            allocator,
            io,
            socket.socket.handle,
            .{
                .ca = &self.bundle,
                .host_name = options.host_name,
                .now_sec = options.now_sec,
                .alpn = options.alpn,
            },
            0,
            0,
        );
        self.open = true;

        self.input = .{
            .vtable = &.{
                .stream = stream,
                .readVec = readVec,
            },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        };
        self.output = .{
            .vtable = &.{
                .drain = drain,
                .flush = flush,
                .rebase = rebase,
            },
            .buffer = &.{},
            .end = 0,
        };

        try self.handshake();
    }

    pub fn deinit(self: *Connection) void {
        if (self.open) {
            self.open = false;
            self.slot.deinit();
        }
        self.bundle.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reader(self: *Connection) *Io.Reader {
        return &self.input;
    }

    pub fn writer(self: *Connection) *Io.Writer {
        return &self.output;
    }

    /// The call's deadline, so a socket wait can end when the call does.
    pub fn setDeadline(self: *Connection, absolute_ns: ?i96) void {
        self.deadline_ns = absolute_ns;
    }

    fn handshake(self: *Connection) !void {
        while (true) {
            switch (try self.slot.next()) {
                .handshake_complete => {
                    const alpn = self.slot.selectedAlpn() orelse return error.WrongAlpn;
                    if (!std.mem.eql(u8, alpn, self.required_alpn)) return error.WrongAlpn;
                    return;
                },
                .need_input => {
                    self.slot.send(Platform) catch return error.HandshakeClosed;
                    const ready = self.readSocket() catch return error.HandshakeClosed;
                    if (!ready) return error.HandshakeClosed;
                },
                .need_output => self.slot.send(Platform) catch return error.HandshakeClosed,
                .progress => {},
                .application_data => {
                    // Plaintext can arrive before the completion event: the
                    // server's SETTINGS routinely shares a flight with its
                    // Finished, and it is already HTTP/2. Dropping it misaligns
                    // the frame stream. The slice stays pinned until consumed,
                    // so the handshake simply ends here and the first read
                    // collects it.
                    const alpn = self.slot.selectedAlpn() orelse return error.HandshakeClosed;
                    if (!std.mem.eql(u8, alpn, self.required_alpn)) return error.WrongAlpn;
                    return;
                },
                .closed => return error.HandshakeClosed,
            }
        }
    }

    fn stream(
        erased: *Io.Reader,
        w: *Io.Writer,
        limit: Io.Limit,
    ) Io.Reader.StreamError!usize {
        _ = erased;
        _ = w;
        _ = limit;
        return error.EndOfStream;
    }

    fn readVec(erased: *Io.Reader, iovecs: [][]u8) Io.Reader.Error!usize {
        return connectionOf(erased, "input").fill(iovecs);
    }

    fn drain(erased: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        return pushAll(connectionOf(erased, "output"), erased, data, splat);
    }

    fn flush(erased: *Io.Writer) Io.Writer.Error!void {
        const self = connectionOf(erased, "output");
        self.slot.send(Platform) catch return error.WriteFailed;
    }

    fn rebase(erased: *Io.Writer, preserve: usize, capacity: usize) Io.Writer.Error!void {
        // The bridge writes straight through, so it never rebases a buffer.
        _ = erased;
        _ = preserve;
        _ = capacity;
    }

    /// Hand plaintext to the transport, taking a prefix at a time and sending
    /// between attempts. Never returns with bytes still queued.
    fn push(
        self: *Connection,
        w: *Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) Io.Writer.Error!usize {
        var total: usize = 0;

        if (w.end != 0) {
            const buffered = w.buffer[0..w.end];
            w.end = 0;
            total += try self.pushSlice(buffered);
        }

        for (data, 0..) |slice, index| {
            const repeat = if (index + 1 == data.len) splat else 1;
            var copy: usize = 0;
            while (copy < repeat) : (copy += 1) total += try self.pushSlice(slice);
        }
        return total;
    }

    fn pushSlice(self: *Connection, bytes: []const u8) Io.Writer.Error!usize {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const accepted = self.slot.write(bytes[offset..]) catch return error.WriteFailed;
            offset += accepted;
            self.slot.send(Platform) catch return error.WriteFailed;
            if (accepted == 0) {
                // The transport still owes output. Yield rather than spin.
                self.io.sleep(.fromMilliseconds(1), .awake) catch return error.WriteFailed;
            }
        }
        return offset;
    }

    /// Return plaintext to the caller, stepping the transport as needed.
    ///
    /// The transport is the buffer. `application_data` stays pinned until it is
    /// consumed, and a partial consume keeps the tail: the next `next()` hands
    /// back exactly the remainder. So this consumes only what it handed over and
    /// copies nothing.
    fn fill(self: *Connection, iovecs: [][]u8) Io.Reader.Error!usize {
        while (true) {
            switch (self.slot.next() catch return error.ReadFailed) {
                .application_data => |bytes| {
                    const copied = copyInto(iovecs, bytes);
                    self.slot.consume(@intCast(copied));
                    return copied;
                },
                .need_input => {
                    // Flush first: during the handshake the peer is waiting on
                    // our ClientHello and will not answer until it arrives.
                    self.slot.send(Platform) catch return error.ReadFailed;
                    if (!(self.readSocket() catch return error.ReadFailed)) return 0;
                },
                .need_output => self.slot.send(Platform) catch return error.ReadFailed,
                .progress, .handshake_complete => {},
                .closed => return 0,
            }
        }
    }

    /// Read the socket once into the transport's own buffer and commit it.
    /// False on EOF.
    ///
    /// The bytes must land in `receiveBuffer`, because that is the storage the
    /// TLS layer decrypts from; reading into a private buffer and reporting a
    /// count produces `RecordTooLarge` on the first record. An empty buffer
    /// means the transport still owes output, not that the peer closed.
    fn readSocket(self: *Connection) !bool {
        const buffer = self.slot.wireBuffer();
        if (buffer.len == 0) {
            self.slot.send(Platform) catch return error.WriteFailed;
            return true;
        }

        if (self.deadline_ns) |deadline| {
            const now = Io.Clock.awake.now(self.io).nanoseconds;
            if (now >= deadline) {
                self.expired = true;
                return error.TimedOut;
            }
            const give_up: Io.Clock.Timestamp = Io.Timestamp
                .fromNanoseconds(deadline)
                .withClock(Io.Clock.awake);

            var storage: [1]Io.Operation.Storage = undefined;
            var batch: Io.Batch = .init(&storage);
            var iovecs: [1][]u8 = .{buffer};
            _ = batch.add(.{ .net_read = .{
                .socket_handle = self.socket.socket.handle,
                .data = &iovecs,
            } });
            batch.awaitConcurrent(self.io, .{ .deadline = give_up }) catch |err| switch (err) {
                error.Timeout, error.Canceled => {
                    self.expired = true;
                    return error.TimedOut;
                },
                error.ConcurrencyUnavailable => return error.DeadlineUnsupported,
            };
            while (batch.next()) |completion| {
                switch (completion.result) {
                    .net_read => |result| {
                        const ready = try result;
                        if (ready.data_len == 0) return false;
                        self.slot.wireReceived(ready.data_len);
                        return true;
                    },
                    else => {},
                }
            }
            self.expired = true;
            return error.TimedOut;
        }

        var iovecs: [1][]u8 = .{buffer};
        var transport_reader = self.socket.reader(self.io, &.{});
        const n = transport_reader.interface.readVec(&iovecs) catch |err| switch (err) {
            error.EndOfStream => return false,
            else => return err,
        };
        if (n == 0) return false;
        self.slot.wireReceived(n);
        return true;
    }
};

fn connectionOf(erased: anytype, comptime field: []const u8) *Connection {
    const base: [*]u8 = @ptrCast(erased);
    const address = @intFromPtr(base) - @offsetOf(Connection, field);
    const pointer: *Connection = @ptrFromInt(address);
    return @alignCast(pointer);
}

fn pushAll(
    self: *Connection,
    w: *Io.Writer,
    data: []const []const u8,
    splat: usize,
) Io.Writer.Error!usize {
    return self.push(w, data, splat);
}

fn copyInto(iovecs: [][]u8, bytes: []const u8) usize {
    var copied: usize = 0;
    for (iovecs) |iov| {
        if (copied == bytes.len) break;
        const take = @min(iov.len, bytes.len - copied);
        @memcpy(iov[0..take], bytes[copied..][0..take]);
        copied += take;
    }
    return copied;
}

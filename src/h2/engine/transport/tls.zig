//! The h2-over-TLS byte transport for the readiness engines.
//!
//! `tls_nonblocking` turns wire records into borrowed plaintext and accepts
//! h2 output one record at a time. The transport owns the per-slot TLS state
//! and buffers; the readiness loop only sees `transport.Event`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fd_t = std.posix.fd_t;

const http = @import("http");
const tls = @import("tls");
const tls_nonblocking = @import("tls_nonblocking");
const wait = http.h2.engine.wait;
const common = http.h2.engine.transport;
const Event = common.Event;

const TlsServer = tls_nonblocking.Server;
const Handshake = tls.ServerHandshake;

pub const Transport = struct {
    // ast-grep-ignore: public-struct-field-default -- options bag; call sites override one knob
    pub const Options = struct {
        /// Reusable server policy. Each slot supplies its own ephemeral keys,
        /// random value, and handshake storage.
        handshake: Handshake.ServerConfig = .{},
        cert_chain: []const []const u8,
        signer: tls.signature.Signer,
        /// Required ALPN protocol. The handshake fails without it.
        alpn: []const u8 = "h2",
        /// Per-connection storage for a verified client leaf certificate.
        /// Zero supplies no client-certificate storage.
        client_cert_bytes: usize = 0,
    };

    pub fn defaultOptions() ?Options {
        return null;
    }

    pub fn init(
        allocator: Allocator,
        io: Io,
        fd: fd_t,
        options: Options,
        read_bytes: usize,
        write_bytes: usize,
    ) anyerror!Slot {
        return SlotImpl.init(allocator, io, fd, options, read_bytes, write_bytes);
    }

    pub const Slot = *SlotImpl;

    const SlotImpl = struct {
        server: TlsServer,
        record: [tls.RecordBuffer.min_storage]u8,
        out: [tls.frame.max_wire_record_len]u8,
        reassembly: [Handshake.ch_reassembly_buffer_size]u8,
        client_cert: []u8,
        fd: fd_t,
        required_alpn: []const u8,
        allocator: Allocator,
        /// The peer's fatal alert, latched the moment `next` sees it. The
        /// handshake drops it once the transport reaches `.closed`, so a
        /// consumer must not wait for a later `next` to read it.
        peer_alert: ?tls.alert.Alert,

        pub fn init(
            allocator: Allocator,
            io: Io,
            fd: fd_t,
            options: Options,
            _: usize,
            _: usize,
        ) anyerror!*SlotImpl {
            const self = try allocator.create(SlotImpl);
            errdefer allocator.destroy(self);

            self.client_cert = if (options.client_cert_bytes == 0)
                &.{}
            else
                try allocator.alloc(u8, options.client_cert_bytes);
            errdefer if (self.client_cert.len != 0) allocator.free(self.client_cert);

            var config: Handshake.Config = .{
                .keypairs = try .init(.generate()),
                .random = undefined,
                .reassembly = &self.reassembly,
            };
            defer config.keypairs.secureZero();
            defer config.random.secureZero();
            try io.randomSecure(&config.random.data);
            if (self.client_cert.len != 0) config.client_cert_buffer = self.client_cert;

            try self.server.init(&.{
                .handshake = options.handshake,
                .cert_chain = options.cert_chain,
                .signer = options.signer,
            }, config, .{ .record = &self.record, .out = &self.out });

            self.fd = fd;
            self.required_alpn = options.alpn;
            self.allocator = allocator;
            self.peer_alert = null;
            return self;
        }

        pub fn deinit(self: *SlotImpl) void {
            self.server.deinit();
            std.crypto.secureZero(u8, &self.record);
            std.crypto.secureZero(u8, &self.out);
            std.crypto.secureZero(u8, &self.reassembly);
            if (self.client_cert.len != 0) {
                std.crypto.secureZero(u8, self.client_cert);
                self.allocator.free(self.client_cert);
            }
            const allocator = self.allocator;
            allocator.destroy(self);
        }

        pub fn receive(self: *SlotImpl, comptime P: type) anyerror!void {
            const dest = self.server.receiveBuffer();
            if (dest.len == 0) return;
            const n = P.read(self.fd, dest) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (n == 0) {
                self.server.endInput();
                return;
            }
            self.server.received(n);
        }

        pub fn next(self: *SlotImpl) anyerror!Event {
            const outcome = self.server.next();
            // Latch before mapping: the handshake drops the alert once the
            // transport reaches `.closed`, and a peer alert discards output,
            // so there is nothing to drain first.
            if (outcome) |_| {} else |err| {
                if (err == error.PeerAlert and self.peer_alert == null) {
                    self.peer_alert = self.server.lastPeerAlert();
                }
            }
            return mapOutcome(
                outcome,
                self.server.sendBuffer().len != 0,
                self.server.selectedAlpn(),
                self.required_alpn,
            );
        }

        pub fn consume(self: *SlotImpl, n: usize) void {
            self.server.consumeApplication(n);
        }

        pub fn write(self: *SlotImpl, bytes: []const u8) anyerror!usize {
            return self.server.write(bytes) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };
        }

        pub fn send(self: *SlotImpl, comptime P: type) anyerror!void {
            const wire = self.server.sendBuffer();
            if (wire.len == 0) return;
            const n = P.send(self.fd, &.{}, wire) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (n == 0) return error.Closed;
            self.server.sent(n);
        }

        pub fn interest(self: *SlotImpl) wait.Interest {
            var result: wait.Interest = .empty;
            if (self.server.receiveBuffer().len != 0) result.insert(.read);
            if (self.server.sendBuffer().len != 0) result.insert(.write);
            return result;
        }

        pub fn canWrite(self: *const SlotImpl) bool {
            return self.server.isConnected();
        }

        pub fn closeWrite(self: *SlotImpl) anyerror!void {
            self.server.closeWrite() catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
        }

        pub fn selectedAlpn(self: *const SlotImpl) ?[]const u8 {
            return self.server.selectedAlpn();
        }

        /// The peer's fatal alert after `next` returned `error.PeerAlert`.
        /// Distinguishes a handshake failure from a clean close: `alert.level`
        /// and `alert.description` name the cause, where the error alone does
        /// not. Null when the peer closed cleanly or no alert arrived.
        pub fn peerAlert(self: *const SlotImpl) ?tls.alert.Alert {
            return self.peer_alert;
        }
    };
};

/// The policy from one `tls_nonblocking` step to one `transport.Event`.
///
/// Pure over its inputs so the mapping can be pinned without a handshake.
/// `Slot.next` supplies the live values: whether wire output is queued, the
/// selected ALPN, and the protocol this transport requires.
pub fn mapOutcome(
    outcome: anyerror!TlsServer.Event,
    has_output: bool,
    selected_alpn: ?[]const u8,
    required_alpn: []const u8,
) anyerror!Event {
    const event = outcome catch |err| switch (err) {
        // The peer half-closed, or the transport is done. Not an error.
        error.Closed => return .closed,
        // A peer alert discards output, so it is never masked by a drain.
        error.PeerAlert => return err,
        else => {
            // A local fatal error may have prepared an alert. Drain it before
            // the slot closes; the retry returns the original error.
            if (has_output) return .need_output;
            return err;
        },
    };
    return switch (event) {
        .need_input => .need_input,
        .need_output => .need_output,
        .progress => .progress,
        .handshake_complete => blk: {
            const alpn = selected_alpn orelse return error.NoAlpn;
            if (!std.mem.eql(u8, alpn, required_alpn)) return error.WrongAlpn;
            break :blk .handshake_complete;
        },
        .application_data => |bytes| .{ .application_data = bytes },
        .early_data => error.EarlyDataUnsupported,
        .key_update => .progress,
        // close_notify ends the peer's sending direction. The socket is not
        // over: `canWrite` decides whether ours is still open.
        .close_notify, .closed => .closed,
    };
}

const testing = std.testing;

fn expectEvent(expected: std.meta.Tag(Event), outcome: anyerror!TlsServer.Event) !void {
    const actual = try mapOutcome(outcome, false, "h2", "h2");
    try testing.expectEqual(expected, std.meta.activeTag(actual));
}

test "a peer close is an event, a truncation is an error" {
    // close_notify and a full close both mean the peer sends nothing more.
    try expectEvent(.closed, .close_notify);
    try expectEvent(.closed, .closed);
    try expectEvent(.closed, error.Closed);

    // EOF without close_notify is a truncation and must never read as a close.
    try testing.expectError(
        error.UnexpectedEof,
        mapOutcome(error.UnexpectedEof, false, "h2", "h2"),
    );
}

test "a peer alert is never masked by a drain" {
    try testing.expectError(error.PeerAlert, mapOutcome(error.PeerAlert, false, "h2", "h2"));
    try testing.expectError(error.PeerAlert, mapOutcome(error.PeerAlert, true, "h2", "h2"));
    // A local fatal error drains its prepared alert first, then reports.
    try testing.expectEqual(
        Event.need_output,
        try mapOutcome(error.UnexpectedMessage, true, "h2", "h2"),
    );
    try testing.expectError(
        error.UnexpectedMessage,
        mapOutcome(error.UnexpectedMessage, false, "h2", "h2"),
    );
}

test "the handshake requires the configured ALPN" {
    try expectEvent(.handshake_complete, .handshake_complete);
    try testing.expectError(error.NoAlpn, mapOutcome(.handshake_complete, false, null, "h2"));
    try testing.expectError(
        error.WrongAlpn,
        mapOutcome(.handshake_complete, false, "http/1.1", "h2"),
    );
}

test "every arm maps to exactly one outcome" {
    try testing.expectError(
        error.EarlyDataUnsupported,
        mapOutcome(.{ .early_data = "" }, false, "h2", "h2"),
    );
    try expectEvent(.progress, .{ .key_update = .update_not_requested });
    try expectEvent(.need_input, .need_input);
    try expectEvent(.need_output, .need_output);
    try expectEvent(.progress, .progress);
    try expectEvent(.application_data, .{ .application_data = "x" });
}

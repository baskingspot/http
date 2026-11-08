//! The h2-over-TLS client byte transport.
//!
//! `tls_nonblocking.Client` turns wire records into borrowed plaintext and
//! accepts h2 output one record at a time. This transport owns the per-slot
//! TLS state and buffers, and exposes the same `transport.Event` union as the
//! h2c and TLS server transports, so one driver shape serves all three.
//!
//! Two rules a driver must hold, because both fail silently:
//!
//! - A full h2 frame does not fit one TLS record. `out_frame_payload` is 16384,
//!   so a maximal DATA frame is 16393 bytes, and `tls.frame.max_plaintext_len`
//!   is 16384. `write` accepts a prefix; the remainder must be retried before
//!   the next frame is queued, or one frame's tail lands behind another's head.
//! - Drain pending output before blocking on a read. During the handshake and
//!   around a key update the transport owes the peer bytes, and a peer waiting
//!   on them will never send. `need_output` is the transport saying it has
//!   output now, not the only time it can have it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fd_t = std.posix.fd_t;

const tls = @import("tls");
const tls_nonblocking = @import("tls_nonblocking");

const http = @import("http");
const wait = http.h2.engine.wait;
const common = http.h2.engine.transport;
const Event = common.Event;

const Client = tls_nonblocking.Client;
const Server = tls_nonblocking.Server;
const Handshake = tls.ClientHandshake;
const ServerHandshake = tls.ServerHandshake;
const Bundle = std.crypto.Certificate.Bundle;

pub const Transport = struct {
    // ast-grep-ignore: public-struct-field-default -- options bag; alpn defaults to h2
    pub const Options = struct {
        /// Trust anchors, built by `http_tls.anchors.build`. The caller owns the
        /// bundle and must keep it alive for the transport's lifetime. Null
        /// trusts nothing, so every handshake fails verification unless
        /// `insecure_no_chain_anchor` is set.
        ca: ?*const Bundle = null,
        /// Test/demo opt-out from chain verification. Never set in production.
        insecure_no_chain_anchor: bool = false,
        /// ASCII DNS name for SNI and the DNS-ID SAN check. The caller owns the
        /// bytes and must keep them alive for the transport's lifetime. A dial
        /// to an IP address still needs the DNS name here, because the SAN is
        /// matched by name.
        host_name: ?[]const u8 = null,
        /// Current time in seconds since the Unix epoch, for certificate
        /// validity. The caller supplies the clock.
        now_sec: i64 = 0,
        /// The one ALPN protocol to offer. The handshake fails with
        /// `error.NoAlpn` or `error.WrongAlpn` unless the server selects it.
        alpn: []const u8 = "h2",
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
        client: Client,
        record: [tls.RecordBuffer.min_storage]u8,
        out: [tls.frame.max_wire_record_len]u8,
        /// Handshake-message reassembly. A client must hold the server's
        /// Certificate chain, which routinely spans records.
        reassembly: [Handshake.recommended_handshake_storage]u8,
        /// `Client.Options.alpn` is a list the handshake keeps referring to, so
        /// the one-entry list must outlive `init`. A stack temporary here would
        /// dangle at ClientHello2 after a HelloRetryRequest.
        alpn_list: [1][]const u8,
        fd: fd_t,
        required_alpn: []const u8,
        allocator: Allocator,
        /// The peer's fatal alert, latched the moment `next` sees it, because
        /// the handshake drops it once the transport reaches `.closed`.
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

            self.alpn_list = .{options.alpn};
            self.fd = fd;
            self.required_alpn = options.alpn;
            self.allocator = allocator;
            self.peer_alert = null;

            var config: Handshake.Config = .{
                .keypairs = try .init(.generate()),
                .host_name = options.host_name,
                .now_sec = options.now_sec,
                .random = undefined,
                .reassembly = &self.reassembly,
            };
            defer config.keypairs.secureZero();
            defer config.random.secureZero();
            try io.randomSecure(&config.random.data);

            try self.client.init(
                &.{
                    .ca = options.ca,
                    .insecure_no_chain_anchor = options.insecure_no_chain_anchor,
                    .host_name = options.host_name,
                    .now_sec = options.now_sec,
                    .alpn = &self.alpn_list,
                },
                config,
                .{ .record = &self.record, .out = &self.out },
            );
            return self;
        }

        pub fn deinit(self: *SlotImpl) void {
            self.client.deinit();
            std.crypto.secureZero(u8, &self.record);
            std.crypto.secureZero(u8, &self.out);
            std.crypto.secureZero(u8, &self.reassembly);
            const allocator = self.allocator;
            allocator.destroy(self);
        }

        pub fn receive(self: *SlotImpl, comptime P: type) anyerror!void {
            const dest = self.client.receiveBuffer();
            if (dest.len == 0) return;
            const n = P.read(self.fd, dest) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (n == 0) {
                self.client.endInput();
                return;
            }
            self.client.received(n);
        }

        /// Destination for a caller-owned socket read. This is **ciphertext**
        /// staging, not plaintext: the TLS layer decrypts out of it. On the h2c
        /// transport the same-looking buffer holds plaintext, and handing
        /// ciphertext to an HTTP/2 parser produces a plausible frame length and
        /// a `FRAME_SIZE_ERROR` that points nowhere near the real fault. Use
        /// `next` and `consume` for plaintext.
        ///
        /// Empty means the transport still owes output, not that the peer
        /// closed. Only a zero-length socket read is EOF, then `wireEndInput`.
        pub fn wireBuffer(self: *SlotImpl) []u8 {
            return self.client.receiveBuffer();
        }

        pub fn wireReceived(self: *SlotImpl, n: usize) void {
            self.client.received(n);
        }

        pub fn wireEndInput(self: *SlotImpl) void {
            self.client.endInput();
        }

        /// Ciphertext ready for a caller-owned socket write, not plaintext. The
        /// slice stays valid until `wireSent`, `deinit`, or a fatal peer alert.
        pub fn wireSendBuffer(self: *const SlotImpl) []const u8 {
            return self.client.sendBuffer();
        }

        pub fn wireSent(self: *SlotImpl, n: usize) void {
            self.client.sent(n);
        }

        pub fn next(self: *SlotImpl) anyerror!Event {
            const outcome = self.client.next();
            if (outcome) |_| {} else |err| {
                if (err == error.PeerAlert and self.peer_alert == null) {
                    self.peer_alert = self.client.lastPeerAlert();
                }
            }
            return mapOutcome(
                outcome,
                self.client.sendBuffer().len != 0,
                self.client.selectedAlpn(),
                self.required_alpn,
            );
        }

        pub fn consume(self: *SlotImpl, n: usize) void {
            self.client.consumeApplication(n);
        }

        pub fn write(self: *SlotImpl, bytes: []const u8) anyerror!usize {
            return self.client.write(bytes) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };
        }

        pub fn send(self: *SlotImpl, comptime P: type) anyerror!void {
            const wire = self.client.sendBuffer();
            if (wire.len == 0) return;
            const n = P.send(self.fd, &.{}, wire) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (n == 0) return error.Closed;
            self.client.sent(n);
        }

        pub fn interest(self: *SlotImpl) wait.Interest {
            var result: wait.Interest = .empty;
            if (self.client.receiveBuffer().len != 0) result.insert(.read);
            if (self.client.sendBuffer().len != 0) result.insert(.write);
            return result;
        }

        pub fn canWrite(self: *const SlotImpl) bool {
            return self.client.isConnected();
        }

        pub fn closeWrite(self: *SlotImpl) anyerror!void {
            self.client.closeWrite() catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
        }

        pub fn selectedAlpn(self: *const SlotImpl) ?[]const u8 {
            return self.client.selectedAlpn();
        }

        /// The peer's fatal alert after `next` returned `error.PeerAlert`.
        /// Null when the peer closed cleanly or no alert arrived.
        pub fn peerAlert(self: *const SlotImpl) ?tls.alert.Alert {
            return self.peer_alert;
        }
    };
};

/// The policy from one `tls_nonblocking.Client` step to one `transport.Event`.
///
/// Pure over its inputs so the mapping can be pinned without a handshake. The
/// client union has `new_session_ticket` and no `early_data`, so this is not
/// the server's function with a flag: the two switches differ.
pub fn mapOutcome(
    outcome: anyerror!Client.Event,
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
        .key_update => .progress,
        // A post-handshake ticket. The payload borrows the record buffer and
        // dies at this boundary; a caller that wants resumption calls
        // `deriveSessionTicket` while the event is fresh, above this layer.
        .new_session_ticket => .progress,
        // close_notify ends the peer's sending direction. The socket is not
        // over: `canWrite` decides whether ours is still open.
        .close_notify, .closed => .closed,
    };
}

const testing = std.testing;

fn expectEvent(expected: std.meta.Tag(Event), outcome: anyerror!Client.Event) !void {
    const actual = try mapOutcome(outcome, false, "h2", "h2");
    try testing.expectEqual(expected, std.meta.activeTag(actual));
}

test "a peer close is an event, a truncation is an error" {
    try expectEvent(.closed, .close_notify);
    try expectEvent(.closed, .closed);
    try expectEvent(.closed, error.Closed);

    try testing.expectError(
        error.UnexpectedEof,
        mapOutcome(error.UnexpectedEof, false, "h2", "h2"),
    );
}

test "a peer alert is never masked by a drain" {
    try testing.expectError(error.PeerAlert, mapOutcome(error.PeerAlert, false, "h2", "h2"));
    try testing.expectError(error.PeerAlert, mapOutcome(error.PeerAlert, true, "h2", "h2"));
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

test "every client arm maps to exactly one outcome" {
    try expectEvent(.progress, .{ .key_update = .update_not_requested });
    try expectEvent(.progress, .{
        .new_session_ticket = std.mem.zeroes(Handshake.NewSessionTicket),
    });
    try expectEvent(.need_input, .need_input);
    try expectEvent(.need_output, .need_output);
    try expectEvent(.progress, .progress);
    try expectEvent(.application_data, .{ .application_data = "x" });
}

test "the transport options default to h2 and trust nothing" {
    const options: Transport.Options = .{};
    try testing.expectEqualStrings("h2", options.alpn);
    try testing.expect(options.ca == null);
    try testing.expect(options.host_name == null);
}

// The public test certificate and scalar from `baskingspot/tls`. Not a
// deployment identity. DNS-only SAN: ztls.server.test.
const cert_b64 =
    "MIIByzCCAXKgAwIBAgIUbmarzBd+vWR/mRLY6OMXZSPvVQQwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQ" ++
    "enRscy5zZXJ2ZXIudGVzdDAeFw0yNjA2MDEwMTA3MzFaFw0zNjA1MjkwMTA3MzFaMBsxGTAXBgNVBAMM" ++
    "EHp0bHMuc2VydmVyLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATKaYKPBZrI1VlFanyJm97M" ++
    "16XUgwbBJkpHVern9TQuuQmG35VDsVMFA0FvUT6cigFaiHvB6NSZWczKYURvdTIlo4GTMIGQMB0GA1Ud" ++
    "DgQWBBQVmks0H0iMK08RcQYrOzH1jLnV0jAfBgNVHSMEGDAWgBQVmks0H0iMK08RcQYrOzH1jLnV0jAM" ++
    "BgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDATAbBgNVHREEFDAS" ++
    "ghB6dGxzLnNlcnZlci50ZXN0MAoGCCqGSM49BAMCA0cAMEQCIE7rvZ4pcB7M69DXnXztJ3RKJzHRMZg/" ++
    "jvjL7Ad2t9wZAiB7s3wziFsMpfnXGN05V/q29wgFLilNG8YQX6ssYxwWog==";

const scalar_b64 = "139HGdxmRe2N5F69cAY4IgK8B4ybwx0hgPE0siIOaeY=";

/// 2027-01-01T00:00:00Z, inside the fixture's validity window.
const fixture_now_sec: i64 = 1_798_761_600;

// The transport seam, end to end: ClientHello, ALPN, records, close_notify.
// Verification is deliberately off and `ca` is null, because the shared fixture
// certificate is an end entity (basicConstraints CA:FALSE) and cannot anchor
// itself. Note that `insecure_no_chain_anchor` is only consulted when `ca` is
// null: with a bundle present the anchor path runs regardless, and a non-CA
// anchor fails with `error.CertificateIssuerNotCa`. Trust-anchor loading is
// covered by the `anchors.build` tests in `http_tls`.
test "a client and server complete a handshake over pumpable buffers" {
    const io = testing.io;
    const allocator = testing.allocator;

    var cert_buf: [1024]u8 = undefined;
    const cert_len = try std.base64.standard.Decoder.calcSizeForSlice(cert_b64);
    try testing.expect(cert_len <= cert_buf.len);
    const cert = cert_buf[0..cert_len];
    try std.base64.standard.Decoder.decode(cert, cert_b64);

    var scalar: [32]u8 = undefined;
    try std.base64.standard.Decoder.decode(&scalar, scalar_b64);

    var private_key = try tls.signature.PrivateKey.fromP256Scalar(&scalar);
    defer private_key.deinit();

    // The peer is the raw client-side handle: it exposes the same buffer
    // pairing, so the test needs no socket, no fd, and no threads.
    var server: Server = undefined;
    var server_record: [tls.RecordBuffer.min_storage]u8 = undefined;
    var server_out: [tls.frame.max_wire_record_len]u8 = undefined;
    var server_reassembly: [ServerHandshake.ch_reassembly_buffer_size]u8 = undefined;
    var server_config: ServerHandshake.Config = .{
        .keypairs = try .init(.generate()),
        .random = undefined,
        .reassembly = &server_reassembly,
    };
    defer server_config.keypairs.secureZero();
    defer server_config.random.secureZero();
    try io.randomSecure(&server_config.random.data);
    try server.init(
        &.{
            .handshake = .{ .alpn_protocols = &.{"h2"} },
            .cert_chain = &.{cert},
            .signer = private_key.signer(),
        },
        server_config,
        .{ .record = &server_record, .out = &server_out },
    );
    defer server.deinit();

    const client = try Transport.init(
        allocator,
        io,
        -1,
        .{
            .ca = null,
            .insecure_no_chain_anchor = true,
            .host_name = "ztls.server.test",
            .now_sec = fixture_now_sec,
            .alpn = "h2",
        },
        0,
        0,
    );
    defer client.deinit();

    // A client slot is inert until stepped: the ClientHello comes out of the
    // first `next()`, not out of `init`.
    try testing.expect(!client.canWrite());

    var rounds: usize = 0;
    while ((!client.canWrite() or !server.isConnected()) and rounds < 400) : (rounds += 1) {
        pumpClientOut(client, &server);
        pumpServerOut(&server, client);
        try step(client);
        try step(&server);
    }

    try testing.expect(client.canWrite());
    try testing.expect(server.isConnected());
    try testing.expectEqualStrings("h2", client.selectedAlpn().?);
    try testing.expectEqualStrings("h2", server.selectedAlpn().?);
    try testing.expect(client.peerAlert() == null);

    // Application data crosses the seam and stays pinned until consumed.
    const sent = try client.write("hello");
    try testing.expectEqual(@as(usize, 5), sent);
    var received: [8]u8 = undefined;
    var received_len: usize = 0;
    rounds = 0;
    while (received_len < 5 and rounds < 100) : (rounds += 1) {
        pumpClientOut(client, &server);
        switch (try server.next()) {
            .application_data => |bytes| {
                @memcpy(received[received_len..][0..bytes.len], bytes);
                received_len += bytes.len;
                server.consumeApplication(bytes.len);
            },
            else => {},
        }
        try step(client);
    }
    try testing.expectEqualStrings("hello", received[0..received_len]);

    // Our close_notify ends our sending direction; the peer sees it as
    // `close_notify` and not as an error or a truncation.
    try client.closeWrite();
    rounds = 0;
    var peer_closed = false;
    while (!peer_closed and rounds < 100) : (rounds += 1) {
        pumpClientOut(client, &server);
        switch (try server.next()) {
            .close_notify, .closed => peer_closed = true,
            else => {},
        }
    }
    try testing.expect(peer_closed);
}

/// Move pending ciphertext from the client transport into the peer's staging
/// buffer. Both sides expose the wire buffer under different names because one
/// is our slot and the other is the `tls_nonblocking` handle.
fn pumpClientOut(from: anytype, to: anytype) void {
    const wire = from.wireSendBuffer();
    if (wire.len == 0) return;
    var copied: usize = 0;
    while (copied < wire.len) {
        const dest = to.receiveBuffer();
        if (dest.len == 0) break;
        const n = @min(dest.len, wire.len - copied);
        @memcpy(dest[0..n], wire[copied..][0..n]);
        to.received(n);
        copied += n;
    }
    from.wireSent(copied);
}

/// The same in the other direction.
fn pumpServerOut(from: anytype, to: anytype) void {
    const wire = from.sendBuffer();
    if (wire.len == 0) return;
    var copied: usize = 0;
    while (copied < wire.len) {
        const dest = to.wireBuffer();
        if (dest.len == 0) break;
        const n = @min(dest.len, wire.len - copied);
        @memcpy(dest[0..n], wire[copied..][0..n]);
        to.wireReceived(n);
        copied += n;
    }
    from.sent(copied);
}

/// One step: produce an event, ignoring everything but failure.
fn step(slot: anytype) !void {
    _ = try slot.next();
}

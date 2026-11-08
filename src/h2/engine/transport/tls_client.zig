//! The h2-over-TLS client byte transport.
//!
//! NOT IMPLEMENTED. `tls_nonblocking.Client` does not exist yet, so there is
//! nothing to wrap. This file commits the contract that grpc's driver is being
//! written against, and `init` fails loudly rather than pretending.
//!
//! What lands here when `Client` arrives, mirroring `transport/tls.zig`:
//!
//! - `init(allocator, io, fd, options, read_bytes, write_bytes)`. The fd and
//!   its lifetime are the caller's; both sizes are ignored, because the record
//!   and output buffers are fixed in the slot.
//! - `receive(P)`, `send(P)`, `next()`, `consume(n)`, `write(bytes)`.
//! - `canWrite`, `closeWrite`, `selectedAlpn`, `peerAlert`.
//!
//! Two rules a driver must hold, because both fail silently:
//!
//! - A full h2 frame does not fit one TLS record. `out_frame_payload` is 16384,
//!   so a maximal DATA frame is 16393 bytes, and `tls.frame.max_plaintext_len`
//!   is 16384. `write` accepts a prefix and the remainder must be retried
//!   before the next frame is queued.
//! - Drain pending output before blocking on a read. During the handshake and
//!   around a key update the transport owes the peer bytes, and a peer waiting
//!   on them will never send.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fd_t = std.posix.fd_t;

const Bundle = std.crypto.Certificate.Bundle;

pub const Transport = struct {
    // ast-grep-ignore: public-struct-field-default -- options bag; alpn defaults to h2
    pub const Options = struct {
        /// Trust anchors, built by `http_tls.anchors.build`. The caller owns the
        /// bundle and must keep it alive for the transport's lifetime. Null
        /// trusts nothing, so every handshake fails verification.
        ca: ?*const Bundle = null,
        /// Required ALPN protocol. `error.NoAlpn` and `error.WrongAlpn` fail
        /// the handshake rather than silently continuing.
        alpn: []const u8 = "h2",
    };

    pub const InitError = error{
        /// The TLS client transport is not built yet. See the module comment.
        ClientNotBuilt,
    };

    pub fn init(
        allocator: Allocator,
        io: Io,
        fd: fd_t,
        options: Options,
        read_bytes: usize,
        write_bytes: usize,
    ) InitError!void {
        _ = allocator;
        _ = io;
        _ = fd;
        _ = options;
        _ = read_bytes;
        _ = write_bytes;
        return error.ClientNotBuilt;
    }
};

const testing = std.testing;

test "the client transport refuses to pretend" {
    try testing.expectError(error.ClientNotBuilt, Transport.init(
        testing.allocator,
        testing.io,
        -1,
        .{},
        0,
        0,
    ));
}

test "the ALPN default is h2" {
    const options: Transport.Options = .{};
    try testing.expectEqualStrings("h2", options.alpn);
    try testing.expect(options.ca == null);
}

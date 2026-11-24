//! An HTTP/3 server over QUIC on loopback, for one connection.
//!
//! `quic-io` terminates TLS and QUIC; the engine sits above it and makes no
//! crypto call. The certificate is the public ECDSA fixture from
//! `baskingspot/tls`, not a deployment identity.
//!
//! `quic-io`'s endpoint holds one connection's storage, so this example
//! accepts one connection, serves it until the client closes, and exits. Run
//! it again for the next client.
//!
//! ```sh
//! just example-h3
//! curl -k --http3 https://127.0.0.1:8443/
//! ```

const std = @import("std");

const http = @import("http");
const quic_io = @import("quic-io");
const build_options = @import("build_options");

const limits: quic_io.SizingLimits = .{
    .streams = 16,
    .stream_ring = 16 * 1024,
    .peer_initial = 4,
    .preheat = 6,
};
const Engine = http.h3.engine.quic.Engine(limits);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const address: quic_io.IpAddress = .{ .ip4 = .loopback(8443) };
    const socket = try address.bind(io, .{ .mode = .dgram });

    var endpoint: Engine.Endpoint = undefined;
    try endpoint.listen(init.gpa, .{
        .io = io,
        .socket = socket,
        .certificate = @embedFile("tls_server_crt"),
        .key = @embedFile("tls_server_key"),
        .alpn = &.{"h3"},
        .parameters = .{
            .max_idle_timeout = 10_000,
            // The client's three unidirectional streams (control, encoder,
            // decoder), and four bidirectional streams so it may keep four
            // requests in flight. `peer_initial` advertises bidi only when both
            // counts are null, so name both.
            .initial_max_streams_bidi = 4,
            .initial_max_streams_uni = 3,
        },
    });
    defer endpoint.deinit(io);

    std.debug.print(
        "http3: one connection on 127.0.0.1:8443, crypto {s}\n",
        .{build_options.crypto},
    );
    try Engine.serve(io, init.gpa, &endpoint, .{ .context = undefined, .handle = handle });
}

fn handle(_: *anyopaque, exchange: *Engine.Exchange) anyerror!void {
    try exchange.respond(.ok, "text/plain", "hello from HTTP/3\n");
}

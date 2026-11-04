//! An HTTP/1.1 server over TLS 1.3 on the blocking engine.
//!
//!     just example-h1-tls
//!     curl -k https://127.0.0.1:8444/
//!
//! TLS comes from `baskingspot/tls` through `tls_std`. The handshake is
//! eager; its reader and writer are the plaintext transport for the h1
//! blocking engine. One thread per connection.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const http = @import("http");
const tls = @import("tls");
const tls_std = @import("tls_std");

const address_text = "127.0.0.1:8444";
const response_body = "h1 over tls hello\n";

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

const App = struct {
    fn handler() http.h1.engine.Handler {
        return .{ .ptr = undefined, .vtable = &.{
            .handle = handle,
            .complete = http.h1.engine.Handler.noopComplete,
            .report_error = reportError,
        } };
    }

    fn handle(_: *anyopaque, exchange: *http.h1.engine.Exchange) anyerror!void {
        try exchange.respond(.{
            .status = .ok,
            .content_type = "text/plain; charset=utf-8",
        }, response_body);
    }

    fn reportError(_: *anyopaque, err: anyerror) void {
        print("http1-tls: error: {s}\n", .{@errorName(err)});
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const address: Io.net.IpAddress = try .parseLiteral(address_text);

    var listener = try address.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
    });
    defer listener.deinit(io);

    print("http1-tls: listening on {s}\n", .{address_text});

    while (true) {
        const stream = listener.accept(io) catch |err| {
            print("http1-tls: accept: {s}\n", .{@errorName(err)});
            continue;
        };
        const thread = std.Thread.spawn(.{}, serveThread, .{ gpa, io, stream }) catch |err| {
            print("http1-tls: thread: {s}\n", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn serveThread(gpa: Allocator, io: Io, stream: Io.net.Stream) void {
    serveConnection(gpa, io, stream) catch |err| App.reportError(undefined, err);
}

fn serveConnection(gpa: Allocator, io: Io, stream: Io.net.Stream) !void {
    var cert_buf: [1024]u8 = undefined;
    const cert_len = try std.base64.standard.Decoder.calcSizeForSlice(cert_b64);
    const cert = cert_buf[0..cert_len];
    try std.base64.standard.Decoder.decode(cert, cert_b64);
    var scalar_buf: [32]u8 = undefined;
    try std.base64.standard.Decoder.decode(&scalar_buf, scalar_b64);

    var signer = try tls.signature.PrivateKey.fromP256Scalar(scalar_buf[0..32]);
    defer signer.deinit();

    var conn: tls_std.Server = undefined;
    try conn.accept(io, stream, .{
        .cert_chain = &.{cert},
        .signer = signer.signer(),
        .alpn = &.{"http/1.1"},
    });
    defer conn.deinit();
    defer conn.close();

    const alpn = conn.selectedAlpn() orelse return error.NoAlpn;
    if (!std.mem.eql(u8, alpn, "http/1.1")) return error.WrongAlpn;

    var request_buffer: [16 * 1024]u8 = undefined;
    var headers: [64]http.Header = undefined;
    var response_head: [1024]u8 = undefined;
    try http.h1.engine.blocking.serveIo(
        io,
        conn.reader(),
        conn.writer(),
        App.handler(),
        .{
            .allocator = gpa,
            .request_buffer = &request_buffer,
            .headers = &headers,
            .response_head_buffer = &response_head,
            .common = .{ .body_bytes = 8 * 1024 },
        },
    );
}

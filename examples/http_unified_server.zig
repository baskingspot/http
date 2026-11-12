//! One TLS port serving HTTP/1.1 and HTTP/2 by ALPN, plus one cleartext port
//! that sniffs the HTTP/2 connection preface.
//!
//!     just example-unified
//!     just curl https://127.0.0.1:8445/
//!     just curl --http2 http://127.0.0.1:8082/
//!     curl http://127.0.0.1:8082/
//!
//! The TLS handshake selects the protocol before any HTTP byte. On cleartext,
//! the first bytes distinguish the h2 preface from an HTTP/1 request; a small
//! reader replays them into the matching blocking engine.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const http = @import("http");
const tls = @import("tls");
const tls_std = @import("tls_std");
const tls_fixture = @import("tls_fixture.zig");

const address_text = "127.0.0.1:8445";
const cleartext_address_text = "127.0.0.1:8082";

const H1App = struct {
    fn handler() http.h1.engine.Handler {
        return .{ .ptr = undefined, .vtable = &.{
            .handle = handle,
            .complete = http.h1.engine.Handler.noopComplete,
            .report_error = reportError,
            .policy_response = http.h1.engine.Handler.defaultPolicyResponse,
        } };
    }

    fn handle(_: *anyopaque, exchange: *http.h1.engine.Exchange) anyerror!void {
        try exchange.respond(.{
            .status = .ok,
            .content_type = "text/plain; charset=utf-8",
        }, "h1 on the shared port\n");
    }

    fn reportError(_: *anyopaque, err: anyerror) void {
        print("unified: h1: {s}\n", .{@errorName(err)});
    }
};

const H2App = struct {
    fn handler() http.h2.engine.Handler {
        return .{ .ptr = undefined, .vtable = &.{
            .handle = handle,
            .complete = http.h2.engine.Handler.noopComplete,
            .report_error = reportError,
            .policy_response = http.h2.engine.Handler.defaultPolicyResponse,
        } };
    }

    fn handle(_: *anyopaque, exchange: *http.h2.engine.Exchange) anyerror!void {
        try exchange.respond(.{
            .status = .ok,
            .content_type = "text/plain; charset=utf-8",
        }, "h2 on the shared port\n");
    }

    fn reportError(_: *anyopaque, err: anyerror) void {
        print("unified: h2: {s}\n", .{@errorName(err)});
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const address: Io.net.IpAddress = try .parseLiteral(address_text);
    const cleartext_address: Io.net.IpAddress = try .parseLiteral(cleartext_address_text);

    var listener = try address.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
    });
    defer listener.deinit(io);

    var cleartext_listener = try cleartext_address.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
    });
    defer cleartext_listener.deinit(io);
    const cleartext_thread = try std.Thread.spawn(
        .{},
        cleartextAccept,
        .{ gpa, io, &cleartext_listener },
    );
    cleartext_thread.detach();

    print("unified: TLS on {s}, cleartext on {s}\n", .{
        address_text,
        cleartext_address_text,
    });

    while (true) {
        const stream = listener.accept(io) catch |err| {
            print("unified: accept: {s}\n", .{@errorName(err)});
            continue;
        };
        const thread = std.Thread.spawn(.{}, serveThread, .{ gpa, io, stream }) catch |err| {
            print("unified: thread: {s}\n", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn serveThread(gpa: Allocator, io: Io, stream: Io.net.Stream) void {
    serveConnection(gpa, io, stream) catch |err| {
        print("unified: connection: {s}\n", .{@errorName(err)});
    };
}

fn cleartextAccept(gpa: Allocator, io: Io, listener: *Io.net.Server) void {
    while (true) {
        const stream = listener.accept(io) catch |err| {
            print("unified: cleartext accept: {s}\n", .{@errorName(err)});
            continue;
        };
        const thread = std.Thread.spawn(.{}, cleartextThread, .{ gpa, io, stream }) catch |err| {
            print("unified: cleartext thread: {s}\n", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn cleartextThread(gpa: Allocator, io: Io, stream: Io.net.Stream) void {
    serveCleartext(gpa, io, stream) catch |err| {
        print("unified: cleartext connection: {s}\n", .{@errorName(err)});
    };
    stream.close(io);
}

fn serveCleartext(gpa: Allocator, io: Io, stream: Io.net.Stream) !void {
    var reader = stream.reader(io, &.{});
    var prefix_buffer: [h2_preface.len]u8 = undefined;
    var prefix_len: usize = 0;
    var maybe_h2 = true;
    while (prefix_len < h2_preface.len) {
        var one: [1]u8 = undefined;
        var iovecs: [1][]u8 = .{&one};
        const n = reader.interface.readVec(&iovecs) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        prefix_buffer[prefix_len] = one[0];
        prefix_len += 1;
        if (one[0] != h2_preface[prefix_len - 1]) {
            maybe_h2 = false;
            break;
        }
    }

    var prefixed = PrefixReader.init(prefix_buffer[0..prefix_len], &reader.interface);
    var write_buffer: [4 * 1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    if (maybe_h2 and prefix_len == h2_preface.len) {
        var h2_read_buffer: [16 * 1024]u8 = undefined;
        try http.h2.engine.blocking.serveIo(
            io,
            &prefixed.interface,
            &writer.interface,
            H2App.handler(),
            .{
                .allocator = gpa,
                .read_buffer = &h2_read_buffer,
                .write_buffer = &write_buffer,
                .wait_fd = .init(stream.socket.handle),
                .common = .{},
            },
        );
        return;
    }

    var request_buffer: [16 * 1024]u8 = undefined;
    var headers: [64]http.Header = undefined;
    var response_head: [1024]u8 = undefined;
    try http.h1.engine.blocking.serveIo(
        io,
        &prefixed.interface,
        &writer.interface,
        H1App.handler(),
        .{
            .allocator = gpa,
            .request_buffer = &request_buffer,
            .headers = &headers,
            .response_head_buffer = &response_head,
            .common = .{ .body_bytes = 8 * 1024 },
        },
    );
}

const h2_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

const PrefixReader = struct {
    prefix: []const u8,
    pos: usize,
    inner: *Io.Reader,
    interface: Io.Reader,

    fn init(prefix: []const u8, inner: *Io.Reader) PrefixReader {
        return .{
            .prefix = prefix,
            .pos = 0,
            .inner = inner,
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = @constCast(&.{}),
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *PrefixReader = @alignCast(@fieldParentPtr("interface", r));
        if (self.pos < self.prefix.len) {
            const n = try w.write(limit.sliceConst(self.prefix[self.pos..]));
            self.pos += n;
            return n;
        }
        return self.inner.stream(w, limit);
    }
};

fn serveConnection(gpa: Allocator, io: Io, stream: Io.net.Stream) !void {
    var cert_buffer: [1024]u8 = undefined;
    const cert = try tls_fixture.decodeCert(&cert_buffer);
    const scalar = try tls_fixture.decodeScalar();

    var signer = try tls.signature.PrivateKey.fromP256Scalar(&scalar);
    defer signer.deinit();

    var conn: tls_std.Server = undefined;
    try conn.accept(io, stream, .{
        .cert_chain = &.{cert},
        .signer = signer.signer(),
        .alpn = &.{ "h2", "http/1.1" },
    });
    defer conn.deinit();
    defer conn.close();

    const alpn = conn.selectedAlpn() orelse return error.NoAlpn;
    if (std.mem.eql(u8, alpn, "h2")) {
        var read_buffer: [16 * 1024]u8 = undefined;
        var write_buffer: [4 * 1024]u8 = undefined;
        try http.h2.engine.blocking.serveIo(
            io,
            conn.reader(),
            conn.writer(),
            H2App.handler(),
            .{
                .allocator = gpa,
                .read_buffer = &read_buffer,
                .write_buffer = &write_buffer,
                .wait_fd = .init(conn.socketHandle()),
                .common = .{},
            },
        );
        return;
    }
    if (std.mem.eql(u8, alpn, "http/1.1")) {
        var request_buffer: [16 * 1024]u8 = undefined;
        var headers: [64]http.Header = undefined;
        var response_head: [1024]u8 = undefined;
        try http.h1.engine.blocking.serveIo(
            io,
            conn.reader(),
            conn.writer(),
            H1App.handler(),
            .{
                .allocator = gpa,
                .request_buffer = &request_buffer,
                .headers = &headers,
                .response_head_buffer = &response_head,
                .common = .{ .body_bytes = 8 * 1024 },
            },
        );
        return;
    }
    return error.UnsupportedAlpn;
}

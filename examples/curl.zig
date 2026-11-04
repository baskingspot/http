//! A deliberately small curl: one HTTP/1.1 GET, body to stdout.
//!
//!     just curl http://127.0.0.1:8080/
//!     just curl https://127.0.0.1:8444/
//!
//! Hosts are IP literals. HTTPS uses `tls_std` with no chain verification,
//! because this example is for local experiments, not a replacement for curl.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const print = std.debug.print;

const http = @import("http");
const tls_std = @import("tls_std");
const client = http.h1.client.blocking;

const max_authority = 300;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        print("usage: curl <http://ip[:port]/path | https://ip[:port]/path>\n", .{});
        return error.InvalidArguments;
    }

    const url = try parseUrl(args[1]);
    var buffers: Buffers = .{};
    const request: client.Request = .{
        .method = .GET,
        .target = url.target,
        .headers = &.{.{ .name = "Host", .value = url.authority }},
    };

    if (url.tls) {
        const stream = try url.address.connect(io, .{ .mode = .stream });
        var conn: tls_std.Client = undefined;
        try conn.connect(io, stream, .{
            .host = null,
            .verify = .insecure,
            .alpn = &.{"http/1.1"},
        });
        defer conn.deinit();
        defer conn.close();
        const response = try client.fetchIo(
            conn.reader(),
            conn.writer(),
            request,
            buffers.config(),
        );
        try printResponse(io, response);
    } else {
        const stream = try url.address.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        const response = try client.fetch(io, stream, request, buffers.config());
        try printResponse(io, response);
    }
}

const Url = struct {
    tls: bool,
    authority: []const u8,
    address: Io.net.IpAddress,
    target: []const u8,
};

fn parseUrl(text: []const u8) !Url {
    var rest: []const u8 = undefined;
    var tls = false;
    if (mem.startsWith(u8, text, "https://")) {
        tls = true;
        rest = text["https://".len..];
    } else if (mem.startsWith(u8, text, "http://")) {
        rest = text["http://".len..];
    } else {
        return error.InvalidUrl;
    }

    const slash = mem.findScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    if (authority.len == 0) return error.InvalidUrl;
    const target = if (slash == rest.len) "/" else rest[slash..];

    var authority_buf: [max_authority]u8 = undefined;
    if (authority.len > authority_buf.len) return error.InvalidUrl;
    @memcpy(authority_buf[0..authority.len], authority);
    var address_text = authority_buf[0..authority.len];

    const has_port = if (authority[0] == '[') blk: {
        const close = mem.findScalar(u8, authority, ']') orelse return error.InvalidUrl;
        break :blk close + 1 < authority.len and authority[close + 1] == ':';
    } else mem.findScalarLast(u8, authority, ':') != null;

    if (!has_port) {
        const port = if (tls) ":443" else ":80";
        if (address_text.len + port.len > authority_buf.len) return error.InvalidUrl;
        @memcpy(authority_buf[address_text.len..][0..port.len], port);
        address_text = authority_buf[0 .. address_text.len + port.len];
    }

    return .{
        .tls = tls,
        .authority = authority,
        .address = try .parseLiteral(address_text),
        .target = target,
    };
}

const Buffers = struct {
    recv: [16 * 1024]u8 = undefined,
    headers: [64]http.Header = undefined,
    trailers: [8]http.Header = undefined,
    body: [1024 * 1024]u8 = undefined,
    write: [4 * 1024]u8 = undefined,

    fn config(self: *Buffers) client.Config {
        return .{
            .recv_buffer = &self.recv,
            .headers = &self.headers,
            .trailers = &self.trailers,
            .body_buffer = &self.body,
            .write_buffer = &self.write,
        };
    }
};

fn printResponse(io: Io, response: client.Response) !void {
    const head = response.head;
    print("{s} {d} {s}\n", .{
        @tagName(head.version),
        head.status.code(),
        head.reason,
    });
    for (head.headers.items) |header| {
        print("{s}: {s}\n", .{ header.name, header.value });
    }
    print("\n", .{});

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    try stdout_writer.interface.writeAll(response.body);
    try stdout_writer.interface.flush();
}

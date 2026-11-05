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
const Allocator = mem.Allocator;
const print = std.debug.print;

const http = @import("http");
const client = http.h1.client.blocking;
const tls = @import("tls_std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        print("usage: curl <http://ip[:port]/path | https://ip[:port]/path>\n", .{});
        return error.InvalidArguments;
    }

    const url = try parseUrl(arena, args[1]);
    var buffers: Buffers = .{};
    const request: client.Request = .{
        .method = .GET,
        .target = url.target,
        .headers = &.{.{ .name = "Host", .value = url.authority }},
    };

    if (url.https) {
        const stream = try url.address.connect(io, .{ .mode = .stream });
        var conn: tls.Client = undefined;
        try conn.connect(io, stream, .{
            .host = null,
            .verify = .insecure,
            .alpn = &.{"http/1.1"},
        });
        defer {
            conn.deinit();
            conn.close();
        }
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
    https: bool,
    authority: []const u8,
    address: Io.net.IpAddress,
    target: []const u8,
};

/// Parses `http://ip[:port][/path][?query]`. The request target is allocated
/// from `arena`.
fn parseUrl(arena: Allocator, text: []const u8) !Url {
    const uri: std.Uri = try .parse(text);
    if (uri.user != null or uri.password != null) return error.InvalidUrl;
    const https = if (mem.eql(u8, uri.scheme, "https"))
        true
    else if (mem.eql(u8, uri.scheme, "http"))
        false
    else
        return error.InvalidUrl;

    // `Uri.parse` fills `host` only after consuming "//", so the authority
    // starts three bytes past the scheme and ends at the path, query, or
    // fragment. `Host` carries it as written.
    const after_scheme = text[uri.scheme.len + 3 ..];
    const authority_end = mem.findAny(u8, after_scheme, "/?#") orelse after_scheme.len;
    const authority = after_scheme[0..authority_end];

    var host_buffer: [Io.net.HostName.max_len]u8 = undefined;
    const host = (try uri.getHost(&host_buffer)).bytes;
    const literal = if (host.len > 1 and host[0] == '[') host[1 .. host.len - 1] else host;

    return .{
        .https = https,
        .authority = authority,
        .address = try .parse(literal, uri.port orelse if (https) 443 else 80),
        // Origin-form request target: the path, then the query when present.
        .target = try std.fmt.allocPrint(arena, "{f}", .{
            std.Uri.fmt(&uri, .{ .path = true, .query = true }),
        }),
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
    var buf: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &buf);
    var writer = &stdout_writer.interface;

    const head = response.head;
    try writer.print("{s} {d} {s}\n", .{
        @tagName(head.version),
        head.status.code(),
        head.reason,
    });
    for (head.headers.items) |header| {
        try writer.print("{s}: {s}\n", .{ header.name, header.value });
    }
    try writer.writeByte('\n');
    try writer.flush();

    try writer.writeAll(response.body);
    try writer.flush();
}

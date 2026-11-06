//! A deliberately small curl: one GET with a streaming body.
//!
//!     just curl http://127.0.0.1:8080/
//!     just curl --http2 http://127.0.0.1:8081/
//!     just curl https://127.0.0.1:8444/
//!
//! Hosts are IP literals. `--http2` is h2c prior knowledge on cleartext.
//! HTTPS offers h2 and http/1.1 through ALPN and uses the selection. It uses
//! `tls_std` with no chain verification, because this example is for local
//! experiments, not a replacement for curl.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;
const print = std.debug.print;

const http = @import("http");
const client = http.client.blocking;
const tls = @import("tls_std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var http2 = false;
    var http1 = false;
    var silent = false;
    var head = false;
    var method: ?[]const u8 = null;
    var body: ?[]const u8 = null;
    var url_text: ?[]const u8 = null;
    const headers = try arena.alloc(http.Header, args.len);
    var header_count: usize = 0;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (mem.eql(u8, arg, "--http2")) {
            http2 = true;
        } else if (mem.eql(u8, arg, "--http1.1")) {
            http1 = true;
        } else if (mem.eql(u8, arg, "-s") or mem.eql(u8, arg, "--silent")) {
            silent = true;
        } else if (mem.eql(u8, arg, "-I") or mem.eql(u8, arg, "--head")) {
            head = true;
        } else if (mem.eql(u8, arg, "-X") or mem.eql(u8, arg, "--request")) {
            index += 1;
            if (index == args.len) return usage();
            method = args[index];
        } else if (mem.eql(u8, arg, "-d") or mem.eql(u8, arg, "--data")) {
            index += 1;
            if (index == args.len) return usage();
            body = args[index];
        } else if (mem.eql(u8, arg, "-H") or mem.eql(u8, arg, "--header")) {
            index += 1;
            if (index == args.len) return usage();
            const colon = mem.findScalar(u8, args[index], ':') orelse return error.InvalidHeader;
            const name = mem.trim(u8, args[index][0..colon], " \t");
            const value = mem.trim(u8, args[index][colon + 1 ..], " \t");
            if (name.len == 0 or name[0] == ':') return error.InvalidHeader;
            const lower = try arena.dupe(u8, name);
            for (lower) |*byte| byte.* = std.ascii.toLower(byte.*);
            headers[header_count] = .{ .name = lower, .value = value };
            header_count += 1;
        } else if (arg.len != 0 and arg[0] == '-') {
            return usage();
        } else if (url_text == null) {
            url_text = arg;
        } else {
            return usage();
        }
    }

    if (http1 and http2) return usage();
    if (head and body != null) return usage();

    const text = url_text orelse return usage();
    const url = try parseUrl(arena, text);
    const request: client.Request = .{
        .method_token = if (head) "HEAD" else (method orelse if (body != null) "POST" else "GET"),
        .scheme = if (url.https) .https else .http,
        .authority = url.authority,
        .target = url.target,
        .headers = headers[0..header_count],
        .body = body orelse "",
    };

    if (url.https) {
        const stream = try url.address.connect(io, .{ .mode = .stream });
        var conn: tls.Client = undefined;
        try conn.connect(io, stream, .{
            .host = null,
            .verify = .insecure,
            .alpn = if (http2) &.{"h2"} else if (http1) &.{"http/1.1"} else &.{ "h2", "http/1.1" },
        });
        defer {
            conn.deinit();
            conn.close();
        }
        const alpn = conn.selectedAlpn() orelse "http/1.1";
        const negotiated: client.Protocol = if (mem.eql(u8, alpn, "h2"))
            .h2
        else if (mem.eql(u8, alpn, "http/1.1"))
            .h1
        else
            return error.UnsupportedAlpn;
        var http_client: client.Client = undefined;
        try http_client.init(conn.reader(), conn.writer(), .{
            .protocol = negotiated,
            .common = .{ .allocator = arena },
        });
        defer http_client.deinit();
        const response = try http_client.request(request);
        try printResponse(io, response, silent);
    } else {
        const stream = try url.address.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var write_buffer: [4 * 1024]u8 = undefined;
        var stream_writer = stream.writer(io, &write_buffer);
        var stream_reader = stream.reader(io, &.{});
        const protocol: client.Protocol = if (http2) .h2 else .h1;
        var http_client: client.Client = undefined;
        try http_client.init(&stream_reader.interface, &stream_writer.interface, .{
            .protocol = protocol,
            .common = .{ .allocator = arena },
        });
        defer http_client.deinit();
        const response = try http_client.request(request);
        try printResponse(io, response, silent);
    }
}

fn usage() error{InvalidArguments} {
    print(
        "usage: curl [-s] [-I] [-X method] [-d body] [-H 'Name: value'] " ++
            "[--http1.1|--http2] <url>\n",
        .{},
    );
    return error.InvalidArguments;
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

fn printResponse(io: Io, response: client.Response, silent: bool) !void {
    defer response.body.close();
    var write_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &write_buffer);
    var writer = &stdout_writer.interface;

    if (!silent) {
        const head = response.head;
        try writer.print("{s} {d}\n", .{ @tagName(head.protocol), head.status.code() });
        for (head.headers.items) |header| {
            try writer.print("{s}: {s}\n", .{ header.name, header.value });
        }
        try writer.writeByte('\n');
        try writer.flush();
    }

    defer writer.flush() catch {};
    try drain(response.body, writer);
}

fn drain(body: http.client.Body, w: *Io.Writer) !void {
    while (true) {
        const result = body.read() catch |err| switch (err) {
            error.EndOfStream => break,
            error.Reset => return error.StreamReset,
            error.Truncated => return error.TruncatedBody,
            error.Protocol => return error.ProtocolError,
            error.LocalCanceled => return error.Canceled,
            error.LocalCapacity => return error.LocalCapacity,
            error.LocalOutOfMemory => return error.OutOfMemory,
            error.LocalUnusable => return error.ConnectionUnusable,
        };
        try w.writeAll(result.data);
    }
}

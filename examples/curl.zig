//! A deliberately small curl with a streaming body.
//!
//!     just curl http://127.0.0.1:8080/
//!     just curl --http2 http://127.0.0.1:8081/
//!     just curl -k https://127.0.0.1:8444/
//!     just curl -v https://baskingspot.dev/
//!
//! Hosts can be IP literals or DNS names. HTTPS verifies the system trust
//! store by default; `-k` skips verification for local test fixtures.
//! `--http2` is h2c prior knowledge on cleartext. `-v` prints the resolved
//! address, ALPN, cipher suite, and retained certificate chain.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;
const print = std.debug.print;

const http = @import("http");
const cli = @import("cli");
const client = http.client.blocking;
const tls = @import("tls");
const tls_std = @import("tls_std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var http2 = false;
    var http1 = false;
    var silent = false;
    var verbose = false;
    var insecure = false;
    var head = false;
    var method: ?[]const u8 = null;
    var body: ?[]const u8 = null;
    var url_text: ?[]const u8 = null;
    var headers: [64]http.Header = undefined;
    var header_count: usize = 0;

    var args: cli.Args = .init(init.minimal.args);
    defer args.deinit();
    while (args.next()) |tok| switch (tok) {
        .positional => |arg| {
            if (url_text != null) return usage();
            url_text = arg;
        },
        .option => |opt| {
            if (opt.isSwitch("http2", null)) {
                http2 = true;
            } else if (opt.isSwitch("http1.1", null)) {
                http1 = true;
            } else if (opt.isSwitch("silent", 's')) {
                silent = true;
            } else if (opt.isSwitch("verbose", 'v')) {
                verbose = true;
            } else if (opt.isSwitch("insecure", 'k')) {
                insecure = true;
            } else if (opt.isSwitch("head", 'I')) {
                head = true;
            } else if (opt.is("request", 'X')) {
                method = args.takeValue(opt) orelse return usage();
            } else if (opt.is("data", 'd')) {
                body = args.takeValue(opt) orelse return usage();
            } else if (opt.is("header", 'H')) {
                const raw = args.takeValue(opt) orelse return usage();
                const colon = mem.findScalar(u8, raw, ':') orelse return error.InvalidHeader;
                const name = mem.trim(u8, raw[0..colon], " \t");
                const value = mem.trim(u8, raw[colon + 1 ..], " \t");
                if (name.len == 0 or name[0] == ':') return error.InvalidHeader;
                const lower = try arena.dupe(u8, name);
                for (lower) |*byte| byte.* = std.ascii.toLower(byte.*);
                if (header_count == headers.len) return error.TooManyHeaders;
                headers[header_count] = .{ .name = lower, .value = value };
                header_count += 1;
            } else {
                return usage();
            }
        },
    };

    if (http1 and http2) return usage();
    if (head and body != null) return usage();

    const text = url_text orelse return usage();
    const url = try parseUrl(arena, io, text);
    const request: client.Request = .{
        .method_token = if (head) "HEAD" else (method orelse if (body != null) "POST" else "GET"),
        .scheme = if (url.https) .https else .http,
        .authority = url.authority,
        .target = url.target,
        .headers = headers[0..header_count],
        .body = body orelse "",
    };

    if (verbose) {
        print("* host {s} resolved to ", .{url.host});
        var address_buffer: [128]u8 = undefined;
        var address_writer: Io.Writer = .fixed(&address_buffer);
        try url.address.format(&address_writer);
        print("{s}\n", .{address_writer.buffered()});
    }

    if (url.https) {
        const TlsClient = tls_std.ClientWith(.{
            .peer_chain_storage = tls.ClientHandshake.recommended_handshake_storage,
        });
        const stream = try url.address.connect(io, .{ .mode = .stream });
        var conn: TlsClient = undefined;
        try conn.connect(io, stream, .{
            .host = if (insecure) null else url.host,
            .verify = if (insecure) .insecure else .{ .system_bundle = arena },
            .alpn = if (http2) &.{"h2"} else if (http1) &.{"http/1.1"} else &.{ "h2", "http/1.1" },
        });
        defer {
            conn.deinit();
            conn.close();
        }
        const info = conn.info();
        if (verbose) {
            print("* TLS ALPN {s} cipher {s} certs {d}\n", .{
                info.alpn orelse "none",
                @tagName(info.cipher_suite),
                info.peer_chain.len,
            });
            for (info.peer_chain, 0..) |cert, cert_index| {
                print("* TLS cert[{d}] {d} bytes\n", .{ cert_index, cert.len });
            }
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
        var write_buffer: [4096]u8 = undefined;
        var stream_writer = stream.writer(io, &write_buffer);
        var stream_reader = stream.reader(io, &.{});
        const protocol: client.Protocol = if (http2) .h2 else .h1;
        if (verbose) print("* cleartext HTTP/{s}\n", .{@tagName(protocol)});
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
        "usage: curl [-s] [-v] [-k] [-I] [-X method] [-d body] " ++
            "[-H 'Name: value'] [--http1.1|--http2] <url>\n",
        .{},
    );
    return error.InvalidArguments;
}

const Url = struct {
    https: bool,
    host: []const u8,
    authority: []const u8,
    address: Io.net.IpAddress,
    target: []const u8,
};

/// Parses `http://ip[:port][/path][?query]`. The request target is allocated
/// from `arena`.
fn parseUrl(arena: Allocator, io: Io, text: []const u8) !Url {
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

    const port: u16 = uri.port orelse if (https) 443 else 80;
    return .{
        .https = https,
        .host = literal,
        .authority = authority,
        .address = try resolve(io, literal, port),
        // Origin-form request target: the path, then the query when present.
        .target = try std.fmt.allocPrint(arena, "{f}", .{
            std.Uri.fmt(&uri, .{ .path = true, .query = true }),
        }),
    };
}

fn resolve(io: Io, host: []const u8, port: u16) !Io.net.IpAddress {
    return Io.net.IpAddress.parse(host, port) catch {
        const host_name = try Io.net.HostName.init(host);
        var results: [16]Io.net.HostName.LookupResult = undefined;
        var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&results);
        try host_name.lookup(io, &queue, .{ .port = port });
        while (true) {
            const result = queue.getOne(io) catch |err| switch (err) {
                error.Closed => return error.UnknownHostName,
                error.Canceled => return error.Canceled,
            };
            switch (result) {
                .address => |address| return address,
                .canonical_name => {},
            }
        }
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
        const result = body.read() catch |err| return switch (err) {
            error.EndOfStream => {},
            error.Reset => error.StreamReset,
            error.Truncated => error.TruncatedBody,
            error.Protocol => error.ProtocolError,
            error.LocalCanceled => error.Canceled,
            error.LocalCapacity => error.LocalCapacity,
            error.LocalOutOfMemory => error.OutOfMemory,
            error.LocalUnusable => error.ConnectionUnusable,
        };
        try w.writeAll(result.data);
    }
}

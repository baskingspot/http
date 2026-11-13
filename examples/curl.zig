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
const builtin = @import("builtin");
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;
const print = std.debug.print;
const HostName = Io.net.HostName;
const IpAddress = Io.net.IpAddress;

const cli = @import("cli");
const stdx = @import("stdx");
const http = @import("http");
const out = stdx.stdio.out;
const err = stdx.stdio.err;
const client = http.client.blocking;
const tls = @import("tls");
const tls_std = @import("tls_std");

const TlsClient = tls_std.ClientWith(.{
    .peer_chain_storage = tls.ClientHandshake.recommended_handshake_storage,
});

pub fn main(init: std.process.Init) !void {
    defer stdx.stdio.flush();
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
        err.print("* host {s} resolved to ", .{url.host});
        var address_buffer: [128]u8 = undefined;
        var address_writer: Io.Writer = .fixed(&address_buffer);
        try url.address.format(&address_writer);
        err.print("{s}\n", .{address_writer.buffered()});
    }

    if (url.https) {
        const stream = try url.address.connect(io, .{ .mode = .stream });
        noDelay(stream);
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
            err.print("* TLS ALPN {s} cipher {s} certs {d}\n", .{
                info.alpn orelse "none",
                @tagName(info.cipher_suite),
                info.peer_chain.len,
            });
            for (info.peer_chain, 0..) |cert, cert_index| {
                err.print("* TLS cert[{d}] {d} bytes\n", .{ cert_index, cert.len });
            }
        }
        const alpn = conn.selectedAlpn() orelse "http/1.1";
        const negotiated: client.Protocol = if (mem.eql(u8, alpn, "h2"))
            .h2
        else if (mem.eql(u8, alpn, "http/1.1"))
            .h1
        else
            return error.UnsupportedAlpn;
        if (verbose) printRequest(request, negotiated);
        var http_client: client.Client = undefined;
        try http_client.init(conn.reader(), conn.writer(), .{
            .protocol = negotiated,
            .common = .{ .allocator = arena },
        });
        defer http_client.deinit();
        const response = try http_client.request(request);
        try printResponse(response, silent, verbose);
    } else {
        const stream = try url.address.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        noDelay(stream);
        var write_buffer: [4096]u8 = undefined;
        var stream_writer = stream.writer(io, &write_buffer);
        var stream_reader = stream.reader(io, &.{});
        const protocol: client.Protocol = if (http2) .h2 else .h1;
        if (verbose) {
            err.print("* cleartext HTTP/{s}\n", .{@tagName(protocol)});
            printRequest(request, protocol);
        }
        var http_client: client.Client = undefined;
        try http_client.init(&stream_reader.interface, &stream_writer.interface, .{
            .protocol = protocol,
            .common = .{ .allocator = arena },
        });
        defer http_client.deinit();
        const response = try http_client.request(request);
        try printResponse(response, silent, verbose);
    }
}

fn usage() error{InvalidArguments} {
    err.print(
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
    address: IpAddress,
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

    var host_buffer: [HostName.max_len]u8 = undefined;
    // 0.17 moved std.Uri.getHost to Io.net.HostName.fromUri.
    const host = if (builtin.zig_version.minor == 16)
        (try uri.getHost(&host_buffer)).bytes
    else
        (try HostName.fromUri(uri, &host_buffer)).bytes;
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

fn noDelay(stream: Io.net.Stream) void {
    const one: u32 = 1;
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        mem.asBytes(&one),
    ) catch return;
}

fn resolve(io: Io, host: []const u8, port: u16) !IpAddress {
    return IpAddress.parse(host, port) catch {
        const host_name: HostName = try .init(host);
        var results: [16]HostName.LookupResult = undefined;
        var queue: Io.Queue(HostName.LookupResult) = .init(&results);
        try host_name.lookup(io, &queue, .{ .port = port });
        while (true) {
            const result = queue.getOne(io) catch |e| return switch (e) {
                error.Closed => error.UnknownHostName,
                error.Canceled => error.Canceled,
            };
            switch (result) {
                .address => |address| return address,
                .canonical_name => {},
            }
        }
    };
}

fn printRequest(request: client.Request, protocol: client.Protocol) void {
    switch (protocol) {
        .h1 => {
            err.print("> {s} {s} HTTP/1.1\n", .{ request.method_token, request.target });
            err.print("> Host: {s}\n", .{request.authority});
        },
        .h2 => {
            err.print("> :method {s}\n", .{request.method_token});
            err.print("> :scheme {s}\n", .{request.scheme.token()});
            err.print("> :authority {s}\n", .{request.authority});
            err.print("> :path {s}\n", .{request.target});
        },
    }
    for (request.headers) |header| {
        err.print("> {s}: {s}\n", .{ header.name, header.value });
    }
    err.print(">\n", .{});
    if (request.body.len != 0) err.print("{s}", .{request.body});
    err.print("\n", .{});
    err.flush();
}

fn printResponse(response: client.Response, silent: bool, verbose: bool) !void {
    defer response.body.close();
    if (verbose) {
        const head = response.head;
        err.print("< {s} {d}\n", .{ @tagName(head.protocol), head.status.code() });
        for (head.headers.items) |header| {
            err.print("< {s}: {s}\n", .{ header.name, header.value });
        }
        err.print("<\n", .{});
        err.flush();
    } else if (!silent) {
        const writer = out.writer();
        const head = response.head;
        try writer.print("{s} {d}\n", .{ @tagName(head.protocol), head.status.code() });
        for (head.headers.items) |header| {
            try writer.print("{s}: {s}\n", .{ header.name, header.value });
        }
        try writer.writeByte('\n');
        out.flush();
    }

    try drain(response.body, out.writer());
    out.flush();
}

fn drain(body: http.client.Body, w: *Io.Writer) !void {
    _ = body.reader.streamRemaining(w) catch |failure| switch (failure) {
        error.ReadFailed => return switch (body.outcome() orelse .truncated) {
            .truncated => error.TruncatedBody,
            .protocol_error => error.ProtocolError,
            .reset => error.StreamReset,
            .local => |local| switch (local) {
                .canceled => error.Canceled,
                .capacity => error.LocalCapacity,
                .out_of_memory => error.OutOfMemory,
                .unusable => error.ConnectionUnusable,
                .timed_out => error.DeadlineExpired,
            },
        },
        error.WriteFailed => return error.WriteFailed,
    };
}

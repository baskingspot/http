//! A deliberately small curl on the high-level client.
//!
//!     just curl http://127.0.0.1:8080/
//!     just curl -L http://127.0.0.1:8080/redirect
//!     just curl --http2 http://127.0.0.1:8081/
//!     just curl -k --address 127.0.0.1:8444 https://ztls.server.test:8444/
//!     just curl -v https://baskingspot.dev/
//!
//! HTTPS uses the platform trust store unless `-k` is given. `--address`
//! connects to a given address while the URL keeps the name used for SNI and
//! the certificate check, which is how a local fixture certificate is reached.
//! `--http2` is h2c prior knowledge on cleartext and an ALPN requirement on
//! TLS. `-L` follows redirects; without it a 3xx prints as the response.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const print = std.debug.print;

const cli = @import("cli");
const stdx = @import("stdx");
const http = @import("http");
const http_tls = @import("http_tls");
const out = stdx.stdio.out;
const err = stdx.stdio.err;
const client = http.client;

pub fn main(init: std.process.Init) !void {
    defer stdx.stdio.flush();
    const io = init.io;
    const gpa = init.gpa;
    // Header names outlive the argument loop, so they come from the arena.
    const arena = init.arena.allocator();

    var http2 = false;
    var http1 = false;
    var silent = false;
    var verbose = false;
    var insecure = false;
    var follow = false;
    var head = false;
    var address: ?Io.net.IpAddress = null;
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
            } else if (opt.isSwitch("location", 'L')) {
                follow = true;
            } else if (opt.isSwitch("head", 'I')) {
                head = true;
            } else if (opt.is("request", 'X')) {
                method = args.takeValue(opt) orelse return usage();
            } else if (opt.is("address", null)) {
                address = try .parseLiteral(args.takeValue(opt) orelse return usage());
            } else if (opt.is("data", 'd')) {
                body = args.takeValue(opt) orelse return usage();
            } else if (opt.is("header", 'H')) {
                const raw = args.takeValue(opt) orelse return usage();
                const field = http.h1.parseFieldLine(raw) catch return error.InvalidHeader;
                // h2 rejects an uppercase field name, so the example sends
                // lowercase on both protocols.
                const lower = try arena.dupe(u8, field.name);
                for (lower) |*byte| byte.* = std.ascii.toLower(byte.*);
                if (header_count == headers.len) return error.TooManyHeaders;
                headers[header_count] = .{ .name = lower, .value = field.value };
                header_count += 1;
            } else {
                return usage();
            }
        },
    };

    if (http1 and http2) return usage();
    if (head and body != null) return usage();

    const url_text_value = url_text orelse return usage();
    const url = client.Url.parse(gpa, url_text_value) catch return error.InvalidUrl;
    defer url.deinit(gpa);

    const request: client.RequestOptions = .{
        .method = if (head)
            .HEAD
        else if (method) |text|
            client.Method.parse(text)
        else if (body != null)
            .POST
        else
            .GET,
        .headers = headers[0..header_count],
        .body = body orelse "",
        .follow_redirects = follow,
        .address = address,
    };

    var http_client: http_tls.Client = undefined;
    try http_client.init(gpa, io, .{
        .insecure_no_chain_anchor = insecure,
        .alpn = if (http2) &.{"h2"} else if (http1) &.{"http/1.1"} else &.{ "h2", "http/1.1" },
        .plain = .{ .protocol = if (http2) .h2 else .h1 },
    });
    defer http_client.deinit();

    if (verbose) {
        err.print("> {s} {s}\n", .{ request.method.token(), url.target });
        for (request.headers) |header| {
            err.print("> {s}: {s}\n", .{ header.name, header.value });
        }
        err.print(">\n", .{});
        err.flush();
    }

    var response = try http_client.send(url, request);
    defer response.body.close();

    const protocol = http_client.protocol() orelse return error.NoProtocol;
    if (verbose) {
        err.print("< {s} {d}\n", .{ @tagName(protocol), response.head.status.code() });
        for (response.head.headers.items) |header| {
            err.print("< {s}: {s}\n", .{ header.name, header.value });
        }
        err.print("<\n", .{});
        err.flush();
    } else if (!silent) {
        const writer = out.writer();
        try writer.print("{s} {d}\n", .{ @tagName(protocol), response.head.status.code() });
        for (response.head.headers.items) |header| {
            try writer.print("{s}: {s}\n", .{ header.name, header.value });
        }
        try writer.writeByte('\n');
        out.flush();
    }

    try drain(response.body, out.writer());
    out.flush();
}

fn usage() error{InvalidArguments} {
    err.print(
        "usage: curl [-s] [-v] [-k] [-L] [-I] [-X method] [-d body] " ++
            "[-H 'Name: value'] [--address ip:port] [--http1.1|--http2] <url>\n",
        .{},
    );
    return error.InvalidArguments;
}

fn drain(body: client.Body, w: *Io.Writer) !void {
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

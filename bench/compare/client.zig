//! The baskingspot/http side of the client comparison.
//!
//!     bench-client <url> <requests> <workers> <h1|h2>
//!
//! Every worker owns one client, so one worker means one keep-alive
//! connection, the way `go_client.go -conc 1` and `reqwest -conc 1` do. The
//! body is streamed to a discarding writer, matching `io.Copy(io.Discard, …)`
//! and `resp.bytes()`. Wall time covers spawning the workers, connecting, and
//! every request; the first connect is noise at the request counts the runner
//! uses.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const http = @import("http");
const http_tls = @import("http_tls");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;

    var args: std.process.Args.Iterator = .init(init.minimal.args);
    _ = args.next();
    const url = args.next() orelse return usage();
    const requests = try std.fmt.parseInt(usize, args.next() orelse return usage(), 10);
    const workers = try std.fmt.parseInt(usize, args.next() orelse return usage(), 10);
    const mode = args.next() orelse return usage();
    const dial_address: ?Io.net.IpAddress = if (args.next()) |text|
        try .parseLiteral(text)
    else
        null;
    const use_mux = std.mem.eql(u8, mode, "h2mux");
    const h2 = use_mux or std.mem.eql(u8, mode, "h2");
    if (!h2 and !std.mem.eql(u8, mode, "h1")) return usage();
    if (workers == 0 or requests == 0) return usage();

    // The mux mode dials once and shares the connection: the h2 multiplexing
    // case. The other modes dial one connection per worker.
    var tls_connector: http_tls.client.Connector = .init(.{
        .insecure_no_chain_anchor = true,
        .alpn = &.{"h2"},
    });
    var plain_connector: http.client.plain.Connector = .init(.{ .protocol = .h2 });
    var parsed = if (use_mux) try http.client.Url.parse(allocator, url) else undefined;
    defer if (use_mux) parsed.deinit(allocator);
    if (use_mux and parsed.scheme == .https) {
        print("h2mux needs a cleartext h2c peer; TLS muxing waits on a poll pump\n", .{});
        return error.HttpsUnsupported;
    }
    const mux: ?*http.h2.client.mux.Mux = if (use_mux) blk: {
        const dial: http.client.transport.Context = .{
            .io = io,
            .gpa = allocator,
            .url = parsed,
            .address = dial_address,
        };
        const connection = switch (parsed.scheme) {
            .http => try plain_connector.handle().connect(dial),
            .https => try tls_connector.handle().connect(dial),
        };
        break :blk try http.h2.client.mux.Mux.create(allocator, io, connection, .{
            .allocator = allocator,
            .max_streams = @intCast(workers),
        });
    } else null;
    defer if (mux) |value| value.destroy();

    const errors = try allocator.alloc(?anyerror, workers);
    defer allocator.free(errors);
    @memset(errors, null);

    const context: Context = .{
        .io = io,
        .allocator = allocator,
        .url = url,
        .per_worker = requests / workers,
        .h2 = h2,
        .mux = mux,
        .scheme = if (use_mux) parsed.scheme else .http,
        .authority = if (use_mux) parsed.authority else "",
        .target = if (use_mux) parsed.target else "/",
        .errors = errors,
    };

    const start = Io.Clock.awake.now(io);
    const threads = try allocator.alloc(std.Thread, workers);
    defer allocator.free(threads);
    for (threads, 0..) |*thread, index| {
        thread.* = std.Thread.spawn(.{}, run, .{ &context, index }) catch |err| {
            for (threads[0..index]) |started| started.join();
            return err;
        };
    }
    for (threads) |thread| thread.join();
    const elapsed = start.durationTo(Io.Clock.awake.now(io));

    for (errors) |maybe| if (maybe) |err| {
        print("error: {s}\n", .{@errorName(err)});
        return err;
    };
    var out_buffer: [128]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &out_buffer);
    try out.interface.print("zig {d} {d}\n", .{
        context.per_worker * workers,
        elapsed.nanoseconds,
    });
    try out.interface.flush();
}

fn usage() error{InvalidArguments} {
    print("usage: bench-client <url> <requests> <workers> <h1|h2>\n", .{});
    return error.InvalidArguments;
}

const Context = struct {
    io: Io,
    allocator: Allocator,
    url: []const u8,
    per_worker: usize,
    h2: bool,
    mux: ?*http.h2.client.mux.Mux,
    scheme: http.client.Scheme,
    authority: []const u8,
    target: []const u8,
    errors: []?anyerror,
};

fn run(context: *const Context, index: usize) void {
    loop(context) catch |err| {
        context.errors[index] = err;
    };
}

fn loopMux(context: *const Context, mux: *http.h2.client.mux.Mux) !void {
    for (0..context.per_worker) |_| {
        var response = try mux.request(.{
            .method_token = "GET",
            .scheme = context.scheme,
            .authority = context.authority,
            .target = context.target,
        }, .none);
        defer response.body.close();
        var sink: Io.Writer.Discarding = .init(&.{});
        _ = try response.body.reader.streamRemaining(&sink.writer);
    }
}

fn loop(context: *const Context) !void {
    if (context.mux) |mux| return loopMux(context, mux);

    const client = try http_tls.Client.create(context.allocator, context.io, .{
        .insecure_no_chain_anchor = true,
        .alpn = if (context.h2) &.{"h2"} else &.{"http/1.1"},
        .plain = .{ .protocol = if (context.h2) .h2 else .h1 },
    });
    defer client.destroy();

    for (0..context.per_worker) |_| {
        var response = try client.get(context.url);
        defer response.body.close();
        var sink: Io.Writer.Discarding = .init(&.{});
        _ = try response.body.reader.streamRemaining(&sink.writer);
    }
}

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
    const h2 = if (std.mem.eql(u8, mode, "h2"))
        true
    else if (std.mem.eql(u8, mode, "h1"))
        false
    else
        return usage();
    if (workers == 0 or requests == 0) return usage();

    const errors = try allocator.alloc(?anyerror, workers);
    defer allocator.free(errors);
    @memset(errors, null);

    const context: Context = .{
        .io = io,
        .allocator = allocator,
        .url = url,
        .per_worker = requests / workers,
        .h2 = h2,
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
    errors: []?anyerror,
};

fn run(context: *const Context, index: usize) void {
    loop(context) catch |err| {
        context.errors[index] = err;
    };
}

fn loop(context: *const Context) !void {
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

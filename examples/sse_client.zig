//! A streaming client: read a `text/event-stream` response as it arrives.
//!
//!     just example-sse-poll          # server, 127.0.0.1:8092
//!     just example-sse-client
//!
//!     just example-h1-tls            # server, 127.0.0.1:8444
//!     just example-sse-client-tls
//!
//! Both recipes take extra arguments: `--chunk=N` reads at most N bytes at a
//! time, so events split across reads, and `--limit=N` stops after N bytes of
//! body. Run on a mode, the program does two exchanges over one connection:
//!
//!     read to the end    the server finishes the stream
//!     stop mid-stream    another thread shuts the socket down
//!
//! The caller owns the socket in both. `client.Client.attached` takes a reader
//! and a writer and does the HTTP/1.1 exchange on them. The plaintext mode
//! dials with `Io.net` and hands over the stream's reader and writer. The TLS
//! mode wraps the same kind of stream in `http.tls.client.Connection`, with
//! the CA the caller supplies and ALPN pinned to `http/1.1`, and hands over
//! its plaintext reader and writer.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const print = std.debug.print;

const http = @import("http");
const client = http.client;
const fixture = @import("tls_ca_fixture.zig");

const Mode = enum { plain, tls };

const plain_address = "127.0.0.1:8092";
const tls_address = "127.0.0.1:8444";
/// The name on the fixture certificate, and the name the TLS client checks.
const tls_host = "ztls.server.test";

/// How long the second exchange runs before the stop thread shuts the socket
/// down. The server sends one event a second, so this lands in a quiet gap
/// with the reader parked in a socket read.
const stop_after_ms = 2500;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const options = try parseArgs(try init.minimal.args.toSlice(init.arena.allocator()));

    var link: Link = undefined;
    try link.open(gpa, io, options.mode);
    defer link.close(io);

    var http_client: client.Client = undefined;
    try http_client.attached(link.reader, link.writer, .{
        .protocol = .h1,
        .common = .{ .allocator = gpa, .read_cause = link.read_cause },
    });
    defer http_client.deinit();

    var run: Run = .{
        .io = io,
        .http_client = &http_client,
        .stream = link.stream,
        .options = options,
    };

    print("connected over {s}\n\n", .{@tagName(options.mode)});
    print("1. read to the end\n", .{});
    try run.readToEnd();
    print("\n2. stop mid-stream\n", .{});
    try run.stopMidStream();
}

const Options = struct {
    mode: Mode,
    /// The most bytes one read may take. Small values make events split
    /// across reads.
    chunk: usize,
    /// Stop after this many body bytes. Null reads until the stream ends.
    limit: ?usize,
};

const read_buffer_len = 4096;

fn parseArgs(args: []const [:0]const u8) !Options {
    var options: Options = .{ .mode = .plain, .chunk = read_buffer_len, .limit = null };
    for (args[1..]) |arg| {
        if (mem.eql(u8, arg, "plain")) {
            options.mode = .plain;
        } else if (mem.eql(u8, arg, "tls")) {
            options.mode = .tls;
        } else if (mem.startsWith(u8, arg, "--chunk=")) {
            options.chunk = try std.fmt.parseInt(usize, arg["--chunk=".len..], 10);
            if (options.chunk == 0 or options.chunk > read_buffer_len) return error.InvalidChunk;
        } else if (mem.startsWith(u8, arg, "--limit=")) {
            options.limit = try std.fmt.parseInt(usize, arg["--limit=".len..], 10);
        } else {
            print("usage: sse-client [plain|tls] [--chunk=N] [--limit=N]\n", .{});
            return error.InvalidArgument;
        }
    }
    return options;
}

/// The socket and whatever sits between it and the HTTP client. The caller
/// owns all of it, which is the point of `attached`: the client never opens,
/// closes, or interrupts the socket.
const Link = struct {
    stream: Io.net.Stream,
    mode: Mode,
    plain_reader: Io.net.Stream.Reader,
    plain_writer: Io.net.Stream.Writer,
    write_buffer: [1024]u8,
    tls: http.tls.client.Connection,
    reader: *Io.Reader,
    writer: *Io.Writer,
    /// Why a read failed, for the body's outcome. Plaintext has no latch, and
    /// a failed read there reads as a truncation.
    read_cause: ?client.ReadCause,

    fn open(self: *Link, gpa: mem.Allocator, io: Io, mode: Mode) !void {
        const address: Io.net.IpAddress = try .parseLiteral(switch (mode) {
            .plain => plain_address,
            .tls => tls_address,
        });
        self.mode = mode;
        self.stream = try address.connect(io, .{ .mode = .stream });
        errdefer self.stream.close(io);

        switch (mode) {
            .plain => {
                self.plain_reader = self.stream.reader(io, &.{});
                self.plain_writer = self.stream.writer(io, &self.write_buffer);
                self.reader = &self.plain_reader.interface;
                self.writer = &self.plain_writer.interface;
                self.read_cause = null;
            },
            .tls => {
                try self.tls.init(gpa, io, self.stream, .{
                    // The CA the caller supplies, as PEM bytes. A deployment
                    // reads them from a file.
                    .trust = .{ .pem = fixture.ca_pem },
                    .host_name = tls_host,
                    .now_sec = Io.Timestamp.now(io, .real).toSeconds(),
                    .alpn = &.{"http/1.1"},
                });
                self.reader = self.tls.reader();
                self.writer = self.tls.writer();
                self.read_cause = self.tls.readCause();
                print("alpn {s}\n", .{self.tls.selectedAlpn() orelse "(none)"});
            },
        }
    }

    fn close(self: *Link, io: Io) void {
        if (self.mode == .tls) self.tls.deinit();
        self.stream.close(io);
    }
};

const Run = struct {
    io: Io,
    http_client: *client.Client,
    stream: Io.net.Stream,
    options: Options,
    /// Set by the stop thread before it shuts the socket down, so the reader
    /// can tell its own stop from a peer that went away.
    stopped: std.atomic.Value(bool) = .init(false),

    fn send(self: *Run) !client.Response {
        return self.http_client.request(.{
            .method = .GET,
            .scheme = switch (self.options.mode) {
                .plain => .http,
                .tls => .https,
            },
            .authority = switch (self.options.mode) {
                .plain => plain_address,
                .tls => tls_host ++ ":8444",
            },
            .target = switch (self.options.mode) {
                .plain => "/",
                .tls => "/events",
            },
            .headers = &.{.{ .name = "accept", .value = "text/event-stream" }},
        });
    }

    /// Request the stream and check that it is one.
    fn get(self: *Run) !client.Response {
        var response = try self.send();
        errdefer response.body.close();

        const content_type = response.head.headers.get("content-type") orelse "(none)";
        print("{d} {s}\n", .{ response.head.status.code(), content_type });
        if (response.head.status.code() != 200) return error.UnexpectedStatus;
        if (!mem.startsWith(u8, content_type, "text/event-stream")) return error.NotAnEventStream;
        return response;
    }

    /// The stream ends when the server says so. `error.EndOfStream` is the
    /// only clean end, and the connection is reusable afterwards.
    fn readToEnd(self: *Run) !void {
        var response = try self.get();
        defer response.body.close();

        const end = try self.readEvents(&response);
        switch (end) {
            .ended => {},
            .capped => print("capped at {d} bytes, the server was still sending\n", .{
                self.options.limit.?,
            }),
            else => return error.UnexpectedEnd,
        }
    }

    /// Stop a read that another thread is blocked in, then try to reuse the
    /// connection.
    ///
    /// `attached` gives the client no socket, so it has no way to wake a thread
    /// parked in `read`, and no way to know why it should. `Stream.shutdown`
    /// is the only thing that does it, and only this program can call it. The
    /// read then fails, as a truncation on plaintext and as `unusable` over
    /// TLS, and `stopped` is how this program knows the failure was its own
    /// doing. A client that dials its own connection passes
    /// `RequestOptions.progress` instead, and the exchange polls it.
    ///
    /// `Body.close` reads the rest of an unfinished response before it
    /// returns, because HTTP/1.1 cannot reset a stream. That read fails on a
    /// shut-down socket, so `close` returns at once and leaves the client
    /// `ConnectionDirty`: a mid-stream stop cannot be followed by another
    /// request. Open another connection.
    ///
    /// `Body.abort` gives up at once without that read, and also leaves the
    /// connection dirty. On a live stream that is still sending, `close`
    /// waits for the stream to end, so use `abort` to leave early.
    fn stopMidStream(self: *Run) !void {
        var response = try self.get();
        defer response.body.close();

        const stopper = try std.Thread.spawn(.{}, stop, .{self});
        const end = self.readEvents(&response);
        stopper.join();
        if ((try end) != .failed) return error.UnexpectedEnd;

        // The `defer` above closes the body again on the way out. That is safe:
        // `close` on a finished or already closed body does nothing. The
        // explicit call is here because the next request needs the response
        // closed first, and it needs the result to be `ConnectionDirty`.
        response.body.close();
        if (self.send()) |_| {
            return error.ExpectedConnectionDirty;
        } else |err| print("next request: {s}\n", .{@errorName(err)});
    }

    fn stop(self: *Run) void {
        self.io.sleep(.fromMilliseconds(stop_after_ms), .awake) catch return;
        self.stopped.store(true, .release);
        self.stream.shutdown(self.io, .both) catch |err| {
            print("shutdown: {s}\n", .{@errorName(err)});
        };
    }

    const End = enum {
        /// `error.EndOfStream`: the server finished the stream.
        ended,
        /// A `--limit` wrapper ran out. The server did not finish.
        capped,
        /// The read failed. `Body.outcome` says why.
        failed,
    };

    /// Read the body in a loop and print each event as it completes.
    ///
    /// A stream has no length, and the body reader enforces no total size: an
    /// event stream is meant to run until one side ends it, and any cap the
    /// client picked would end a healthy connection at an arbitrary byte. The
    /// only bound in this program is per event, the `Splitter` buffer, and it
    /// is the program's own memory.
    ///
    /// A caller that needs a total bound wraps the body in `Io.Reader.limited`
    /// and reads the wrapper, as `--limit` does below. The wrapper reports
    /// `error.EndOfStream` when it runs out, which looks exactly like the
    /// server finishing, so check `remaining` to tell the two apart. The body
    /// underneath is then unfinished: close it as an abandoned stream.
    fn readEvents(self: *Run, response: *client.Response) !End {
        var splitter: Splitter = .{ .io = self.io, .started = Io.Timestamp.now(self.io, .awake) };

        var limited: Io.Reader.Limited = undefined;
        var source = response.body.reader;
        if (self.options.limit) |limit| {
            limited = response.body.reader.limited(.limited(limit), &.{});
            source = &limited.interface;
        }

        var reads: usize = 0;
        var buffer: [read_buffer_len]u8 = undefined;
        const end: End = while (true) {
            // The body reader has no buffer of its own, so `take` and `peek`
            // do not work on it. `readVec` returns whatever one read produced,
            // from a single byte up to the size of the slice.
            var vecs = [_][]u8{buffer[0..self.options.chunk]};
            const n = source.readVec(&vecs) catch |err| switch (err) {
                error.EndOfStream => {
                    const capped = self.options.limit != null and limited.remaining == .nothing;
                    break if (capped) .capped else .ended;
                },
                error.ReadFailed => break .failed,
            };
            reads += 1;
            try splitter.feed(buffer[0..n]);
        };

        switch (end) {
            .ended => print("end of stream: {d} events in {d} reads\n", .{
                splitter.events,
                reads,
            }),
            .capped => print("{d} events in {d} reads\n", .{ splitter.events, reads }),
            .failed => print("read failed: {s}, {s}\n", .{
                outcomeName(response.body.outcome()),
                if (self.stopped.load(.acquire)) "stopped by this program" else "not our stop",
            }),
        }
        // A last event with no blank line after it was never finished. The
        // SSE spec says to drop it, and so does this.
        if (splitter.len != 0) print("dropped {d} bytes of an unfinished event\n", .{splitter.len});
        return end;
    }
};

fn outcomeName(outcome: ?client.Outcome) []const u8 {
    return switch (outcome orelse return "no outcome") {
        .truncated => "truncated",
        .protocol_error => "protocol error",
        .reset => "reset",
        .local => |local| @tagName(local),
    };
}

/// Cuts a byte stream into events, whatever the chunk boundaries were. An
/// event ends at a blank line, with LF or CRLF line endings. A bare CR, which
/// the SSE spec also allows, is not handled.
const Splitter = struct {
    io: Io,
    started: Io.Timestamp,
    buffer: [16 * 1024]u8 = undefined,
    /// Bytes in `buffer`: the start of an event that has not ended yet.
    len: usize = 0,
    events: usize = 0,

    /// Add bytes and print every event they complete. An event that does not
    /// fit in `buffer` is `error.EventTooLarge`.
    fn feed(self: *Splitter, bytes: []const u8) error{EventTooLarge}!void {
        if (bytes.len > self.buffer.len - self.len) return error.EventTooLarge;
        @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;

        while (blankLine(self.buffer[0..self.len])) |at| {
            self.emit(self.buffer[0..at.event_end]);
            self.len -= at.next;
            @memmove(self.buffer[0..self.len], self.buffer[at.next..][0..self.len]);
        }
    }

    const Boundary = struct { event_end: usize, next: usize };

    fn blankLine(bytes: []const u8) ?Boundary {
        const lf = mem.find(u8, bytes, "\n\n");
        const crlf = mem.find(u8, bytes, "\r\n\r\n");
        if (lf) |i| {
            if (crlf) |j| if (j < i) return .{ .event_end = j, .next = j + 4 };
            return .{ .event_end = i, .next = i + 2 };
        }
        if (crlf) |j| return .{ .event_end = j, .next = j + 4 };
        return null;
    }

    /// One line of output per event: when it arrived, then its fields.
    fn emit(self: *Splitter, event: []const u8) void {
        const elapsed = self.started.durationTo(Io.Timestamp.now(self.io, .awake));
        print("  +{d:>4}ms  #{d}", .{ @as(u64, @intCast(elapsed.toMilliseconds())), self.events });
        var lines = mem.splitScalar(u8, event, '\n');
        while (lines.next()) |raw| {
            const line = mem.trimEnd(u8, raw, "\r");
            if (line.len == 0 or line[0] == ':') continue;
            print("  {s}", .{line});
        }
        print("\n", .{});
        self.events += 1;
    }
};

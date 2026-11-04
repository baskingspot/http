//! A minimal h2c server over std.Io, driven by `h2.Session`.
//!
//!     just example-h2
//!     curl -v --http2-prior-knowledge http://127.0.0.1:8081/
//!     nghttp -v http://127.0.0.1:8081/
//!
//! The session owns the protocol state; this file owns the socket, the read
//! loop, and the request handler. No TLS: this is h2c with prior knowledge.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const http = @import("http");

const address_text = "127.0.0.1:8081";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const address: Io.net.IpAddress = try .parseLiteral(address_text);

    var listener = try address.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
    });
    defer listener.deinit(io);

    print("http2-server: listening on {s}\n", .{address_text});

    while (true) {
        const stream = listener.accept(io) catch |err| {
            print("http2-server: accept: {s}\n", .{@errorName(err)});
            continue;
        };
        serveConnection(gpa, io, stream) catch |err| {
            print("http2-server: connection: {s}\n", .{@errorName(err)});
        };
        stream.close(io);
    }
}

fn serveConnection(gpa: Allocator, io: Io, stream: Io.net.Stream) !void {
    var reader = stream.reader(io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    const r = &reader.interface;
    const w = &writer.interface;

    var session = try http.h2.Session.init(gpa, .{ .role = .server });
    defer session.deinit(gpa);

    var read_buf: [16 * 1024]u8 = undefined;
    var out_buf: [4096]u8 = undefined;

    while (true) {
        while (true) {
            const n = session.send(&out_buf);
            if (n == 0) break;
            try w.writeAll(out_buf[0..n]);
        }
        try w.flush();

        var vecs: [1][]u8 = .{&read_buf};
        const n = r.readVec(&vecs) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return err,
        };
        if (n == 0) return;

        var offset: usize = 0;
        while (offset < n) {
            const consumed = session.receive(read_buf[offset..n]);
            if (consumed == 0) break;
            offset += consumed;

            while (try session.nextEvent(gpa)) |event| {
                try handleEvent(&session, gpa, event);
            }
        }
        if (session.isClosed()) {
            while (true) {
                const written = session.send(&out_buf);
                if (written == 0) break;
                try w.writeAll(out_buf[0..written]);
            }
            try w.flush();
            return;
        }
    }
}

fn handleEvent(session: *http.h2.Session, gpa: Allocator, event: http.h2.session.Event) !void {
    switch (event) {
        .request => |request| {
            print("request {s} {s} ({s})\n", .{
                request.head.method_token,
                request.head.path orelse "?",
                request.head.authority orelse "?",
            });

            const body = "h2c hello\n";
            var length_buf: [20]u8 = undefined;
            const length = try std.fmt.bufPrint(&length_buf, "{d}", .{body.len});
            const response = [_]http.Header{
                .{ .name = ":status", .value = "200" },
                .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
                .{ .name = "content-length", .value = length },
            };
            try session.submitResponse(gpa, request.stream_id, &response, false);
            _ = try session.submitData(gpa, request.stream_id, body, true);
        },

        .data => |data| {
            print("DATA {d} bytes on stream {d}\n", .{ data.bytes.len, data.stream_id });
            if (data.bytes.len > 0) {
                try session.release(gpa, data.stream_id, @intCast(data.bytes.len));
            }
        },

        .trailers => |trailers| {
            print("trailers on stream {d}\n", .{trailers.stream_id});
        },

        .reset => |reset| {
            print("reset stream {d}: {s}\n", .{ reset.stream_id, @tagName(reset.code) });
        },

        .goaway => |goaway| {
            print("GOAWAY last={d} code={s}\n", .{ goaway.last_stream_id, @tagName(goaway.code) });
        },

        .connection_error => |err| {
            print("connection error: {s}\n", .{@tagName(err.code)});
        },

        .window_update => {},
        .response => {},
    }
}

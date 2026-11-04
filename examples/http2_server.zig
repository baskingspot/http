//! A primitive h2c server over std.Io, for poking at the frame layer.
//!
//!     just example-h2
//!     curl -v --http2-prior-knowledge http://127.0.0.1:8081/
//!
//! This is deliberately not the session: one request at a time, no flow
//! control, no stream table, no GOAWAY draining. It reads the client preface,
//! sends an empty SETTINGS, ACKs the peer's SETTINGS, decodes HEADERS with
//! HPACK, and answers with a fixed 200. It exists to watch real frames on the
//! wire.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const print = std.debug.print;

const http = @import("http");
const frame = http.h2.frame;
const hpack = http.hpack;
const TableStorage = hpack.TableStorage;
const max_frame: usize = frame.default_max_frame_size;

const address_text = "127.0.0.1:8081";
const max_headers = 64;
const table_size = 4096;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
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
        serveConnection(io, stream) catch |err| {
            print("http2-server: connection: {s}\n", .{@errorName(err)});
        };
        stream.close(io);
    }
}

fn serveConnection(io: Io, stream: Io.net.Stream) !void {
    var reader = stream.reader(io, &.{});
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    const r = &reader.interface;
    const w = &writer.interface;

    var preface_buf: [frame.preface.len]u8 = undefined;
    try r.readSliceAll(&preface_buf);
    if (!mem.eql(u8, &preface_buf, frame.preface)) return error.BadPreface;

    // Empty SETTINGS: every default, including HEADER_TABLE_SIZE 4096.
    try send(w, .settings, 0, 0, &.{});

    var payload_buf: [max_frame]u8 = undefined;
    var block_buf: [32 * 1024]u8 = undefined;
    var assembler = http.h2.header_block.Assembler.init(&block_buf);
    var decode_bytes: [16 * 1024]u8 = undefined;
    var response_block: [4096]u8 = undefined;
    var headers: [max_headers]http.Header = undefined;

    var decoder_memory: TableStorage.Buffer(table_size) = undefined;
    var decoder = hpack.Decoder.init(try .initBuffer(&decoder_memory, table_size));
    var encoder_memory: TableStorage.Buffer(table_size) = undefined;
    var encoder = hpack.Encoder.init(try .initBuffer(&encoder_memory, table_size));

    while (true) {
        const header = readHeader(r) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        if (header.length > max_frame) {
            try sendGoAway(w, header.stream_id, .frame_size_error);
            return error.FrameTooLarge;
        }

        const payload = payload_buf[0..header.length];
        try r.readSliceAll(payload);

        const body = frame.body(header, payload) catch |err| {
            print("http2-server: frame: {s}\n", .{@errorName(err)});
            try sendGoAway(w, header.stream_id, .protocol_error);
            return err;
        };

        switch (body) {
            .settings => |settings| {
                if (!settings.ack) {
                    var entries = settings.iterator();
                    while (entries.next()) |entry| {
                        print("SETTINGS {any} = {d}\n", .{ entry.id, entry.value });
                        if (entry.id == .header_table_size) {
                            encoder.setMaxSize(@min(entry.value, table_size)) catch unreachable;
                        }
                    }
                    try send(w, .settings, frame.flags.ack, 0, &.{});
                }
            },

            .ping => |ping| {
                if (!ping.ack) try send(w, .ping, frame.flags.ack, 0, ping.payload);
            },

            .headers => |headers_frame| {
                const stream_id = header.stream_id;
                var request_block = try assembler.start(
                    stream_id,
                    headers_frame.block,
                    header.flags & frame.flags.end_headers != 0,
                );
                while (request_block == null) {
                    const next_header = try readHeader(r);
                    if (next_header.stream_id != stream_id or next_header.type != .continuation) {
                        return error.UnexpectedFrame;
                    }
                    const next_payload = payload_buf[0..next_header.length];
                    try r.readSliceAll(next_payload);
                    const next_body = try frame.body(next_header, next_payload);
                    request_block = try assembler.continuation(
                        stream_id,
                        next_body.continuation.block,
                        next_header.flags & frame.flags.end_headers != 0,
                    );
                }

                const request = decoder.decode(
                    request_block.?,
                    &headers,
                    &decode_bytes,
                ) catch |err| {
                    print("http2-server: hpack: {s}\n", .{@errorName(err)});
                    try sendGoAway(w, stream_id, .compression_error);
                    return err;
                };
                const head = http.h2.head.request(request) catch |err| {
                    print("http2-server: head: {s}\n", .{@errorName(err)});
                    var reset: [4]u8 = undefined;
                    mem.writeInt(
                        u32,
                        &reset,
                        @intFromEnum(frame.ErrorCode.protocol_error),
                        .big,
                    );
                    try send(w, .rst_stream, 0, stream_id, &reset);
                    return err;
                };
                print("request {s} {s} ({s})\n", .{
                    head.method_token,
                    head.path orelse "?",
                    head.authority orelse "?",
                });

                const response_body = "h2c hello\n";
                var length_buf: [20]u8 = undefined;
                const length = try std.fmt.bufPrint(&length_buf, "{d}", .{response_body.len});
                const response = [_]http.Header{
                    .{ .name = ":status", .value = "200" },
                    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
                    .{ .name = "content-length", .value = length },
                };
                const block = try encoder.encode(&response, &response_block);
                try send(w, .headers, frame.flags.end_headers, stream_id, block);
                try send(w, .data, frame.flags.end_stream, stream_id, response_body);
            },

            .data => |data| print("DATA {d} bytes\n", .{data.data.len}),
            .goaway => return,
            .rst_stream => print("RST_STREAM\n", .{}),
            .window_update => |update| print("WINDOW_UPDATE {d}\n", .{update.increment}),
            .priority => print("PRIORITY\n", .{}),
            .push_promise => print("PUSH_PROMISE\n", .{}),
            .continuation => print("unexpected CONTINUATION\n", .{}),
            .unknown => |unknown| print("unknown frame {d}\n", .{@intFromEnum(unknown.type)}),
        }
    }
}

fn readHeader(reader: *Io.Reader) !frame.Header {
    var bytes: [9]u8 = undefined;
    try reader.readSliceAll(&bytes);
    return frame.parseHeader(&bytes);
}

fn send(
    writer: *Io.Writer,
    frame_type: frame.FrameType,
    frame_flags: u8,
    stream_id: u31,
    payload: []const u8,
) !void {
    var head: [9]u8 = undefined;
    frame.encodeHeader(&head, .{
        .length = @intCast(payload.len),
        .type = frame_type,
        .flags = frame_flags,
        .stream_id = stream_id,
    });
    try writer.writeAll(&head);
    try writer.writeAll(payload);
    try writer.flush();
}

fn sendGoAway(writer: *Io.Writer, last_stream_id: u31, code: frame.ErrorCode) !void {
    var payload: [8]u8 = undefined;
    mem.writeInt(u32, payload[0..4], last_stream_id, .big);
    mem.writeInt(u32, payload[4..8], @intFromEnum(code), .big);
    try send(writer, .goaway, 0, 0, &payload);
}

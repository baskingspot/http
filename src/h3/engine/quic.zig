//! HTTP/3 over `quic-io`: the server engine.
//!
//! `quic-io` terminates QUIC and TLS; this driver hands it HTTP/3 stream bytes
//! and takes the tagged writes back. It imports no TLS type and makes no crypto
//! call. One task per QUIC stream feeds `h3.Session`; the session mutex
//! serializes receive, events, and the outbound queue.
//!
//! The caller opens and owns the endpoint. The engine opens the local control
//! and QPACK decoder streams, initializes the session with their QUIC stream
//! ids, and then accepts peer streams until the connection closes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const quic_io = @import("quic-io");
const session_mod = @import("../session.zig");
const Session = session_mod.Session;
const head = @import("../head.zig");
const error_code = @import("../error_code.zig");
const Header = @import("../../header.zig").Header;
const Status = @import("../../status.zig").Status;

pub fn Engine(comptime limits: quic_io.SizingLimits) type {
    return struct {
        const Self = @This();

        pub const Endpoint = quic_io.Endpoint(quic_io.Sizing(limits));

        /// What `Exchange.respond` reserves for the response head: the QPACK
        /// block, the frame type and length, and the status line. A response
        /// head made by `respond` is far smaller; this is the margin.
        const head_reserve: usize = 1024;

        /// The field sections and frames the session buffers for one HEADERS
        /// or DATA frame.
        const max_header_block: usize = 16 * 1024;
        const max_frame: usize = max_header_block + 16;
        /// A DATA frame's type byte plus the worst-case 8-byte length varint.
        const data_frame_overhead: usize = 1 + 8;

        /// The largest body `Exchange.respond` accepts. A QUIC stream's send
        /// buffer does not wrap (`SizingLimits.stream_ring`), and the session's
        /// DATA frame buffer does not either, so the whole response must fit
        /// both once. A larger body returns `error.ResponseTooLarge`; the
        /// driver resets that stream and leaves the connection serving.
        pub const max_body_bytes: usize = @min(
            if (limits.stream_ring > head_reserve) limits.stream_ring - head_reserve else 0,
            max_frame - data_frame_overhead,
        );

        comptime {
            assert(max_frame > data_frame_overhead);
            assert(max_body_bytes <= limits.stream_ring);
            assert(max_body_bytes <= max_frame - data_frame_overhead);
        }

        pub const Exchange = struct {
            session: *Session,
            allocator: Allocator,
            stream_id: u62,
            request: head.RequestHead,

            /// Send a response head and body, ending the stream.
            ///
            /// `body` is limited to `Engine.max_body_bytes` and
            /// `content_type` to 256 bytes, because the driver queues the
            /// whole response in the stream's fixed send buffer. A larger
            /// response returns `error.ResponseTooLarge` without writing;
            /// the driver resets this stream only.
            pub fn respond(
                self: *Exchange,
                status: Status,
                content_type: []const u8,
                body: []const u8,
            ) !void {
                if (body.len > max_body_bytes or content_type.len > 256) {
                    return error.ResponseTooLarge;
                }
                var status_text: [3]u8 = undefined;
                _ = std.mem.print(&status_text, "{d}", .{status.code()}) catch unreachable;
                var length_text: [20]u8 = undefined;
                const length = std.mem.print(&length_text, "{d}", .{body.len}) catch unreachable;

                const fields = [_]Header{
                    .{ .name = ":status", .value = &status_text },
                    .{ .name = "content-type", .value = content_type },
                    .{ .name = "content-length", .value = length },
                };
                try self.session.submitResponse(self.allocator, self.stream_id, &fields, false);
                try self.session.submitData(self.allocator, self.stream_id, body, true);
            }
        };

        pub const Handler = struct {
            context: *anyopaque,
            handle: *const fn (context: *anyopaque, exchange: *Exchange) anyerror!void,
        };

        const Entry = struct {
            id: u62,
            stream: quic_io.Stream,
        };

        const State = struct {
            io: Io,
            allocator: Allocator,
            connection: quic_io.Connection,
            session: Session,
            handler: Handler,
            mutex: Io.Mutex = .init,
            entries: [limits.streams]Entry = undefined,
            entry_count: usize = 0,
            group: Io.Group = .init,
            failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

            fn add(self: *State, stream: quic_io.Stream) bool {
                if (self.entry_count == self.entries.len) return false;
                const id: u62 = @intCast(stream.id);
                self.entries[self.entry_count] = .{ .id = id, .stream = stream };
                self.entry_count += 1;
                return true;
            }

            fn find(self: *State, id: u62) ?quic_io.Stream {
                for (self.entries[0..self.entry_count]) |entry| {
                    if (entry.id == id) return entry.stream;
                }
                return null;
            }

            fn remove(self: *State, id: u62) void {
                var i: usize = 0;
                while (i < self.entry_count) : (i += 1) {
                    if (self.entries[i].id != id) continue;
                    self.entry_count -= 1;
                    self.entries[i] = self.entries[self.entry_count];
                    return;
                }
            }

            /// The task for one QUIC stream has ended. Forget the HTTP/3
            /// stream, free its table entry, and close the QUIC handle, which
            /// is the only thing that returns the stream slot to `quic-io`.
            /// A stream that ended without its local FIN gets a reset first.
            fn finish(self: *State, stream: quic_io.Stream) void {
                const id: u62 = @intCast(stream.id);

                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);

                self.session.forgetStream(self.allocator, id) catch |err| switch (err) {
                    error.StreamBusy => {
                        self.session.submitReset(
                            self.allocator,
                            id,
                            @backingInt(error_code.Code.internal_error),
                        ) catch |submit_err| switch (submit_err) {
                            error.ConnectionClosed, error.UnknownStream => {},
                            else => {},
                        };
                        self.drain();
                        self.session.forgetStream(
                            self.allocator,
                            id,
                        ) catch |forget_err| switch (forget_err) {
                            error.StreamBusy => {},
                            else => {},
                        };
                    },
                    error.UnknownStream => {},
                    else => {},
                };
                self.remove(id);
                stream.close(self.io);
            }

            fn fail(self: *State, code: error_code.Code) void {
                self.connection.closeWith(self.io, @backingInt(code));
                self.failed.store(true, .monotonic);
            }

            fn drain(self: *State) void {
                while (self.session.nextAction()) |action| {
                    switch (action) {
                        .write => |write| {
                            const stream = self.find(write.stream_id) orelse
                                return self.fail(.internal_error);
                            writeStream(
                                self.io,
                                stream,
                                write.bytes,
                                write.fin,
                            ) catch |err| switch (err) {
                                error.SendBufferFull, error.StreamReset, error.StreamClosed => {
                                    // A write outgrew the send buffer without
                                    // `respond`'s check, or the client stopped
                                    // or reset the stream. Reset this stream;
                                    // the connection serves the others.
                                    self.session.submitReset(
                                        self.allocator,
                                        write.stream_id,
                                        @backingInt(error_code.Code.internal_error),
                                    ) catch |reset_err| switch (reset_err) {
                                        error.ConnectionClosed, error.UnknownStream => {},
                                        else => {},
                                    };
                                },
                                else => return self.fail(.internal_error),
                            };
                        },
                        .reset => |reset| {
                            // The stream is already being torn down; a failure
                            // here changes nothing.
                            if (self.find(reset.stream_id)) |stream| {
                                stream.shutdown(self.io, .both) catch |err| switch (err) {
                                    error.StreamClosed, error.ConnectionClosed => {},
                                    else => {},
                                };
                            }
                        },
                        .stop_sending => |stop| {
                            if (self.find(stop.stream_id)) |stream| {
                                stream.shutdown(self.io, .recv) catch |err| switch (err) {
                                    error.StreamClosed, error.ConnectionClosed => {},
                                    else => {},
                                };
                            }
                        },
                        .close => |code| {
                            self.connection.closeWith(self.io, code);
                            self.failed.store(true, .monotonic);
                        },
                    }
                    self.session.release(self.allocator);
                    if (self.failed.load(.monotonic)) return;
                }
            }

            fn events(self: *State) !void {
                while (try self.session.nextEvent(self.allocator)) |event| {
                    switch (event) {
                        .request => |request| {
                            var exchange = Exchange{
                                .session = &self.session,
                                .allocator = self.allocator,
                                .stream_id = request.stream_id,
                                .request = request.head,
                            };
                            self.handler.handle(self.handler.context, &exchange) catch {
                                self.session.submitReset(
                                    self.allocator,
                                    request.stream_id,
                                    @backingInt(error_code.Code.internal_error),
                                ) catch |err| switch (err) {
                                    error.ConnectionClosed, error.UnknownStream => {},
                                    else => {},
                                };
                            };
                        },
                        .discard_stream => |id| {
                            if (self.find(id)) |stream| {
                                stream.shutdown(self.io, .both) catch |err| switch (err) {
                                    error.StreamClosed, error.ConnectionClosed => {},
                                    else => {},
                                };
                            }
                            // The stream is retired: drop the session's
                            // tombstone and stop its task. A later byte in the
                            // same read must not become a new stream type.
                            self.session.forgetStream(self.allocator, id) catch |err| switch (err) {
                                error.StreamBusy => {},
                                else => {},
                            };
                        },
                        else => {},
                    }
                    if (self.failed.load(.monotonic)) return;
                }
                self.drain();
            }
        };

        /// Accept one connection from `endpoint` and serve it until it closes.
        /// `quic-io`'s endpoint holds one connection's storage, so a second
        /// connection needs a second endpoint.
        pub fn serve(
            io: Io,
            allocator: Allocator,
            endpoint: *Endpoint,
            handler: Handler,
        ) !void {
            const connection = endpoint.accept(io) catch |err| switch (err) {
                error.ConnectionClosed => return,
                else => return err,
            };
            handleConnection(io, allocator, connection, handler) catch |err| switch (err) {
                error.ConnectionClosed => {},
                else => return err,
            };
        }

        fn handleConnection(
            io: Io,
            allocator: Allocator,
            connection: quic_io.Connection,
            handler: Handler,
        ) !void {
            defer connection.close(io);

            const control = try connection.openStream(io, .uni);
            const decoder = try connection.openStream(io, .uni);

            var state: State = .{
                .io = io,
                .allocator = allocator,
                .connection = connection,
                .session = undefined,
                .handler = handler,
            };
            state.entries[0] = .{ .id = @intCast(control.id), .stream = control };
            state.entries[1] = .{ .id = @intCast(decoder.id), .stream = decoder };
            state.entry_count = 2;

            state.session = try Session.init(allocator, .{
                .role = .server,
                .control_stream = @intCast(control.id),
                .decoder_stream = @intCast(decoder.id),
                .qpack_max_table_capacity = 4096,
                .qpack_blocked_streams = 16,
                .max_field_section_size = 16 * 1024,
                .max_streams = limits.streams,
                .max_fields = 64,
                .max_in_header_block = max_header_block,
                .max_control_frame = 16 * 1024,
                .max_data_event = 16 * 1024,
                .max_blocked_bytes = 64 * 1024,
            });
            defer state.session.deinit(allocator);

            // The type bytes and SETTINGS the session queued for its control
            // and decoder streams.
            state.mutex.lockUncancelable(io);
            state.drain();
            state.mutex.unlock(io);

            while (!state.failed.load(.monotonic)) {
                const stream = connection.acceptStream(io) catch |err| switch (err) {
                    error.ConnectionClosed => break,
                    else => break,
                };

                state.mutex.lockUncancelable(io);
                const added = state.add(stream);
                state.mutex.unlock(io);
                if (!added) {
                    state.fail(.excessive_load);
                    break;
                }

                state.group.concurrent(io, streamTask, .{ &state, stream }) catch {
                    state.fail(.internal_error);
                    break;
                };
            }

            state.group.await(io) catch |err| switch (err) {
                error.Canceled => {},
            };
            control.close(io);
            decoder.close(io);
        }

        fn streamTask(state: *State, stream: quic_io.Stream) Io.Cancelable!void {
            defer state.finish(stream);
            streamLoop(state, stream) catch |err| switch (err) {
                error.ConnectionClosed, error.StreamClosed, error.StreamReset => {},
                else => state.fail(.internal_error),
            };
        }

        fn streamLoop(state: *State, stream: quic_io.Stream) !void {
            const id: u62 = @intCast(stream.id);
            var buffer: [16 * 1024]u8 = undefined;
            var len: usize = 0;

            while (!state.failed.load(.monotonic)) {
                if (len == buffer.len) return error.MessageTooLarge;

                var vectors = [1][]u8{buffer[len..]};
                const n = stream.read(state.io, &vectors) catch |err| switch (err) {
                    error.StreamReset => {
                        state.mutex.lockUncancelable(state.io);
                        defer state.mutex.unlock(state.io);
                        state.session.reset(state.allocator, id, 0);
                        try state.events();
                        return;
                    },
                    error.ConnectionClosed, error.StreamClosed => return,
                    else => return err,
                };

                if (n == 0) {
                    state.mutex.lockUncancelable(state.io);
                    defer state.mutex.unlock(state.io);

                    var offset: usize = 0;
                    while (offset < len) {
                        const consumed = state.session.receive(
                            state.allocator,
                            id,
                            buffer[offset..len],
                            true,
                        );
                        offset += consumed;
                        try state.events();
                        if (state.failed.load(.monotonic)) return;
                        if (!state.session.containsStream(id)) return;
                        if (consumed == 0) break;
                    }
                    if (offset < len) return error.MessageTooLarge;

                    _ = state.session.receive(state.allocator, id, "", true);
                    try state.events();
                    return;
                }

                len += n;
                state.mutex.lockUncancelable(state.io);
                var offset: usize = 0;
                {
                    defer state.mutex.unlock(state.io);
                    while (offset < len) {
                        const consumed = state.session.receive(
                            state.allocator,
                            id,
                            buffer[offset..len],
                            false,
                        );
                        offset += consumed;
                        try state.events();
                        if (state.failed.load(.monotonic)) return;
                        if (!state.session.containsStream(id)) return;
                        if (consumed == 0) break;
                    }
                }

                if (offset > 0) {
                    @memmove(buffer[0 .. len - offset], buffer[offset..len]);
                    len -= offset;
                }
            }
        }

        fn writeStream(
            io: Io,
            stream: quic_io.Stream,
            bytes: []const u8,
            fin: bool,
        ) !void {
            var pos: usize = 0;
            while (pos < bytes.len) {
                const n = stream.write(io, bytes[pos..]) catch |err| switch (err) {
                    error.NoSpace => return error.SendBufferFull,
                    else => return err,
                };
                if (n == 0) return error.SendBufferFull;
                pos += n;
            }
            if (fin) try stream.shutdown(io, .send);
        }
    };
}

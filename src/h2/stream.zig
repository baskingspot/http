//! HTTP/2 stream states and identifiers (RFC 9113 §5.1, §5.1.1).
//!
//! `transition` applies one frame-level event from a side to a stream state.
//! It is a table, not a stream object: the session owns the table of streams.
//! HEADERS with END_STREAM is two events in order, `headers` then
//! `end_stream`, so the state after the frame is the same.
//!
//! This module does not decide whether a bad transition is a stream or a
//! connection error. `IdleStream` marks the cases RFC 9113 §5.1 calls a
//! connection error; the rest are stream errors.

const std = @import("std");
const testing = std.testing;
const settings = @import("settings.zig");

pub const Role = settings.Role;

pub const State = enum {
    idle,
    reserved_local,
    reserved_remote,
    open,
    half_closed_local,
    half_closed_remote,
    closed,
};

pub const Side = enum { local, remote };

pub const Event = enum {
    /// HEADERS (or a HEADERS opening a reserved stream). On its own this does
    /// not carry END_STREAM; apply `end_stream` after it when the flag is set.
    headers,
    /// DATA. It never changes the state, but it is illegal on an idle or
    /// closed stream and on the side that already ended.
    data,
    /// END_STREAM, from a HEADERS or DATA frame.
    end_stream,
    /// RST_STREAM.
    reset,
    /// PUSH_PROMISE, applied to the promised stream, not the current one.
    push_promise,
};

pub const Error = error{
    /// The frame is not legal in this state from this side. A stream error.
    InvalidTransition,
    /// RST_STREAM or DATA on an idle stream. A connection error.
    IdleStream,
    /// A new remote stream identifier that is zero, the wrong parity, or not
    /// greater than the last one.
    InvalidStreamId,
};

pub fn transition(state: State, side: Side, event: Event) Error!State {
    return switch (event) {
        .headers => headers(state, side),
        .data => data(state, side),
        .end_stream => endStream(state, side),
        .reset => reset(state),
        .push_promise => pushPromise(state, side),
    };
}

fn headers(state: State, side: Side) Error!State {
    return switch (side) {
        .local => switch (state) {
            .idle => .open,
            .reserved_local => .half_closed_remote,
            .open, .half_closed_remote => state,
            else => error.InvalidTransition,
        },
        .remote => switch (state) {
            .idle => .open,
            .reserved_remote => .half_closed_local,
            .open, .half_closed_local => state,
            else => error.InvalidTransition,
        },
    };
}

fn data(state: State, side: Side) Error!State {
    return switch (side) {
        .local => switch (state) {
            .open, .half_closed_remote => state,
            .idle => error.IdleStream,
            else => error.InvalidTransition,
        },
        .remote => switch (state) {
            .open, .half_closed_local => state,
            .idle => error.IdleStream,
            else => error.InvalidTransition,
        },
    };
}

fn endStream(state: State, side: Side) Error!State {
    return switch (side) {
        .local => switch (state) {
            .open => .half_closed_local,
            .half_closed_remote => .closed,
            else => error.InvalidTransition,
        },
        .remote => switch (state) {
            .open => .half_closed_remote,
            .half_closed_local => .closed,
            else => error.InvalidTransition,
        },
    };
}

fn reset(state: State) Error!State {
    return switch (state) {
        .idle => error.IdleStream,
        else => .closed,
    };
}

fn pushPromise(state: State, side: Side) Error!State {
    if (state != .idle) return error.InvalidTransition;
    return switch (side) {
        .local => .reserved_local,
        .remote => .reserved_remote,
    };
}

/// The next local stream identifier and the last remote one.
pub const Ids = struct {
    role: Role,
    local_next: u32,
    last_remote: u31 = 0,

    pub fn init(role: Role) Ids {
        return .{
            .role = role,
            .local_next = if (role == .client) 1 else 2,
        };
    }

    /// The next stream this endpoint initiates, or null when the 31-bit space
    /// is exhausted.
    pub fn nextLocal(self: *Ids) ?u31 {
        if (self.local_next > 0x7fff_ffff) return null;
        const id: u31 = @intCast(self.local_next);
        self.local_next += 2;
        return id;
    }

    /// Accept a new stream initiated by the peer. The identifier must have the
    /// peer's parity and exceed every remote identifier seen.
    pub fn acceptRemote(self: *Ids, id: u31) Error!void {
        if (id == 0) return error.InvalidStreamId;
        const peer_is_client = self.role == .server;
        const parity: u31 = if (peer_is_client) 1 else 0;
        if (id & 1 != parity) return error.InvalidStreamId;
        if (id <= self.last_remote) return error.InvalidStreamId;
        self.last_remote = id;
    }
};

test "headers open an idle stream from either side" {
    try testing.expectEqual(State.open, try transition(.idle, .local, .headers));
    try testing.expectEqual(State.open, try transition(.idle, .remote, .headers));
}

test "END_STREAM closes each side in order" {
    var state: State = .idle;
    state = try transition(state, .local, .headers);
    state = try transition(state, .local, .end_stream);
    try testing.expectEqual(State.half_closed_local, state);
    state = try transition(state, .remote, .data);
    try testing.expectEqual(State.half_closed_local, state);
    state = try transition(state, .remote, .end_stream);
    try testing.expectEqual(State.closed, state);
    try testing.expectError(
        error.InvalidTransition,
        transition(state, .local, .data),
    );
}

test "trailers are allowed on the open side only" {
    try testing.expectEqual(
        State.open,
        try transition(.open, .local, .headers),
    );
    try testing.expectEqual(
        State.half_closed_local,
        try transition(.half_closed_local, .remote, .headers),
    );
    try testing.expectError(
        error.InvalidTransition,
        transition(.half_closed_local, .local, .headers),
    );
    try testing.expectError(
        error.InvalidTransition,
        transition(.half_closed_remote, .remote, .headers),
    );
}

test "DATA is legal only where the side is open" {
    try testing.expectEqual(State.open, try transition(.open, .local, .data));
    try testing.expectEqual(State.open, try transition(.open, .remote, .data));
    try testing.expectEqual(
        State.half_closed_remote,
        try transition(.half_closed_remote, .local, .data),
    );
    try testing.expectEqual(
        State.half_closed_local,
        try transition(.half_closed_local, .remote, .data),
    );
    try testing.expectError(error.IdleStream, transition(.idle, .remote, .data));
    try testing.expectError(
        error.InvalidTransition,
        transition(.closed, .local, .data),
    );
    try testing.expectError(
        error.InvalidTransition,
        transition(.half_closed_local, .local, .data),
    );
}

test "RST_STREAM closes an active stream and is a connection error on idle" {
    try testing.expectEqual(State.closed, try transition(.open, .local, .reset));
    try testing.expectEqual(
        State.closed,
        try transition(.reserved_remote, .remote, .reset),
    );
    try testing.expectEqual(State.closed, try transition(.closed, .local, .reset));
    try testing.expectError(error.IdleStream, transition(.idle, .local, .reset));
}

test "PUSH_PROMISE reserves a new stream" {
    try testing.expectEqual(
        State.reserved_local,
        try transition(.idle, .local, .push_promise),
    );
    try testing.expectEqual(
        State.reserved_remote,
        try transition(.idle, .remote, .push_promise),
    );
    try testing.expectError(
        error.InvalidTransition,
        transition(.open, .local, .push_promise),
    );
    try testing.expectEqual(
        State.half_closed_remote,
        try transition(.reserved_local, .local, .headers),
    );
    try testing.expectEqual(
        State.half_closed_local,
        try transition(.reserved_remote, .remote, .headers),
    );
}

test "stream identifiers follow role parity and increase" {
    var client = Ids.init(.client);
    try testing.expectEqual(@as(?u31, 1), client.nextLocal());
    try testing.expectEqual(@as(?u31, 3), client.nextLocal());
    try testing.expectEqual(@as(?u31, 5), client.nextLocal());
    try client.acceptRemote(2);
    try client.acceptRemote(4);
    try client.acceptRemote(6);
    try testing.expectError(error.InvalidStreamId, client.acceptRemote(1));
    try testing.expectError(error.InvalidStreamId, client.acceptRemote(3));
    try testing.expectError(error.InvalidStreamId, client.acceptRemote(6));
    try testing.expectError(error.InvalidStreamId, client.acceptRemote(0));

    var server = Ids.init(.server);
    try testing.expectEqual(@as(?u31, 2), server.nextLocal());
    try testing.expectEqual(@as(?u31, 4), server.nextLocal());
    try server.acceptRemote(1);
    try server.acceptRemote(3);
    try testing.expectError(error.InvalidStreamId, server.acceptRemote(2));
}

test "the stream identifier space can be exhausted" {
    var ids: Ids = .{ .role = .client, .local_next = 0x7fff_fffd };
    try testing.expectEqual(@as(?u31, 0x7fff_fffd), ids.nextLocal());
    try testing.expectEqual(@as(?u31, 0x7fff_ffff), ids.nextLocal());
    try testing.expect(ids.nextLocal() == null);
}

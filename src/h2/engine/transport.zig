//! The byte-transport event shared by the readiness engines.
//!
//! A transport owns the socket-facing state for one connection slot: the raw
//! fd, its read and write storage, and, for TLS, the handshake and record
//! layer. It exposes application plaintext to the h2 `Connection` and accepts
//! h2 output in return. The readiness loop owns readiness, deadlines, and the
//! connection lifetime; it never sees a TLS record.

/// One step of the transport state machine.
pub const Event = union(enum) {
    /// No complete input record or plaintext remains.
    need_input,
    /// The transport has wire output to drain before it can make progress.
    need_output,
    /// The transport advanced but has more work ready now.
    progress,
    /// TLS completed its handshake and the configured ALPN was selected.
    handshake_complete,
    /// Borrowed plaintext. The transport keeps it pinned until `consume`.
    application_data: []const u8,
    /// The peer ended its side of the transport and will send nothing more.
    /// This is not the end of the socket: after a TLS close_notify our sending
    /// direction can stay open (RFC 8446 6.1), so flush pending output and
    /// call `canWrite` before closing the slot. The transport keeps reporting
    /// `closed` once the peer has closed, so a driver must decide from
    /// `canWrite` rather than waiting for another kind of event.
    closed,
};

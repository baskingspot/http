//! HTTP/3 (RFC 9114), sans I/O.
//!
//! `frame` is the framing layer: the type and length varints, typed payloads,
//! and a reader that walks one QUIC stream. `settings`, `error_code`, and
//! `control` cover the control stream and the unidirectional stream types.
//! `head` validates the decoded request, response, and trailer field sections.
//! The session is not here yet.

pub const control = @import("control.zig");
pub const error_code = @import("error_code.zig");
pub const frame = @import("frame.zig");
pub const head = @import("head.zig");
pub const settings = @import("settings.zig");

test {
    _ = control;
    _ = error_code;
    _ = frame;
    _ = head;
    _ = settings;
}

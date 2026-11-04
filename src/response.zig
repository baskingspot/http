//! An outbound HTTP response, with the known fields kept as values.
//!
//! `status`, `content_type`, and `content_length` are typed. The HPACK encoder
//! writes their text at wire time, so a caller does not build a `Header` array
//! or carry temporary status and length strings. `headers` holds the regular
//! fields that are already text.

const Header = @import("header.zig").Header;
const Status = @import("status.zig").Status;

// ast-grep-ignore: public-struct-field-default -- typed known fields; the rest is a list
pub const Response = struct {
    status: Status,
    content_type: ?[]const u8 = null,
    /// The engine sets this; `h2.Session.submitResponse` encodes it.
    content_length: ?u64 = null,
    /// Extra regular fields. Pseudo-headers and `content-length` belong in the
    /// typed fields, not here.
    headers: []const Header = &.{},
};

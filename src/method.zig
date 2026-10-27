//! The common request methods, re-exported from `std.http`.
//!
//! `std.http.Method` is the conventional nine, with `safe`, `idempotent`, and
//! the body/cache helpers. The parser still returns the wire token, because
//! `method = token` is case-sensitive and the IANA registry is open (RFC 9110
//! §9.1, §16.1.1); `parse` and `token` are the bridge.

const std = @import("std");
const meta = std.meta;
pub const Method = std.http.Method;

/// The exact wire token. Methods are case-sensitive (RFC 9110 §9.1).
pub fn token(method: Method) []const u8 {
    return @tagName(method);
}

/// The method with this exact token, or null. `get` is not `GET`.
pub fn parse(wire: []const u8) ?Method {
    return meta.stringToEnum(Method, wire);
}

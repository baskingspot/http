//! HTTP version numbers: the exact wire pair and the version a recipient
//! processes the message as.

const std = @import("std");
const testing = std.testing;

/// The two decimal digits from the start-line, exactly as sent.
/// RFC 9112 §2.3: `HTTP-version = HTTP-name "/" DIGIT "." DIGIT`.
pub const WireVersion = packed struct(u16) {
    major: u8,
    minor: u8,
};

/// The version a recipient processes a message as. A message with major
/// version 1 and a higher minor version is processed as 1.1 (RFC 9110 §6.2).
pub const Version = enum { @"HTTP/1.0", @"HTTP/1.1" };

pub const Error = error{UnsupportedVersion};

/// RFC 9110 §6.2: a recipient that implements major version 1 and receives a
/// higher minor version processes the message as its highest supported minor.
/// The wire pair stays in `WireVersion`; this is the effective version.
pub fn effective(wire: WireVersion) Error!Version {
    return switch (wire) {
        .{ .major = 1, .minor = 0 } => .@"HTTP/1.0",
        .{ .major = 1, .minor = 1 } => .@"HTTP/1.1",
        else => if (wire.major == 1) .@"HTTP/1.1" else error.UnsupportedVersion,
    };
}

test "effective: a higher minor maps to the highest supported minor" {
    try testing.expectEqual(Version.@"HTTP/1.0", try effective(.{ .major = 1, .minor = 0 }));
    try testing.expectEqual(Version.@"HTTP/1.1", try effective(.{ .major = 1, .minor = 1 }));
    try testing.expectEqual(Version.@"HTTP/1.1", try effective(.{ .major = 1, .minor = 2 }));
    try testing.expectEqual(Version.@"HTTP/1.1", try effective(.{ .major = 1, .minor = 9 }));
}

test "effective: another major is unsupported" {
    try testing.expectError(error.UnsupportedVersion, effective(.{ .major = 0, .minor = 9 }));
    try testing.expectError(error.UnsupportedVersion, effective(.{ .major = 2, .minor = 0 }));
}

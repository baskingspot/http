//! Connection persistence (RFC 9112 §9.3).
//!
//! HTTP/1.1 persists by default; HTTP/1.0 closes by default and persists only
//! with the `keep-alive` connection option. `close` wins over everything.

const std = @import("std");
const testing = std.testing;

const Header = @import("../header.zig").Header;
const Headers = @import("../header.zig").Headers;
const Version = @import("../version.zig").Version;

/// Whether the connection persists after the most recently received message.
pub fn persistent(version: Version, headers: Headers) bool {
    if (headers.containsToken("Connection", "close")) return false;
    return switch (version) {
        .@"HTTP/1.1" => true,
        .@"HTTP/1.0" => headers.containsToken("Connection", "keep-alive"),
    };
}

fn section(items: []const Header) Headers {
    return .{ .items = items };
}

test "HTTP/1.1 persists by default" {
    try testing.expect(persistent(.@"HTTP/1.1", section(&.{})));
    try testing.expect(persistent(.@"HTTP/1.1", section(&.{
        .{ .name = "Connection", .value = "keep-alive" },
    })));
}

test "close wins on HTTP/1.1" {
    try testing.expect(!persistent(.@"HTTP/1.1", section(&.{
        .{ .name = "Connection", .value = "close" },
    })));
    try testing.expect(!persistent(.@"HTTP/1.1", section(&.{
        .{ .name = "connection", .value = "Upgrade, close" },
    })));
}

test "HTTP/1.0 closes by default" {
    try testing.expect(!persistent(.@"HTTP/1.0", section(&.{})));
    try testing.expect(persistent(.@"HTTP/1.0", section(&.{
        .{ .name = "Connection", .value = "keep-alive" },
    })));
}

test "close wins on HTTP/1.0" {
    try testing.expect(!persistent(.@"HTTP/1.0", section(&.{
        .{ .name = "Connection", .value = "keep-alive, close" },
    })));
}

test "Connection lines are checked in order and case-insensitively" {
    const headers: Headers = .{ .items = &.{
        .{ .name = "connection", .value = "Upgrade" },
        .{ .name = "CONNECTION", .value = "close" },
    } };
    try testing.expect(!persistent(.@"HTTP/1.1", headers));
}

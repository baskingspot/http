//! HTTP status codes as an open enum.
//!
//! The wire value is three digits, and RFC 9110 §15 requires a recipient to
//! treat an unrecognized code as the x00 of its class. So this type is
//! non-exhaustive: a code the enum does not name is still a value, and `class`
//! works on it. `parse` rejects only a number that cannot be three digits.
//!
//! The names and values mirror `std.http.Status`, so Zig callers already know
//! them. Unlike a re-export, this type is stable across Zig releases and
//! carries its own phrase table.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

pub const Status = enum(u10) {
    @"continue" = 100, // RFC 9110 §15.2.1
    switching_protocols = 101,
    processing = 102, // RFC 2518
    early_hints = 103, // RFC 8297

    ok = 200, // RFC 9110 §15.3.1
    created = 201,
    accepted = 202,
    non_authoritative_info = 203,
    no_content = 204,
    reset_content = 205,
    partial_content = 206,
    multi_status = 207, // RFC 4918
    already_reported = 208, // RFC 5842
    im_used = 226, // RFC 3229

    multiple_choice = 300, // RFC 9110 §15.4.1
    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    use_proxy = 305, // deprecated
    temporary_redirect = 307,
    permanent_redirect = 308, // RFC 7538

    bad_request = 400, // RFC 9110 §15.5.1
    unauthorized = 401,
    payment_required = 402,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    not_acceptable = 406,
    proxy_auth_required = 407,
    request_timeout = 408,
    conflict = 409,
    gone = 410,
    length_required = 411,
    precondition_failed = 412,
    payload_too_large = 413,
    uri_too_long = 414,
    unsupported_media_type = 415,
    range_not_satisfiable = 416,
    expectation_failed = 417,
    teapot = 418, // RFC 7168
    misdirected_request = 421, // RFC 9110 §15.5.20
    unprocessable_entity = 422, // RFC 9110 §15.5.21
    locked = 423, // RFC 4918
    failed_dependency = 424, // RFC 4918
    too_early = 425, // RFC 8470
    upgrade_required = 426,
    precondition_required = 428, // RFC 6585
    too_many_requests = 429, // RFC 6585
    request_header_fields_too_large = 431, // RFC 6585
    unavailable_for_legal_reasons = 451, // RFC 7725

    internal_server_error = 500, // RFC 9110 §15.6.1
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    gateway_timeout = 504,
    http_version_not_supported = 505,
    variant_also_negotiates = 506, // RFC 2295
    insufficient_storage = 507, // RFC 4918
    loop_detected = 508, // RFC 5842
    not_extended = 510, // RFC 2774
    network_authentication_required = 511, // RFC 6585

    _,

    pub const Class = enum {
        informational,
        success,
        redirect,
        client_error,
        server_error,
    };

    /// The three-digit wire value.
    /// The three ASCII digits of the wire status. The status must be 100..999;
    /// `h2.head.validateResponse` enforces that before encoding.
    pub fn text(self: Status) [3]u8 {
        const value = self.code();
        assert(value >= 100);
        assert(value < 1000);
        return .{
            @intCast('0' + (value / 100) % 10),
            @intCast('0' + (value / 10) % 10),
            @intCast('0' + value % 10),
        };
    }

    pub fn code(self: Status) u16 {
        return @intFromEnum(self);
    }

    /// The status with this number, or null when it cannot be three digits.
    /// A three-digit code the enum does not name returns a value, not null.
    pub fn parse(value: u16) ?Status {
        if (value > 999) return null;
        return @as(Status, @enumFromInt(@as(u10, @intCast(value))));
    }

    /// The class of the code, or null when the value is outside 100..599
    /// (RFC 9110 §15).
    pub fn class(self: Status) ?Class {
        return switch (@intFromEnum(self)) {
            100...199 => .informational,
            200...299 => .success,
            300...399 => .redirect,
            400...499 => .client_error,
            500...599 => .server_error,
            else => null,
        };
    }

    /// The canonical reason phrase, or null for an unnamed code. The phrase is
    /// advisory: a client does not use it to decide anything (RFC 9110 §15.2).
    pub fn phrase(self: Status) ?[]const u8 {
        return switch (self) {
            // 1xx
            .@"continue" => "Continue",
            .switching_protocols => "Switching Protocols",
            .processing => "Processing",
            .early_hints => "Early Hints",

            // 2xx
            .ok => "OK",
            .created => "Created",
            .accepted => "Accepted",
            .non_authoritative_info => "Non-Authoritative Information",
            .no_content => "No Content",
            .reset_content => "Reset Content",
            .partial_content => "Partial Content",
            .multi_status => "Multi-Status",
            .already_reported => "Already Reported",
            .im_used => "IM Used",

            // 3xx
            .multiple_choice => "Multiple Choices",
            .moved_permanently => "Moved Permanently",
            .found => "Found",
            .see_other => "See Other",
            .not_modified => "Not Modified",
            .use_proxy => "Use Proxy",
            .temporary_redirect => "Temporary Redirect",
            .permanent_redirect => "Permanent Redirect",

            // 4xx
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .payment_required => "Payment Required",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .not_acceptable => "Not Acceptable",
            .proxy_auth_required => "Proxy Authentication Required",
            .request_timeout => "Request Timeout",
            .conflict => "Conflict",
            .gone => "Gone",
            .length_required => "Length Required",
            .precondition_failed => "Precondition Failed",
            .payload_too_large => "Payload Too Large",
            .uri_too_long => "URI Too Long",
            .unsupported_media_type => "Unsupported Media Type",
            .range_not_satisfiable => "Range Not Satisfiable",
            .expectation_failed => "Expectation Failed",
            .teapot => "I'm a teapot",
            .misdirected_request => "Misdirected Request",
            .unprocessable_entity => "Unprocessable Entity",
            .locked => "Locked",
            .failed_dependency => "Failed Dependency",
            .too_early => "Too Early",
            .upgrade_required => "Upgrade Required",
            .precondition_required => "Precondition Required",
            .too_many_requests => "Too Many Requests",
            .request_header_fields_too_large => "Request Header Fields Too Large",
            .unavailable_for_legal_reasons => "Unavailable For Legal Reasons",

            // 5xx
            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .bad_gateway => "Bad Gateway",
            .service_unavailable => "Service Unavailable",
            .gateway_timeout => "Gateway Timeout",
            .http_version_not_supported => "HTTP Version Not Supported",
            .variant_also_negotiates => "Variant Also Negotiates",
            .insufficient_storage => "Insufficient Storage",
            .loop_detected => "Loop Detected",
            .not_extended => "Not Extended",
            .network_authentication_required => "Network Authentication Required",

            else => null,
        };
    }
};

test "every named status round-trips through code and parse" {
    inline for (std.meta.fields(Status)) |field| {
        const status: Status = @field(Status, field.name);
        try testing.expectEqual(status, Status.parse(status.code()).?);
    }
}

test "an unnamed code stays a value (RFC 9110 §15)" {
    const status = Status.parse(599).?;
    try testing.expectEqual(599, status.code());
    try testing.expectEqual(Status.Class.server_error, status.class().?);
    try testing.expect(status.phrase() == null);
    try testing.expect(status != .not_found);
}

test "parse rejects only a value that cannot be three digits" {
    try testing.expect(Status.parse(1000) == null);
    try testing.expect(Status.parse(65535) == null);
    try testing.expectEqual(0, Status.parse(0).?.code());
}

test "class covers the five classes and nothing else" {
    try testing.expectEqual(Status.Class.informational, Status.early_hints.class().?);
    try testing.expectEqual(Status.Class.success, Status.ok.class().?);
    try testing.expectEqual(Status.Class.redirect, Status.found.class().?);
    try testing.expectEqual(Status.Class.client_error, Status.not_found.class().?);
    try testing.expectEqual(Status.Class.server_error, Status.bad_gateway.class().?);
    try testing.expect(Status.parse(99).?.class() == null);
    try testing.expect(Status.parse(600).?.class() == null);
}

test "phrase is the canonical spelling, null when unnamed" {
    try testing.expectEqualStrings("OK", Status.ok.phrase().?);
    try testing.expectEqualStrings("I'm a teapot", Status.teapot.phrase().?);
    try testing.expect(Status.parse(599).?.phrase() == null);
}

test "text is the three wire digits" {
    try testing.expectEqualStrings("200", &Status.ok.text());
    try testing.expectEqualStrings("404", &Status.not_found.text());
    try testing.expectEqualStrings("500", &Status.internal_server_error.text());
}

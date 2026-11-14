//! A consumer of `http_tls` by module name.
//!
//! This file exists to pin one thing: the `http_tls` module must compile when
//! something other than itself imports it. A file inside the module that
//! imports `@import("http_tls")` resolves only when that file is the root of
//! its own compilation, so the mistake is invisible until a consumer tries it.

const std = @import("std");
const testing = std.testing;
const http_tls = @import("http_tls");

test "the module imports by name and exposes the client" {
    _ = http_tls.client.Connection;
    _ = http_tls.anchors;
    _ = http_tls.Bundle;
}

test "the client exposes the request surface" {
    const Connection = http_tls.client.Connection;
    try testing.expect(@hasDecl(Connection, "init"));
    try testing.expect(@hasDecl(Connection, "deinit"));
    try testing.expect(@hasDecl(Connection, "reader"));
    try testing.expect(@hasDecl(Connection, "writer"));
    try testing.expect(@hasDecl(Connection, "setDeadline"));
    try testing.expect(@hasDecl(Connection, "expired"));
    try testing.expect(@hasDecl(Connection, "selectedAlpn"));
    try testing.expect(@hasDecl(Connection, "peerAlert"));
    try testing.expect(@hasDecl(Connection, "readError"));
    try testing.expect(@hasDecl(Connection, "writeError"));
    // No `canWrite`: after a peer close_notify the write is the query.
    try testing.expect(!@hasDecl(Connection, "canWrite"));
    try testing.expect(!@hasField(Connection, "canWrite"));
    try testing.expect(!@hasField(Connection, "expired"));
}

test "the anchors builder is reachable through the module name" {
    try testing.expect(@hasDecl(http_tls.anchors, "build"));
    const options: http_tls.client.Connection.Options = .{
        .ca_pem = "",
        .host_name = "example.com",
        .now_sec = 0,
    };
    try testing.expectEqualStrings("h2", options.alpn[0]);
    try testing.expectEqualStrings("http/1.1", options.alpn[1]);
}

test "the transport is reachable through the module name" {
    _ = http_tls.h2.transport.tls_client.Transport;
    _ = http_tls.h2.engine.tls.poll;
}

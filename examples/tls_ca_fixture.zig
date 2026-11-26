//! A test CA and a leaf it signed for `ztls.server.test`, valid from
//! 2026-11-08 to 2036-11-05. The same material `tests/tls_connection.zig` uses.
//! Not a deployment identity.
//!
//! `tls_fixture.zig` holds the shared `baskingspot/tls` certificate. That one
//! is an end entity, and an end entity cannot anchor a chain, so a client that
//! supplies its own CA needs this pair instead.

const std = @import("std");

pub const ca_b64 =
    "MIIBoTCCAUegAwIBAgIUYElwU9zW7k8K0l+/pLW0cooLRu4wCgYIKoZIzj0EAwIwHjEcMBoG" ++
    "A1UEAwwTYmFza2luZ3Nwb3QgdGVzdCBDQTAeFw0yNjExMDgyMTI5MTJaFw0zNjExMDUyMTI5" ++
    "MTJaMB4xHDAaBgNVBAMME2Jhc2tpbmdzcG90IHRlc3QgQ0EwWTATBgcqhkjOPQIBBggqhkjO" ++
    "PQMBBwNCAAQ0i5xrrCogTXE8NieIB6Q7I6nEDRlhFy9+cBAdvE1N2bear/26RFwRfy85TCQQ" ++
    "1pfy7joeEJ7OMs6S5HqmLZMfo2MwYTAdBgNVHQ4EFgQUXklNCmBTwvBUBxWWUG+P3HMlic0w" ++
    "HwYDVR0jBBgwFoAUXklNCmBTwvBUBxWWUG+P3HMlic0wDwYDVR0TAQH/BAUwAwEB/zAOBgNV" ++
    "HQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwIDSAAwRQIgGhkKrs3Ti7XbyHnHAbXeGoxoBEavp5ye" ++
    "DfHcnzBQxGUCIQDMLiQu6kV+FqRNS/inwPosu4qRRJe8Po7dHxEsMkDXhQ==";

pub const leaf_b64 =
    "MIIB0DCCAXWgAwIBAgIUEDqD3Y5azscjzRoDRLEJpxijgyswCgYIKoZIzj0EAwIwHjEcMBoG" ++
    "A1UEAwwTYmFza2luZ3Nwb3QgdGVzdCBDQTAeFw0yNjExMDgyMTI5MTJaFw0zNjExMDUyMTI5" ++
    "MTJaMBsxGTAXBgNVBAMMEHp0bHMuc2VydmVyLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMB" ++
    "BwNCAARRbBYdrnrz6oaIU2defGKr1Trlm1NL6+qqa+mmSG3AOiQoFD4BZtorlv1FBKDwgXZT" ++
    "MNwzzEoU7QNmBOUbhuRto4GTMIGQMBsGA1UdEQQUMBKCEHp0bHMuc2VydmVyLnRlc3QwDAYD" ++
    "VR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwHQYDVR0O" ++
    "BBYEFP9OTNiyuMqZKCiKd4UydrqVCmfcMB8GA1UdIwQYMBaAFF5JTQpgU8LwVAcVllBvj9xz" ++
    "JYnNMAoGCCqGSM49BAMCA0kAMEYCIQCtVJEtDQDDtmk6t6p5ahEhI7iA1Mipc7uY9z7DAd8B" ++
    "5QIhAIBubxJiTeZbKG6jZxYpzFEvdksUhZRqUS6RzKkI7AVz";

pub const leaf_scalar_b64 = "CH5wDP96TpNJK4U/29zPZbad1B24GBkqcNqakuC0e1g=";

/// The CA as PEM, which is what a client reads from a file.
pub const ca_pem = "-----BEGIN CERTIFICATE-----\n" ++ ca_b64 ++
    "\n-----END CERTIFICATE-----\n";

/// The leaf as DER, which is what `cert_chain` takes. The CA is not sent: the
/// client already holds it.
pub fn decodeLeaf(buffer: []u8) ![]const u8 {
    const len = try std.base64.standard.Decoder.calcSizeForSlice(leaf_b64);
    if (len > buffer.len) return error.BufferTooSmall;
    const der = buffer[0..len];
    try std.base64.standard.Decoder.decode(der, leaf_b64);
    return der;
}

pub fn decodeScalar() ![32]u8 {
    var scalar: [32]u8 = undefined;
    try std.base64.standard.Decoder.decode(&scalar, leaf_scalar_b64);
    return scalar;
}

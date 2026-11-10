//! Trust anchors built from PEM bytes a caller already holds.
//!
//! A caller with a certificate bundle in memory never parses PEM itself and
//! never touches the filesystem. The clock is the caller's, because an expired
//! anchor is dropped silently rather than reported.

const std = @import("std");
const tls_nonblocking = @import("tls_nonblocking");

/// A trust store, as `tls.certificate.Policy` expects one.
pub const Bundle = std.crypto.Certificate.Bundle;

/// Build a trust store from one or more PEM certificate blocks.
///
/// `now_sec` is the clock used to reject expired anchors. The caller owns the
/// returned bundle and must call `deinit`. Any failure discards a partial
/// store; `error.NoTrustAnchors` means nothing usable loaded.
pub const build = tls_nonblocking.anchors.build;

const testing = std.testing;

// The public test certificate from `baskingspot/tls`, valid 2026-06-01 to
// 2036-05-29. Not a deployment identity.
const pem_fixture =
    "-----BEGIN CERTIFICATE-----\n" ++
    "MIIByzCCAXKgAwIBAgIUbmarzBd+vWR/mRLY6OMXZSPvVQQwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQ" ++
    "enRscy5zZXJ2ZXIudGVzdDAeFw0yNjA2MDEwMTA3MzFaFw0zNjA1MjkwMTA3MzFaMBsxGTAXBgNVBAMM" ++
    "EHp0bHMuc2VydmVyLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATKaYKPBZrI1VlFanyJm97M" ++
    "16XUgwbBJkpHVern9TQuuQmG35VDsVMFA0FvUT6cigFaiHvB6NSZWczKYURvdTIlo4GTMIGQMB0GA1Ud" ++
    "DgQWBBQVmks0H0iMK08RcQYrOzH1jLnV0jAfBgNVHSMEGDAWgBQVmks0H0iMK08RcQYrOzH1jLnV0jAM" ++
    "BgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDATAbBgNVHREEFDAS" ++
    "ghB6dGxzLnNlcnZlci50ZXN0MAoGCCqGSM49BAMCA0cAMEQCIE7rvZ4pcB7M69DXnXztJ3RKJzHRMZg/" ++
    "jvjL7Ad2t9wZAiB7s3wziFsMpfnXGN05V/q29wgFLilNG8YQX6ssYxwWog==\n" ++
    "-----END CERTIFICATE-----\n";

/// 2027-01-01T00:00:00Z, inside the fixture's validity window.
const fixture_now_sec: i64 = 1_798_761_600;
/// 2036-07-18T13:20:00Z, after the fixture expires on 2036-05-29.
const after_fixture_expiry: i64 = 2_100_000_000;

test "anchors.build loads a valid PEM block" {
    var bundle = try build(testing.allocator, pem_fixture, fixture_now_sec);
    defer bundle.deinit(testing.allocator);

    // One anchor, holding exactly the DER of the fixture certificate.
    try testing.expectEqual(@as(usize, 1), bundle.map.count());
    try testing.expectEqual(@as(usize, 463), bundle.bytes.items.len);
}

test "anchors.build refuses a store with nothing usable" {
    // No marker at all.
    try testing.expectError(
        error.NoTrustAnchors,
        build(testing.allocator, "not a certificate", fixture_now_sec),
    );

    // A well-formed block whose anchor the caller's clock says has expired.
    try testing.expectError(
        error.NoTrustAnchors,
        build(testing.allocator, pem_fixture, after_fixture_expiry),
    );
}

test "anchors.build refuses a partial or malformed block" {
    // A valid block followed by a block that is not valid base64. The loader
    // commits the first anchor before failing on the second, so the only safe
    // outcome is that nothing is handed back.
    const bad_base64 =
        pem_fixture ++
        "-----BEGIN CERTIFICATE-----\n" ++
        "no!t-base-64\n" ++
        "-----END CERTIFICATE-----\n";
    try testing.expectError(
        error.InvalidPemBase64,
        build(testing.allocator, bad_base64, fixture_now_sec),
    );

    // Structurally invalid DER is rejected before std's parser descends into
    // it. Without this guard the 5-byte block below panics in the certificate
    // parser, and it is structurally valid at the top level: a SEQUENCE
    // holding one INTEGER.
    const bad_der =
        pem_fixture ++
        "-----BEGIN CERTIFICATE-----\n" ++
        "MAMCAQE=\n" ++
        "-----END CERTIFICATE-----\n";
    try testing.expectError(
        error.InvalidCertificateDer,
        build(testing.allocator, bad_der, fixture_now_sec),
    );

    // A missing END marker is an error, not an empty store.
    const truncated = pem_fixture[0 .. pem_fixture.len - 30];
    try testing.expectError(
        error.MissingEndCertificateMarker,
        build(testing.allocator, truncated, fixture_now_sec),
    );
}

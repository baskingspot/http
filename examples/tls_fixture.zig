//! The public test certificate and scalar from `baskingspot/tls`. Not a
//! deployment identity.

const std = @import("std");

pub const cert_b64 =
    "MIIByzCCAXKgAwIBAgIUbmarzBd+vWR/mRLY6OMXZSPvVQQwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQ" ++
    "enRscy5zZXJ2ZXIudGVzdDAeFw0yNjA2MDEwMTA3MzFaFw0zNjA1MjkwMTA3MzFaMBsxGTAXBgNVBAMM" ++
    "EHp0bHMuc2VydmVyLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATKaYKPBZrI1VlFanyJm97M" ++
    "16XUgwbBJkpHVern9TQuuQmG35VDsVMFA0FvUT6cigFaiHvB6NSZWczKYURvdTIlo4GTMIGQMB0GA1Ud" ++
    "DgQWBBQVmks0H0iMK08RcQYrOzH1jLnV0jAfBgNVHSMEGDAWgBQVmks0H0iMK08RcQYrOzH1jLnV0jAM" ++
    "BgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDATAbBgNVHREEFDAS" ++
    "ghB6dGxzLnNlcnZlci50ZXN0MAoGCCqGSM49BAMCA0cAMEQCIE7rvZ4pcB7M69DXnXztJ3RKJzHRMZg/" ++
    "jvjL7Ad2t9wZAiB7s3wziFsMpfnXGN05V/q29wgFLilNG8YQX6ssYxwWog==";
pub const scalar_b64 = "139HGdxmRe2N5F69cAY4IgK8B4ybwx0hgPE0siIOaeY=";

pub fn decodeCert(buffer: []u8) ![]const u8 {
    const len = try std.base64.standard.Decoder.calcSizeForSlice(cert_b64);
    if (len > buffer.len) return error.BufferTooSmall;
    const cert = buffer[0..len];
    try std.base64.standard.Decoder.decode(cert, cert_b64);
    return cert;
}

pub fn decodeScalar() ![32]u8 {
    var scalar: [32]u8 = undefined;
    try std.base64.standard.Decoder.decode(&scalar, scalar_b64);
    return scalar;
}

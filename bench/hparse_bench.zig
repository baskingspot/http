//! hparse 0.2.0 on the same heads as `h1_bench.zig`. Compare the rows, not the
//! absolute numbers: the inputs are duplicated so a change to one bench cannot
//! silently move the other.

const testingx = @import("testingx");
const compat = @import("../src/compat.zig");
const hparse = @import("hparse");

const typical =
    "GET /metrics?x=1 HTTP/1.1\r\n" ++
    "Host: example.com\r\n" ++
    "User-Agent: test/1.0\r\n" ++
    "Accept: */*\r\n" ++
    "Accept-Encoding: gzip, br\r\n" ++
    "\r\n";

const wide =
    "GET /v2?address=db.example.com:6432 HTTP/1.1\r\n" ++
    "Host: example.com\r\n" ++
    "User-Agent: exosphere/0.1\r\n" ++
    "Accept: */*\r\n" ++
    "Accept-Encoding: gzip, deflate, br, zstd\r\n" ++
    "Connection: keep-alive\r\n" ++
    "Content-Type: application/json\r\n" ++
    "Content-Length: 128\r\n" ++
    "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345\r\n" ++
    "X-Request-Id: 01234567-89ab-cdef-0123-456789abcdef\r\n" ++
    "X-Forwarded-For: 203.0.113.7, 198.51.100.9\r\n" ++
    "X-Forwarded-Proto: https\r\n" ++
    "X-Forwarded-Host: example.com\r\n" ++
    "Traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\r\n" ++
    "\r\n";

const response =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: application/json\r\n" ++
    "Content-Length: 1234\r\n" ++
    "Date: Mon, 26 Oct 2026 12:00:00 GMT\r\n" ++
    "Connection: keep-alive\r\n" ++
    "\r\n";

pub fn benchmarkRequestTypicalHparse(b: *testingx.B) !void {
    const buf = b.blackBox(typical);
    var headers: [16]hparse.Header = undefined;
    var sink: usize = 0;
    while (try b.loop()) {
        var method: hparse.Method = .unknown;
        var path: ?[]const u8 = null;
        var version: hparse.Version = .@"1.0";
        var count: usize = 0;
        const consumed = try hparse.parseRequest(buf, &method, &path, &version, &headers, &count);
        sink +%= consumed + count;
    }
    b.keepAlive(sink);
    b.keepAlive(&headers);
}

pub fn benchmarkRequestWideHparse(b: *testingx.B) !void {
    const buf = b.blackBox(wide);
    var headers: [32]hparse.Header = undefined;
    var sink: usize = 0;
    while (try b.loop()) {
        var method: hparse.Method = .unknown;
        var path: ?[]const u8 = null;
        var version: hparse.Version = .@"1.0";
        var count: usize = 0;
        const consumed = try hparse.parseRequest(buf, &method, &path, &version, &headers, &count);
        sink +%= consumed + count;
    }
    b.keepAlive(sink);
    b.keepAlive(&headers);
}

pub fn benchmarkResponseHparse(b: *testingx.B) !void {
    const buf = b.blackBox(response);
    var headers: [16]hparse.Header = undefined;
    var sink: usize = 0;
    while (try b.loop()) {
        var version: hparse.Version = .@"1.0";
        var status: u16 = 0;
        var reason: ?[]const u8 = null;
        var count: usize = 0;
        const consumed = try hparse.parseResponse(
            buf,
            &version,
            &status,
            &reason,
            &headers,
            &count,
        );
        const reason_len: usize = if (reason) |value| value.len else 0;
        sink +%= consumed + count + reason_len;
    }
    b.keepAlive(sink);
    b.keepAlive(&headers);
}

const long_value = compat.repeatString("a", 1024);
const long_request = "GET / HTTP/1.1\r\nX-Long: " ++ long_value ++ "\r\n\r\n";

pub fn benchmarkRequestLongValueHparse(b: *testingx.B) !void {
    const buf: []const u8 = long_request;
    var headers: [4]hparse.Header = undefined;
    var sink: usize = 0;
    while (try b.loop()) {
        var method: hparse.Method = .unknown;
        var path: ?[]const u8 = null;
        var version: hparse.Version = .@"1.0";
        var count: usize = 0;
        const consumed = try hparse.parseRequest(buf, &method, &path, &version, &headers, &count);
        sink +%= consumed + headers[0].value.len;
    }
    b.keepAlive(sink);
    b.keepAlive(&headers);
}

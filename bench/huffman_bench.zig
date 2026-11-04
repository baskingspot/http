//! HPACK Huffman encode and decode benchmarks.

const testingx = @import("testingx");
const http = @import("http");

const text = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36";
const cookie = "session=abc123; theme=dark; lang=en-US; path=/; HttpOnly; Secure; SameSite=Lax";

pub fn benchmarkHuffmanEncode(b: *testingx.B) !void {
    const src = b.blackBox(text);
    var out: [128]u8 = undefined;
    var sink: usize = 0;
    while (try b.loop()) {
        sink +%= try http.huffman.encode(src, &out);
    }
    b.keepAlive(sink);
}

pub fn benchmarkHuffmanDecode(b: *testingx.B) !void {
    var encoded: [128]u8 = undefined;
    const n = try http.huffman.encode(text, &encoded);
    const src = b.blackBox(encoded[0..n]);
    var out: [128]u8 = undefined;
    var sink: usize = 0;
    while (try b.loop()) {
        sink +%= try http.huffman.decode(src, &out);
    }
    b.keepAlive(sink);
}

pub fn benchmarkHuffmanEncodeCookie(b: *testingx.B) !void {
    const src = b.blackBox(cookie);
    var out: [256]u8 = undefined;
    var sink: usize = 0;
    while (try b.loop()) {
        sink +%= try http.huffman.encode(src, &out);
    }
    b.keepAlive(sink);
}

pub fn benchmarkHuffmanDecodeCookie(b: *testingx.B) !void {
    var encoded: [256]u8 = undefined;
    const n = try http.huffman.encode(cookie, &encoded);
    const src = b.blackBox(encoded[0..n]);
    var out: [256]u8 = undefined;
    var sink: usize = 0;
    while (try b.loop()) {
        sink +%= try http.huffman.decode(src, &out);
    }
    b.keepAlive(sink);
}

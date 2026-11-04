//! The bench suite: one module per parser. `addMod` finds every top-level
//! `pub fn benchmark*` and registers it by name.

const testingx = @import("testingx");

const content_length = @import("content_length_bench.zig");
const encoding = @import("encoding_bench.zig");
const h1 = @import("h1_bench.zig");
const huffman = @import("huffman_bench.zig");
const hpack = @import("hpack_bench.zig");
const hparse = @import("hparse_bench.zig");
const writer = @import("writer_bench.zig");
const token_list = @import("token_list_bench.zig");

pub fn benchmarkMain(b: *testingx.B) !void {
    try b.addMod(content_length);
    try b.addMod(encoding);
    try b.addMod(h1);
    try b.addMod(huffman);
    try b.addMod(hpack);
    try b.addMod(hparse);
    try b.addMod(writer);
    try b.addMod(token_list);
}

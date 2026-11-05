//! HTTP/1.1 and HTTP/2 in Zig: field-value parsers, sans-I/O connection
//! machines, and the engines you build a server or client on.
//!
//! Each parser module reads one field family or message head and returns
//! borrowed slices or fills caller-owned storage. `h1.ServerConn` and
//! `h2.Session` are the connection machines; `client` is the protocol-neutral
//! client contract they both implement. The engines own the transport and the
//! handler loop over `std.Io`, and the parsers import no socket and no
//! allocator.

pub const content_length = @import("content_length.zig");
pub const encoding = @import("encoding.zig");
pub const engine = @import("engine/common.zig");
pub const client = @import("client/root.zig");
pub const h1 = @import("h1/root.zig");
pub const h2 = @import("h2/root.zig");
pub const hpack = @import("hpack/root.zig");
pub const huffman = @import("huffman.zig");
pub const Cursor = @import("Cursor.zig");
pub const Header = @import("header.zig").Header;
pub const Headers = @import("header.zig").Headers;
pub const Method = @import("method.zig").Method;
pub const method = @import("method.zig");
pub const prefix_int = @import("prefix_int.zig");
pub const response = @import("response.zig");
pub const Status = @import("status.zig").Status;
pub const status = @import("status.zig");
pub const token_list = @import("token_list.zig");
pub const transfer_encoding = @import("transfer_encoding.zig");
pub const Values = @import("header.zig").Values;
pub const Version = @import("version.zig").Version;
pub const WireVersion = @import("version.zig").WireVersion;

test {
    _ = @import("Cursor.zig");
    _ = @import("header.zig");
    _ = @import("method.zig");
    _ = @import("status.zig");
    _ = @import("version.zig");
    _ = content_length;
    _ = client;
    _ = h1;
    _ = h2;
    _ = hpack;
    _ = huffman;
    _ = prefix_int;
    _ = response;
    _ = engine;
    _ = encoding;
    _ = token_list;
    _ = transfer_encoding;
}

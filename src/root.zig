//! http: pure HTTP field-value parsers. No server, no allocator, no `std.Io`.
//!
//! Each module parses one field family and returns borrowed slices or fills
//! caller-owned storage. The caller maps content-coding tokens to its codecs.

pub const Field = @import("field.zig").Field;
pub const Method = @import("method.zig").Method;
pub const method = @import("method.zig");
pub const StatusCode = @import("status.zig").StatusCode;
pub const status = @import("status.zig");
pub const Fields = @import("field.zig").Fields;
pub const Values = @import("field.zig").Values;

pub const content_length = @import("content_length.zig");
pub const h1 = @import("h1/root.zig");
pub const encoding = @import("encoding.zig");
pub const token_list = @import("token_list.zig");

test {
    _ = @import("field.zig");
    _ = @import("method.zig");
    _ = @import("status.zig");
    _ = content_length;
    _ = h1;
    _ = encoding;
    _ = token_list;
}

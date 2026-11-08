//! Shims for the Zig 0.16 and 0.17 APIs. Private to the module.

// 0.17's formatter rewrites these to builtins that 0.16 cannot compile.
// zig fmt: off
pub fn enumToInt(e: anytype) @typeInfo(@TypeOf(e)).@"enum".tag_type {
    return @intFromEnum(e);
}
pub fn enumFromInt(comptime E: type, raw: @typeInfo(E).@"enum".tag_type) E {
    return @enumFromInt(raw);
}
// zig fmt: on

/// Zig 0.17 removed the `**` operator for byte strings.
pub fn repeatString(comptime s: []const u8, comptime n: usize) [s.len * n]u8 {
    var out: [s.len * n]u8 = undefined;
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}

/// Repeat a value in an array on either side of the operator removal.
pub fn filled(comptime T: type, comptime n: usize, comptime value: T) [n]T {
    var out: [n]T = undefined;
    for (&out) |*item| item.* = value;
    return out;
}

/// Iterate an enum's fields on either side of the 0.17 split.
pub fn enumFieldCount(comptime E: type) usize {
    const info = @typeInfo(E).@"enum";
    if (comptime @hasField(@TypeOf(info), "field_names")) return info.field_names.len;
    return info.fields.len;
}

pub fn enumFieldName(comptime E: type, comptime index: usize) []const u8 {
    const info = @typeInfo(E).@"enum";
    if (comptime @hasField(@TypeOf(info), "field_names")) return info.field_names[index];
    return info.fields[index].name;
}

// zig fmt: off
pub fn enumFieldValue(comptime E: type, comptime index: usize) E {
    const info = @typeInfo(E).@"enum";
    if (comptime @hasField(@TypeOf(info), "field_values"))
        return @enumFromInt(info.field_values[index]);
    return @field(E, info.fields[index].name);
}
// zig fmt: on

const std = @import("std");
const testing = std.testing;

const Base64VLQ = @import("Base64VLQ.zig");

const MappingSegment = @This();

const Source = struct {
    /// Zero-based index into the "sources" list.
    ///
    /// This field is a base 64 VLQ relative to the previous occurrence of
    /// this field, unless this is the first occurrence of this field, in
    /// which case the whole value is represented.
    index: i32,

    /// Zero-based starting line in the original source represented
    ///
    /// This field is a base 64 VLQ relative to the previous occurrence of
    /// this field, unless this is the first occurrence of this field, in
    /// which case the whole value is represented.
    line: i32,

    /// Zero-based starting column of the line in the source represented
    ///
    /// This field is a base 64 VLQ relative to the previous occurrence of
    /// this field, unless this is the first occurrence of this field, in
    /// which case the whole value is represented.
    column: i32,

    /// Zero-based index into the "names" list associated with this segment.
    ///
    /// This field is a base 64 VLQ relative to the previous occurrence of
    /// this field, unless this is the first occurrence of this field, in
    /// which case the whole value is represented.
    name_index: ?i32 = null,
};

/// Zero-based starting column of the line in the generated code that the
/// segment represents.
///
/// If this is the first field of the first segment, or the first segment
/// following a new generated line (";"), then this field holds the whole
/// base 64 VLQ. Otherwise, this field contains a base 64 VLQ that is
/// relative to the previous occurrence of this field.
///
/// Note that this is different than the other fields because the previous
/// value is reset after every generated line.
generated_column: i64,

source: ?Source = null,

pub const max_encoded_len =
    Base64VLQ.encodedByteLength(64) +
    Base64VLQ.encodedByteLength(32) +
    Base64VLQ.encodedByteLength(32) +
    Base64VLQ.encodedByteLength(32) +
    Base64VLQ.encodedByteLength(32);

pub fn encode(self: MappingSegment) [max_encoded_len:0]u8 {
    var buf = std.mem.zeroes([max_encoded_len:0]u8);
    std.mem.copyForwards(u8, &buf, &Base64VLQ.encode(self.generated_column));
    if (self.source) |source| {
        std.mem.copyForwards(u8, buf[bufLen(buf)..], &Base64VLQ.encode(source.index));
        std.mem.copyForwards(u8, buf[bufLen(buf)..], &Base64VLQ.encode(source.line));
        std.mem.copyForwards(u8, buf[bufLen(buf)..], &Base64VLQ.encode(source.column));
        if (source.name_index) |name_index| {
            std.mem.copyForwards(u8, buf[bufLen(buf)..], &Base64VLQ.encode(name_index));
        }
    }

    return buf;
}

fn bufLen(buf: [max_encoded_len:0]u8) usize {
    for (buf, 0..) |c, i| {
        if (c == 0) {
            return i;
        }
    }

    return buf.len;
}

pub fn encodeBuf(self: MappingSegment, buf: []u8) ![]const u8 {
    const encoded = self.encode();
    const len = bufLen(encoded);

    if (buf.len < len) {
        return error.NoSpaceLeft;
    }

    std.mem.copyForwards(u8, buf, encoded[0..len]);

    return buf[0..len];
}

fn testEncode(expected: []const u8, segment: MappingSegment) !void {
    var buf: [max_encoded_len]u8 = undefined;
    try testing.expectEqualStrings(expected, segment.encodeBuf(&buf) catch unreachable);
}

test encode {
    try testEncode("A", MappingSegment{
        .generated_column = 0,
    });

    try testEncode("AAAA", MappingSegment{
        .generated_column = 0,
        .source = .{
            .index = 0,
            .line = 0,
            .column = 0,
        },
    });

    try testEncode("IAAM", MappingSegment{
        .generated_column = 4,
        .source = .{
            .index = 0,
            .line = 0,
            .column = 6,
        },
    });

    try testEncode("WAAW", MappingSegment{
        .generated_column = 11,
        .source = .{
            .index = 0,
            .line = 0,
            .column = 11,
        },
    });

    try testEncode("AAAAA", MappingSegment{
        .generated_column = 0,
        .source = .{
            .index = 0,
            .line = 0,
            .column = 0,
            .name_index = 0,
        },
    });
}

fn decode(str: []const u8) !MappingSegment {
    const generated_column, var rest = try Base64VLQ.decode(i64, str);
    if (rest.len == 0) {
        return .{
            .generated_column = generated_column,
        };
    }

    const source_index, rest = try Base64VLQ.decode(i32, rest);
    const source_line, rest = try Base64VLQ.decode(i32, rest);
    const source_column, rest = try Base64VLQ.decode(i32, rest);
    if (rest.len == 0) {
        return .{
            .generated_column = generated_column,
            .source = .{
                .index = source_index,
                .line = source_line,
                .column = source_column,
            },
        };
    }

    const source_name_index, rest = try Base64VLQ.decode(i32, rest);
    if (rest.len == 0) {
        return .{
            .generated_column = generated_column,
            .source = .{
                .index = source_index,
                .line = source_line,
                .column = source_column,
                .name_index = source_name_index,
            },
        };
    }

    return error.UnexpectedExtraData;
}

test decode {
    try testing.expectEqualDeep(MappingSegment{
        .generated_column = 0,
    }, decode("A"));

    try testing.expectEqualDeep(MappingSegment{
        .generated_column = 0,
        .source = .{
            .index = 0,
            .line = 0,
            .column = 0,
        },
    }, decode("AAAA"));

    try testing.expectEqualDeep(MappingSegment{
        .generated_column = 4,
        .source = .{
            .index = 0,
            .line = 0,
            .column = 6,
        },
    }, decode("IAAM"));

    try testing.expectEqualDeep(MappingSegment{
        .generated_column = 11,
        .source = .{
            .index = 0,
            .line = 0,
            .column = 11,
        },
    }, decode("WAAW"));

    try testing.expectEqualDeep(MappingSegment{
        .generated_column = 0,
        .source = .{
            .index = 0,
            .line = 0,
            .column = 0,
            .name_index = 0,
        },
    }, decode("AAAAA"));
}

const std = @import("std");
const testing = std.testing;
const charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

const inverted = blk: {
    var result = [_]?u6{null} ** 128;
    for (charset, 0..) |char, i| {
        std.debug.assert(result[char] == null);

        result[char] = @intCast(i);
    }

    break :blk result;
};

const FirstSextet = packed struct(u6) {
    const Bits = u4;
    const bit_mask = std.math.maxInt(Bits);

    signed: bool,
    bits: Bits,
    has_more: bool,
};

const FollowingSextet = packed struct(u6) {
    const Bits = u5;
    const bit_mask = std.math.maxInt(Bits);

    bits: Bits,
    has_more: bool,
};

fn comptimeBits(comptime n: comptime_int) u16 {
    return @as(u16, @intCast(std.math.log2(@abs(n)))) + @intFromBool(n < 0) + 1;
}

pub fn encodedByteLength(bits: u16) usize {
    if (bits <= 4) {
        return 1;
    }

    return 1 + (std.math.divCeil(usize, bits - 4, 5) catch unreachable);
}

pub fn encode(number: anytype) [encodedByteLength(if (@typeInfo(@TypeOf(number)) == .ComptimeInt) comptimeBits(number) else @typeInfo(@TypeOf(number)).Int.bits):0]u8 {
    const number_bit_size = comptime if (@typeInfo(@TypeOf(number)) == .ComptimeInt) comptimeBits(number) else @typeInfo(@TypeOf(number)).Int.bits;

    const len = comptime encodedByteLength(number_bit_size);
    var buf = [_:0]u8{0} ** len;
    var n = @as(std.meta.Int(.unsigned, @max(number_bit_size, 4)), @abs(number));
    buf[0] = charset[
        @as(u6, @bitCast(FirstSextet{
            .signed = number < 0,
            .bits = @intCast(n & FirstSextet.bit_mask),
            .has_more = @abs(n) > FirstSextet.bit_mask,
        }))
    ];

    if (len == 1) {
        return buf;
    }

    n >>= 4;
    if (n == 0) {
        return buf;
    }

    var i: usize = 1;
    while (n != 0) {
        buf[i] = charset[
            @as(u6, @bitCast(FollowingSextet{
                .bits = @intCast(n & FollowingSextet.bit_mask),
                .has_more = n > FollowingSextet.bit_mask,
            }))
        ];
        n >>= 5;
        i += 1;
    }

    return buf;
}

test encode {
    try testing.expectEqualStrings(&[1:0]u8{'C'}, &encode(1));
    try testing.expectEqualStrings(&[1:0]u8{'L'}, &encode(-5));

    try testing.expectEqualStrings(&[2:0]u8{ '+', 'P' }, &encode(std.math.maxInt(u8)));
    try testing.expectEqualStrings(&[2:0]u8{ '+', 'H' }, &encode(std.math.maxInt(i8)));
    try testing.expectEqualStrings(&[2:0]u8{ '/', 'H' }, &encode(-std.math.maxInt(i8)));

    try testing.expectEqualStrings(&[4:0]u8{ '+', '/', '/', 'D' }, &encode(std.math.maxInt(u16)));
    try testing.expectEqualStrings(&[4:0]u8{ '+', '/', '/', 'B' }, &encode(std.math.maxInt(i16)));
    try testing.expectEqualStrings(&[4:0]u8{ '/', '/', '/', 'B' }, &encode(-std.math.maxInt(i16)));

    try testing.expectEqualStrings(&[7:0]u8{ 'I', 0, 0, 0, 0, 0, 0 }, &encode(@as(u32, 4)));
    try testing.expectEqualStrings(&[7:0]u8{ 'W', 0, 0, 0, 0, 0, 0 }, &encode(@as(u32, 11)));

    try testing.expectEqualStrings(&[13:0]u8{ '4', 'L', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &encode(@as(i64, 188)));
    try testing.expectEqualStrings(&[13:0]u8{ 'q', '9', 'G', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &encode(@as(i64, 3541)));
    try testing.expectEqualStrings(&[13:0]u8{ 'z', 'v', 'g', 'E', 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &encode(@as(i64, -65785)));
}

pub fn decode(comptime T: type, bytes: []const u8) !struct { T, []const u8 } {
    std.debug.assert(@typeInfo(T) == .Int);

    const info = @typeInfo(T).Int;
    std.debug.assert(info.bits >= 4);

    if (bytes.len == 0) {
        return error.UnexpectedEndOfFile;
    }

    var sign: i3 = 1;
    var bits: std.meta.Int(.unsigned, info.bits - (if (info.signedness == .signed) 1 else 0)) = 0;
    if (inverted[bytes[0]]) |n| {
        const sextet: FirstSextet = @bitCast(n);
        if (info.signedness == .signed) {
            sign = @as(i3, @intFromBool(!sextet.signed)) * 2 - 1;
        } else {
            std.debug.assert(!sextet.signed);
        }

        bits = sextet.bits;
        if (!sextet.has_more) {
            return .{
                @as(T, bits) * (if (info.signedness == .signed) sign else 1),
                bytes[1..],
            };
        }
    } else {
        return error.UnexpectedCharacter;
    }

    for (bytes[1..], 1..) |c, i| {
        if (inverted[c]) |n| {
            const sextet: FollowingSextet = @bitCast(n);
            bits = (@as(@TypeOf(bits), sextet.bits) << @as(std.math.IntFittingRange(0, info.bits - 1), @intCast(4 + 5 * (i - 1)))) | bits;
            if (!sextet.has_more) {
                return .{
                    @as(T, bits) * (if (info.signedness == .signed) sign else 1),
                    bytes[i + 1 ..],
                };
            }
        } else {
            return error.UnexpectedCharacter;
        }
    }

    return error.UnexpectedEndOfFile;
}

test decode {
    try testing.expectEqualDeep(.{ 1, "" }, try decode(u8, "C"));
    try testing.expectEqualDeep(.{ -5, "" }, try decode(i8, "L"));
    try testing.expectEqualDeep(.{ 4, "A" }, try decode(u32, "IA"));
    try testing.expectEqualDeep(.{ 11, "AAW" }, try decode(u32, "WAAW"));
    try testing.expectEqualDeep(.{ 188, "A" }, try decode(u32, "4LA"));
    try testing.expectEqualDeep(.{ 3541, "" }, try decode(u64, "q9G"));
    try testing.expectEqualDeep(.{ -65785, "" }, try decode(i64, "zvgE"));
}

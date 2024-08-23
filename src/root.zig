const std = @import("std");
const testing = std.testing;

test {
    _ = @import("Base64VLQ.zig");
    _ = @import("MappingSegment.zig");
    _ = @import("SourceMapGenerator.zig");
}

pub const Generator = @import("SourceMapGenerator.zig");
pub const Position = Generator.Position;
pub const Mapping = Generator.Mapping;

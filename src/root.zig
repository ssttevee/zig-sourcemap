const std = @import("std");
const testing = std.testing;

test {
    _ = @import("Base64VLQ.zig");
    _ = @import("MappingSegment.zig");
    _ = @import("SourceMapGenerator.zig");
}

const SourceMapGenerator = @import("SourceMapGenerator.zig");
const Position = SourceMapGenerator.Position;
const Mapping = SourceMapGenerator.Mapping;

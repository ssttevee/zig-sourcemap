const std = @import("std");
const testing = std.testing;

const MappingSegment = @import("MappingSegment.zig");

const SourceMapGenerator = @This();

pub const Position = struct {
    line: u31,
    column: u31,
};

pub const Mapping = struct {
    generated: Position,
    original: ?struct {
        source: []const u8,
        position: Position,
        name: ?[]const u8 = null,
    } = null,
};

allocator: std.mem.Allocator,
file: []const u8,
source_root: []const u8,
sources: std.StringArrayHashMapUnmanaged(?[]const u8) = .{},
names: std.StringArrayHashMapUnmanaged(void) = .{},
mappings: std.ArrayListUnmanaged(std.ArrayListUnmanaged(MappingSegment)) = .{},

pub fn init(allocator: std.mem.Allocator, file: []const u8, source_root: []const u8) !SourceMapGenerator {
    return .{
        .allocator = allocator,
        .file = try allocator.dupe(u8, file),
        .source_root = try allocator.dupe(u8, source_root),
    };
}

pub fn deinit(self: *SourceMapGenerator) void {
    self.allocator.free(self.file);
    self.allocator.free(self.source_root);

    for (self.sources.keys(), self.sources.values()) |key, value| {
        self.allocator.free(key);
        if (value) |v| {
            self.allocator.free(v);
        }
    }

    self.sources.deinit(self.allocator);

    for (self.names.keys()) |key| {
        self.allocator.free(key);
    }

    self.names.deinit(self.allocator);

    for (self.mappings.items) |*line| {
        line.deinit(self.allocator);
    }

    self.mappings.deinit(self.allocator);

    self.* = undefined;
}

/// Set the source content for an original source file.
///
/// Ownership of original pointers is not transferred.
pub fn setSourceContent(self: *SourceMapGenerator, source_file: []const u8, source_content: ?[]const u8) !void {
    const result = try self.sources.getOrPut(self.allocator, source_file);
    if (result.found_existing) {
        if (result.value_ptr.*) |prev_source| {
            self.allocator.free(prev_source);
        }
    } else {
        result.key_ptr.* = try self.allocator.dupe(u8, source_file);
    }

    result.value_ptr.* = if (source_content) |content| try self.allocator.dupe(u8, content) else null;
}

/// Add a single mapping from original source line and column to the generated
/// source's line and column for this source map being created.
///
/// Ownership of original pointers passed through `mapping` is not transferred.
pub fn addMapping(self: *SourceMapGenerator, mapping: Mapping) !void {
    try self.mappings.ensureTotalCapacity(self.allocator, mapping.generated.line + 1);
    if (self.mappings.items.len <= mapping.generated.line) {
        self.mappings.appendNTimesAssumeCapacity(.{}, mapping.generated.line + 1 - self.mappings.items.len);
    }

    var segment = MappingSegment{
        .generated_column = mapping.generated.column,
    };

    if (mapping.original) |original| {
        segment.source = .{
            .index = @intCast(blk: {
                if (self.sources.getIndex(original.source)) |i| {
                    break :blk i;
                }

                try self.sources.put(self.allocator, try self.allocator.dupe(u8, original.source), null);

                break :blk self.sources.count();
            }),
            .line = original.position.line,
            .column = original.position.column,
            .name_index = blk: {
                if (original.name) |name| {
                    if (self.names.getIndex(name)) |i| {
                        break :blk @intCast(i);
                    }

                    try self.names.put(self.allocator, try self.allocator.dupe(u8, name), {});

                    break :blk @intCast(self.names.count());
                }

                break :blk null;
            },
        };
    }

    try self.mappings.items[mapping.generated.line].append(self.allocator, segment);
}

fn writeMappingsString(self: SourceMapGenerator, writer: anytype) !void {
    var prev_source_index: i32 = 0;
    var prev_source_line: i32 = 0;
    var prev_source_column: i32 = 0;
    var prev_name_index: i32 = 0;

    var buf: [MappingSegment.max_encoded_len]u8 = undefined;
    for (self.mappings.items, 0..) |line_segments, i| {
        if (i > 0) {
            try writer.writeByte(';');
        }

        var prev_generated_column: i64 = 0;

        for (line_segments.items, 0..) |segment, j| {
            if (j > 0) {
                try writer.writeByte(',');
            }

            defer prev_generated_column = segment.generated_column;

            try writer.writeAll((MappingSegment{
                .generated_column = segment.generated_column - prev_generated_column,
                .source = blk: {
                    if (segment.source) |source| {
                        defer {
                            prev_source_index = source.index;
                            prev_source_line = source.line;
                            prev_source_column = source.column;
                        }

                        break :blk .{
                            .index = source.index - prev_source_index,
                            .line = source.line - prev_source_line,
                            .column = source.column - prev_source_column,
                            .name_index = blk2: {
                                if (source.name_index) |name_index| {
                                    defer prev_name_index = name_index;

                                    break :blk2 name_index - prev_name_index;
                                }

                                break :blk2 null;
                            },
                        };
                    }

                    break :blk null;
                },
            }).encodeBuf(&buf) catch unreachable);
        }
    }
}

pub fn jsonStringify(self: SourceMapGenerator, stream: anytype) !void {
    try stream.beginObject();
    try stream.objectField("version");
    try stream.write(3);
    try stream.objectField("file");
    try stream.write(self.file);
    try stream.objectField("sourceRoot");
    try stream.write(self.source_root);
    try stream.objectField("sources");
    try stream.beginArray();
    for (self.sources.keys()) |source| {
        try stream.write(source);
    }
    try stream.endArray();
    try stream.objectField("sourcesContent");
    try stream.beginArray();
    for (self.sources.values()) |content| {
        try stream.write(content);
    }
    try stream.endArray();
    try stream.objectField("names");
    try stream.beginArray();
    for (self.names.keys()) |name| {
        try stream.write(name);
    }
    try stream.endArray();
    try stream.objectField("mappings");
    try stream.stream.writeByte('"');
    try self.writeMappingsString(stream.stream);
    stream.next_punctuation = .comma;
    try stream.stream.writeByte('"');
    try stream.endObject();
}

pub fn toJSON(self: SourceMapGenerator, allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    var stream = std.json.writeStream(out.writer(), .{});
    try self.jsonStringify(&stream);

    return out.toOwnedSlice();
}

test {
    var smg = try init(testing.allocator, "out.js", "");
    defer smg.deinit();

    try smg.setSourceContent("foo.js", null);
    try smg.setSourceContent("bar.js", null);

    try smg.addMapping(.{
        .generated = .{
            .line = 0,
            .column = 0,
        },
    });

    try smg.addMapping(.{
        .generated = .{
            .line = 0,
            .column = 0,
        },
        .original = .{
            .source = "foo.js",
            .position = .{
                .line = 0,
                .column = 1,
            },
        },
    });

    try smg.addMapping(.{
        .generated = .{
            .line = 2,
            .column = 0,
        },
        .original = .{
            .source = "bar.js",
            .position = .{
                .line = 1,
                .column = 2,
            },
        },
    });

    try smg.addMapping(.{
        .generated = .{
            .line = 2,
            .column = 1,
        },
        .original = .{
            .source = "bar.js",
            .position = .{
                .line = 3,
                .column = 1,
            },
        },
    });

    try smg.addMapping(.{
        .generated = .{
            .line = 2,
            .column = 2,
        },
        .original = .{
            .source = "foo.js",
            .position = .{
                .line = 3,
                .column = 2,
            },
        },
    });

    const json = try smg.toJSON(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings("{\"version\":3,\"file\":\"out.js\",\"sourceRoot\":\"\",\"sources\":[\"foo.js\",\"bar.js\"],\"sourcesContent\":[null,null],\"names\":[],\"mappings\":\"A,AAAC;;ACCC,CAED,CDAC\"}", json);
}

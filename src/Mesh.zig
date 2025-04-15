const std = @import("std");
const vk = @import("vulkan");
const vma = @import("vma");
const zm = @import("zmath");

const Renderer = @import("render/Renderer.zig");
const RID = Renderer.RID;
const Self = @This();

const rdr = Renderer.rdr;

pub const Vertex = [3]f32;

index_buffer: RID,
vertex_buffer: RID,
normal_buffer: RID,
texture_buffer: RID,

count: usize,
index_type: Renderer.IndexType,

pub fn init(
    comptime IndexType: type,
    indices: []const IndexType,
    vertices: []const Vertex,
    normals: []const Vertex,
    texture_coords: []const [2]f32,
) !Self {
    const index_buffer = try rdr().bufferCreate(.{ .size = @sizeOf(IndexType) * indices.len, .usage = .{ .index_buffer = true, .transfer_dst = true } });
    const vertex_buffer = try rdr().bufferCreate(.{ .size = @sizeOf(Vertex) * vertices.len, .usage = .{ .vertex_buffer = true, .transfer_dst = true } });
    const normal_buffer = try rdr().bufferCreate(.{ .size = @sizeOf(Vertex) * normals.len, .usage = .{ .vertex_buffer = true, .transfer_dst = true } });
    const texture_buffer = try rdr().bufferCreate(.{ .size = @sizeOf([2]f32) * texture_coords.len, .usage = .{ .vertex_buffer = true, .transfer_dst = true } });

    // TODO: Add a method to update multiple buffers at the same time.
    try rdr().bufferUpdate(index_buffer, std.mem.sliceAsBytes(indices), 0);
    try rdr().bufferUpdate(vertex_buffer, std.mem.sliceAsBytes(vertices), 0);
    try rdr().bufferUpdate(normal_buffer, std.mem.sliceAsBytes(normals), 0);
    try rdr().bufferUpdate(texture_buffer, std.mem.sliceAsBytes(texture_coords), 0);

    const index_type: Renderer.IndexType = switch (IndexType) {
        u16 => .uint16,
        u32 => .uint32,
        else => @compileError("Only u16 and u32 indices are supported"),
    };

    return .{
        .index_buffer = index_buffer,
        .vertex_buffer = vertex_buffer,
        .normal_buffer = normal_buffer,
        .texture_buffer = texture_buffer,
        .count = indices.len,
        .index_type = index_type,
    };
}

pub fn deinit(self: *const Self) void {
    self.vertex_buffer.deinit();
}

fn n(v: [3]f32) [3]f32 {
    const inv_length = 1.0 / std.math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return .{ v[0] * inv_length, v[1] * inv_length, v[2] * inv_length };
}

pub fn createCube() !Self {
    return init(u16, &.{
        0, 1, 2, 2, 3, 0, // front
        20, 21, 22, 22, 23, 20, // back
        4, 5, 6, 6, 7, 4, // right
        12, 13, 14, 14, 15, 12, // left
        8, 9, 10, 10, 11, 8, // top
        16, 17, 18, 18, 19, 16, // bottom
    }, &.{
        // front
        .{ 0.0, 0.0, 1.0 },
        .{ 1.0, 0.0, 1.0 },
        .{ 1.0, 1.0, 1.0 },
        .{ 0.0, 1.0, 1.0 },
        // back
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 1.0, 1.0, 0.0 },
        // left
        .{ 0.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 1.0 },
        .{ 0.0, 1.0, 1.0 },
        .{ 0.0, 1.0, 0.0 },
        // right
        .{ 1.0, 0.0, 1.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 1.0, 1.0, 0.0 },
        .{ 1.0, 1.0, 1.0 },
        // top
        .{ 0.0, 1.0, 1.0 },
        .{ 1.0, 1.0, 1.0 },
        .{ 1.0, 1.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        // bottom
        .{ 0.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 1.0 },
        .{ 0.0, 0.0, 1.0 },
    }, &.{
        // front
        n(.{ -0.5, -0.5, 0.5 }),
        n(.{ 0.5, -0.5, 0.5 }),
        n(.{ 0.5, 0.5, 0.5 }),
        n(.{ -0.5, 0.5, 0.5 }),
        // back
        n(.{ 0.5, -0.5, -0.5 }),
        n(.{ -0.5, -0.5, -0.5 }),
        n(.{ -0.5, 0.5, -0.5 }),
        n(.{ 0.5, 0.5, -0.5 }),
        // left
        n(.{ -0.5, -0.5, -0.5 }),
        n(.{ -0.5, -0.5, 0.5 }),
        n(.{ -0.5, 0.5, 0.5 }),
        n(.{ -0.5, 0.5, -0.5 }),
        // right
        n(.{ 0.5, -0.5, 0.5 }),
        n(.{ 0.5, -0.5, -0.5 }),
        n(.{ 0.5, 0.5, -0.5 }),
        n(.{ 0.5, 0.5, 0.5 }),
        // top
        n(.{ -0.5, 0.5, 0.5 }),
        n(.{ 0.5, 0.5, 0.5 }),
        n(.{ 0.5, 0.5, -0.5 }),
        n(.{ -0.5, 0.5, -0.5 }),
        // bottom
        n(.{ -0.5, -0.5, -0.5 }),
        n(.{ 0.5, -0.5, -0.5 }),
        n(.{ 0.5, -0.5, 0.5 }),
        n(.{ -0.5, -0.5, 0.5 }),
    }, &.{
        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 1.0, 1.0 },
        .{ 0.0, 1.0 },

        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 1.0, 1.0 },
        .{ 0.0, 1.0 },

        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 1.0, 1.0 },
        .{ 0.0, 1.0 },

        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 1.0, 1.0 },
        .{ 0.0, 1.0 },

        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 1.0, 1.0 },
        .{ 0.0, 1.0 },

        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 1.0, 1.0 },
        .{ 0.0, 1.0 },
    });
}

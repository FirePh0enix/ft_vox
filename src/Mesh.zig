const std = @import("std");
const vk = @import("vulkan");
const vma = @import("vma");
const zm = @import("zmath");
const Renderer = @import("render/Renderer.zig");

const Buffer = @import("render/Buffer.zig");
const Self = @This();

const rdr = Renderer.rdr;

pub const Vertex = [3]f32;

index_buffer: Buffer,
vertex_buffer: Buffer,
normal_buffer: Buffer,
texture_buffer: Buffer,
count: usize,
index_type: vk.IndexType,

pub fn init(
    comptime IndexType: type,
    indices: []const IndexType,
    vertices: []const Vertex,
    normals: []const Vertex,
    texture_coords: []const [2]f32,
) !Self {
    return .{
        .index_buffer = try rdr().createBufferFromData(IndexType, indices, .gpu_only, .{ .index_buffer = true, .transfer_dst = true }),
        .vertex_buffer = try rdr().createBufferFromData(Vertex, vertices, .gpu_only, .{ .vertex_buffer = true, .transfer_dst = true }),
        .normal_buffer = try rdr().createBufferFromData(Vertex, normals, .gpu_only, .{ .vertex_buffer = true, .transfer_dst = true }),
        .texture_buffer = try rdr().createBufferFromData([2]f32, texture_coords, .gpu_only, .{ .vertex_buffer = true, .transfer_dst = true }),
        .count = indices.len,
        .index_type = switch (IndexType) {
            u16 => .uint16,
            u32 => .uint32,
            else => @compileError("Only u16 and u32 are supported"),
        },
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

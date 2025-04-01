const std = @import("std");
const vk = @import("vulkan");
const vma = @import("vma");
const zm = @import("zmath");
const Renderer = @import("render/Renderer.zig");

const Buffer = @import("render/Buffer.zig");
const Self = @This();

pub const Vertex = [3]f32;

index_buffer: Buffer,
vertex_buffer: Buffer,
texture_buffer: Buffer,
count: usize,
index_type: vk.IndexType,

pub fn init(
    comptime IndexType: type,
    indices: []const IndexType,
    vertices: []const Vertex,
    texture_coords: []const [2]f32,
) !Self {
    return .{
        .index_buffer = try Buffer.createFromData(IndexType, indices, .{ .index_buffer_bit = true, .transfer_dst_bit = true }, .gpu_only),
        .vertex_buffer = try Buffer.createFromData(Vertex, vertices, .{ .vertex_buffer_bit = true, .transfer_dst_bit = true }, .gpu_only),
        .texture_buffer = try Buffer.createFromData([2]f32, texture_coords, .{ .vertex_buffer_bit = true, .transfer_dst_bit = true }, .gpu_only),
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

pub const PushConstants = extern struct {
    camera_matrix: zm.Mat,
};

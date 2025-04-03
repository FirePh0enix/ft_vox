const std = @import("std");
const vk = @import("vulkan");
const zm = @import("zmath");
const world = @import("../world.zig");

const Allocator = std.mem.Allocator;
const ShaderModel = @import("ShaderModel.zig");
const Buffer = @import("Buffer.zig");
const Renderer = @import("Renderer.zig");
const Self = @This();
const Mesh = @import("../Mesh.zig");
const Material = @import("../Material.zig");
const Camera = @import("../Camera.zig");
const World = world.World;

const rdr = Renderer.rdr;

pub const BlockInstanceData = struct {
    model_position: [3]f32,
};

allocator: Allocator,

mesh: Mesh,
material: Material,

pub fn create(allocator: Allocator, mesh: Mesh, material: Material) !Self {
    return .{
        .allocator = allocator,
        .mesh = mesh,
        .material = material,
    };
}

pub fn recordCommandBuffer(
    self: *const Self,
    command_buffer: Renderer.CommandBuffer,
    camera: *const Camera,
    the_world: *const World,
    framebuffer: vk.Framebuffer,
) !void {
    for (the_world.chunks.items) |chunk| {
        const instance_buffer_barrier: []const vk.BufferMemoryBarrier = &.{
            vk.BufferMemoryBarrier{
                .buffer = chunk.instance_buffer.buffer,
                .offset = 0,
                .size = @sizeOf(world.Chunk.BlockInstance) * world.Chunk.block_count,
                .src_queue_family_index = rdr().graphics_queue_index,
                .src_access_mask = .{},
                .dst_queue_family_index = rdr().graphics_queue_index,
                .dst_access_mask = .{ .vertex_attribute_read_bit = true },
            },
        };

        command_buffer.pipelineBarrier(
            .{ .vertex_input_bit = true },
            .{ .vertex_input_bit = true },
            .{ .by_region_bit = true },
            0,
            null,
            @intCast(instance_buffer_barrier.len),
            @ptrCast(instance_buffer_barrier.ptr),
            0,
            null,
        );
    }

    // Begin a new render pass.
    const clears: []const vk.ClearValue = &.{
        .{ .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 0.0 } } },
        .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0.0 } },
    };

    command_buffer.beginRenderPass(&vk.RenderPassBeginInfo{
        .render_pass = rdr().render_pass,
        .framebuffer = framebuffer,
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = rdr().swapchain_extent,
        },
        .clear_value_count = @intCast(clears.len),
        .p_clear_values = clears.ptr,
    }, .@"inline");

    for (the_world.chunks.items) |chunk| {
        // Bind command pipeline, buffer and other vulkan stuff.
        command_buffer.bindPipeline(.graphics, self.material.pipeline.pipeline);
        command_buffer.bindDescriptorSets(.graphics, self.material.pipeline.layout, 0, 1, @ptrCast(&self.material.descriptor_set), 0, null);

        command_buffer.bindIndexBuffer(self.mesh.index_buffer.buffer, 0, self.mesh.index_type);
        command_buffer.bindVertexBuffers(0, 1, @ptrCast(&self.mesh.vertex_buffer.buffer), &.{0});
        command_buffer.bindVertexBuffers(1, 1, @ptrCast(&self.mesh.texture_buffer), &.{0});

        command_buffer.bindVertexBuffers(2, 1, @ptrCast(&chunk.instance_buffer.buffer), &.{0});

        command_buffer.setViewport(0, 1, @ptrCast(&vk.Viewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(rdr().swapchain_extent.width),
            .height = @floatFromInt(rdr().swapchain_extent.height),
            .min_depth = 0.0,
            .max_depth = 1.0,
        }));

        command_buffer.setScissor(0, 1, @ptrCast(&vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = rdr().swapchain_extent,
        }));

        // Push constants
        const aspect_ratio = @as(f32, @floatFromInt(rdr().swapchain_extent.width)) / @as(f32, @floatFromInt(rdr().swapchain_extent.height));

        var projection_matrix = zm.perspectiveFovRh(std.math.degreesToRadians(60.0), aspect_ratio, 0.01, 1000.0);
        projection_matrix[1][1] *= -1;

        const camera_matrix = zm.mul(camera.getViewMatrix(), projection_matrix);

        const constants: Mesh.PushConstants = .{
            .camera_matrix = camera_matrix,
        };

        command_buffer.pushConstants(self.material.pipeline.layout, .{ .vertex_bit = true }, 0, @sizeOf(Mesh.PushConstants), @ptrCast(&constants));

        // And then we draw our instances.
        command_buffer.drawIndexed(@intCast(self.mesh.count), @intCast(chunk.instance_count), 0, 0, 0);
    }

    command_buffer.endRenderPass();
}

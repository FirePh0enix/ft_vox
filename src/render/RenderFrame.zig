const std = @import("std");
const vk = @import("vulkan");
const zm = @import("zmath");

const Allocator = std.mem.Allocator;
const ShaderModel = @import("ShaderModel.zig");
const Buffer = @import("Buffer.zig");
const Renderer = @import("Renderer.zig");
const Self = @This();
const Mesh = @import("../Mesh.zig");
const Material = @import("../Material.zig");
const Camera = @import("../Camera.zig");

const rdr = Renderer.rdr;

pub const BlockInstanceData = struct {
    model_matrix: zm.Mat,
};

allocator: Allocator,

block_instances: std.ArrayListUnmanaged(BlockInstanceData),
block_instance_buffer: Buffer,
block_instance_staging_buffer: Buffer,

mesh: Mesh,
material: Material,

const preallocated_instance_count: usize = 65536 * 64;

pub fn create(allocator: Allocator, mesh: Mesh, material: Material) !Self {
    return .{
        .allocator = allocator,
        .block_instances = try .initCapacity(allocator, preallocated_instance_count),
        .block_instance_buffer = try Buffer.create(preallocated_instance_count * @sizeOf(BlockInstanceData), .{ .vertex_buffer_bit = true, .transfer_dst_bit = true }, .gpu_only),
        .block_instance_staging_buffer = try Buffer.create(preallocated_instance_count * @sizeOf(BlockInstanceData), .{ .transfer_src_bit = true }, .cpu_to_gpu),

        .mesh = mesh,
        .material = material,
    };
}

pub fn reset(self: *Self) void {
    self.block_instances.clearRetainingCapacity();
}

pub fn addBlocks(self: *Self, instances: []const BlockInstanceData) !void {
    try self.block_instances.appendSlice(self.allocator, instances);
}

pub fn recordCommandBuffer(
    self: *const Self,
    command_buffer: Renderer.CommandBuffer,
    camera: *const Camera,
    framebuffer: vk.Framebuffer,
) !void {
    // Since we dont reallocate the instance buffer on the GPU, we need to make multiple calls to `vkCmdDrawIndexed` and update the buffer.
    // between calls using barriers.
    const draw_calls = std.math.divCeil(usize, self.block_instances.items.len, preallocated_instance_count) catch 0;

    const index = 0 * preallocated_instance_count;
    const count = @min(self.block_instances.items.len - index, preallocated_instance_count);

    if (count > 0) {
        const byte_index: usize = index * @sizeOf(BlockInstanceData);
        const byte_size: usize = count * @as(usize, @sizeOf(BlockInstanceData));

        // Copy instance data from CPU memory into the staging buffer.
        {
            const data = try self.block_instance_staging_buffer.map();
            defer self.block_instance_staging_buffer.unmap();

            @memcpy(data[0..byte_size], @as([*]u8, @ptrCast(self.block_instances.items.ptr))[byte_index .. byte_index + byte_size]);
        }

        // Issue a copy command to transfer instance data from the staging buffer to the final buffer.
        command_buffer.copyBuffer(self.block_instance_staging_buffer.buffer, self.block_instance_buffer.buffer, 1, @ptrCast(&vk.BufferCopy{
            .src_offset = 0,
            .dst_offset = 0,
            .size = byte_size,
        }));

        // Wait until the copy has finished.
        const instance_buffer_barrier: []const vk.BufferMemoryBarrier = &.{
            vk.BufferMemoryBarrier{
                .buffer = self.block_instance_buffer.buffer,
                .offset = 0,
                .size = byte_size,
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

    for (0..draw_calls) |draw_index| {
        _ = draw_index;

        // Bind command pipeline, buffer and other vulkan stuff.
        command_buffer.bindPipeline(.graphics, self.material.pipeline.pipeline);
        command_buffer.bindDescriptorSets(.graphics, self.material.pipeline.layout, 0, 1, @ptrCast(&self.material.descriptor_set), 0, null);

        command_buffer.bindIndexBuffer(self.mesh.index_buffer.buffer, 0, self.mesh.index_type);
        command_buffer.bindVertexBuffers(0, 1, @ptrCast(&self.mesh.vertex_buffer.buffer), &.{0});
        command_buffer.bindVertexBuffers(1, 1, @ptrCast(&self.mesh.texture_buffer), &.{0});

        command_buffer.bindVertexBuffers(2, 1, @ptrCast(&self.block_instance_buffer), &.{0});

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
        command_buffer.drawIndexed(@intCast(self.mesh.count), @intCast(self.block_instances.items.len), 0, 0, 0);
    }

    command_buffer.endRenderPass();
}

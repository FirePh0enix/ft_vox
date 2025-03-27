const std = @import("std");
const vk = @import("vulkan");
const vma = @import("vma");
const zigimg = @import("zigimg");

const Renderer = @import("Renderer.zig");
const Self = @This();
const Allocator = std.mem.Allocator;

image: vk.Image,
image_view: vk.ImageView,
allocation: vma.VmaAllocation,
width: u32,
height: u32,
sampler: vk.Sampler,

pub fn create(
    width: u32,
    height: u32,
    format: vk.Format,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
) !Self {
    const image_info: vk.ImageCreateInfo = .{
        .image_type = .@"2d",
        .format = format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
        .tiling = tiling,
        .usage = usage,
    };

    const alloc_info: vma.VmaAllocationCreateInfo = .{
        .usage = vma.VMA_MEMORY_USAGE_GPU_ONLY,
    };

    var image: vk.Image = .null_handle;
    var alloc: vma.VmaAllocation = undefined;

    if (vma.vmaCreateImage(Renderer.singleton.vma_allocator, @ptrCast(&image_info), @ptrCast(&alloc_info), @ptrCast(&image), &alloc, null) != vma.VK_SUCCESS)
        return error.Internal;
    errdefer vma.vmaDestroyImage(Renderer.singleton.vma_allocator, @ptrFromInt(@as(usize, @intFromEnum(image))), alloc);

    const image_view = try Renderer.singleton.device.createImageView(&vk.ImageViewCreateInfo{
        .image = image,
        .view_type = .@"2d",
        .format = format,
        .components = .{},
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_array_layer = 0,
            .layer_count = 1,
            .base_mip_level = 0,
            .level_count = 1,
        },
    }, null);
    errdefer Renderer.singleton.device.destroyImageView(image_view, null);

    const sampler = try Renderer.singleton.device.createSampler(&vk.SamplerCreateInfo{
        .mag_filter = .linear, // Linear is best for pixel art and voxels.
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0.0,
        .anisotropy_enable = vk.FALSE, // TODO: What is this
        .max_anisotropy = 0.0,
        .compare_enable = vk.FALSE,
        .compare_op = .equal,
        .min_lod = 0.0,
        .max_lod = 0.0,
        .border_color = .int_opaque_black,
        .unnormalized_coordinates = vk.FALSE,
    }, null);

    return .{
        .image = image,
        .allocation = alloc,
        .width = width,
        .height = height,

        .image_view = image_view,
        .sampler = sampler,
    };
}

pub fn createFromFile(
    allocator: Allocator,
    path: []const u8,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
) !Self {
    const image_data = try zigimg.Image.fromFilePath(allocator, path);
    defer image_data.deinit();

    const width: u32 = @intCast(image_data.width);
    const height: u32 = @intCast(image_data.height);

    const vk_format: vk.Format = switch (image_data.pixelFormat()) {
        .rgb24 => vk.Format.r8g8b8_sint,
        .rgb32 => vk.Format.r8g8b8a8_sint,
        else => error.FormatNotSupported,
    };

    const image = try create(width, height, vk_format, tiling, usage);
    image.store(image_data.rawBytes());
}

pub fn store(self: *Self, data: []const u8) void {
    var staging_buffer = try Renderer.Buffer.create(self.size, .{ .transfer_src_bit = true }, .cpu_to_gpu);
    defer staging_buffer.deinit();

    {
        const map_data = try staging_buffer.map();
        defer staging_buffer.unmap();

        const data_bytes: []const u8 = @as([*]const u8, @ptrCast(data.ptr))[0..self.size];
        @memcpy(map_data, data_bytes);
    }

    // Record the command buffer
    const begin_info: vk.CommandBufferBeginInfo = .{
        .flags = .{ .one_time_submit_bit = true },
    };
    try Renderer.singleton.buffer_transfer_command_buffer.resetCommandBuffer(.{});
    try Renderer.singleton.buffer_transfer_command_buffer.beginCommandBuffer(&begin_info);

    const regions: []const vk.BufferImageCopy = &.{
        vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{ .aspect_mask = .{ .color_bit = true }, .base_array_layer = 0, .layer_count = 1, .mip_level = 0 },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = self.width, .height = self.height, .depth = 1 },
        },
    };

    Renderer.singleton.buffer_transfer_command_buffer.copyBufferToImage(staging_buffer.buffer, self.image, .{ .transfer_dst_optimal = true }, @intCast(regions.len), regions.ptr);
    try Renderer.singleton.buffer_transfer_command_buffer.endCommandBuffer();

    const submit_info: vk.SubmitInfo = .{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&Renderer.singleton.buffer_transfer_command_buffer),
    };

    try Renderer.singleton.graphics_queue.submit(1, @ptrCast(&submit_info), .null_handle);
    try Renderer.singleton.device.deviceWaitIdle();
}

fn transferLayout(
    self: *const Self,
    format: vk.Format,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
) !void {
    const command_buffer = Renderer.singleton.buffer_transfer_command_buffer;

    try command_buffer.beginCommandBuffer(&vk.CommandBufferBeginInfo{});

    var src_stage: vk.PipelineStageFlags = undefined;
    var dst_stage: vk.PipelineStageFlags = undefined;

    const barrier: vk.ImageMemoryBarrier = .{
        .src_access_mask = .{},
        .dst_access_mask = .{},
        .old_layout = old_layout,
        .new_layout = new_layout,
        .image = self.image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_array_layer = 0,
            .layer_count = 1,
            .base_mip_level = 0,
            .level_count = 1,
        },
    };

    if (old_layout == .undefined and new_layout == .transfer_dst_optimal) {
        barrier.src_access_mask = .{};
        barrier.dst_access_mask = .{ .transfer_write_bit = true };

        src_stage = .{ .top_of_pipe_bit = true };
        dst_stage = .{ .transfer_bit = true };
    } else if (old_layout == .transfer_dst_optimal and new_layout == .shader_read_only_optimal) {
        barrier.src_access_mask = .{ .transfer_write_bit = true };
        barrier.dst_access_mask = .{ .shader_read_bit = true };

        src_stage = .{ .transfer_bit = true };
        dst_stage = .{ .fragment_shader_bit = true };
    } else if (old_layout == .undefined and new_layout == .depth_stencil_attachment_optimal) {
        barrier.src_access_mask = .{};
        barrier.dst_access_mask = .{ .depth_stencil_attachment_write_bit = true };

        src_stage = .{ .transfer_bit = true };
        dst_stage = .{ .fragment_shader_bit = true };
    }
}

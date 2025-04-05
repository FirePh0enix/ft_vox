const std = @import("std");
const vk = @import("vulkan");
const vma = @import("vma");
const zigimg = @import("zigimg");

const Renderer = @import("Renderer.zig");
const Self = @This();
const Allocator = std.mem.Allocator;
const Buffer = @import("Buffer.zig");

const rdr = Renderer.rdr;

width: u32,
height: u32,
layers: u32,

image: vk.Image,
image_view: vk.ImageView,
allocation: vma.VmaAllocation,

pub fn create(
    width: u32,
    height: u32,
    layers: u32,
    format: vk.Format,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
    aspect_mask: vk.ImageAspectFlags,
) !Self {
    const image_info: vk.ImageCreateInfo = .{
        .image_type = .@"2d",
        .format = format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = layers,
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

    const image_view = try rdr().device.createImageView(&vk.ImageViewCreateInfo{
        .image = image,
        .view_type = if (layers == 0) .@"2d" else .@"2d_array",
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = aspect_mask,
            .base_array_layer = 0,
            .layer_count = layers,
            .base_mip_level = 0,
            .level_count = 1,
        },
    }, null);
    errdefer rdr().device.destroyImageView(image_view, null);

    return .{
        .width = width,
        .height = height,
        .layers = layers,

        .image = image,
        .image_view = image_view,
        .allocation = alloc,
    };
}

pub fn createFromFile(
    allocator: Allocator,
    path: []const u8,
) !Self {
    var image_data = try zigimg.Image.fromFilePath(allocator, path);
    defer image_data.deinit();

    const width: u32 = @intCast(image_data.width);
    const height: u32 = @intCast(image_data.height);

    const vk_format: vk.Format = .r8g8b8a8_srgb;

    var image = try create(width, height, 1, vk_format, .optimal, .{ .sampled_bit = true, .transfer_dst_bit = true }, .{ .color_bit = true });
    errdefer image.deinit();

    try image.transferLayout(.undefined, .transfer_dst_optimal, .{ .color_bit = true });
    try image.store(0, image_data.rawBytes());
    try image.transferLayout(.transfer_dst_optimal, .shader_read_only_optimal, .{ .color_bit = true });

    return image;
}

pub fn createDepth(width: u32, height: u32) !Self {
    // TODO: Check supported format for depth images.
    const depth_format: vk.Format = .d32_sfloat;
    const tiling: vk.ImageTiling = .optimal;

    var image = try Self.create(width, height, 1, depth_format, tiling, .{ .depth_stencil_attachment_bit = true }, .{ .depth_bit = true });
    try image.transferLayout(.undefined, .depth_stencil_attachment_optimal, .{ .depth_bit = true });

    return image;
}

pub fn createMissing() !Self {
    const image = try create(16, 16, 1, .r8g8b8a8_srgb, .optimal, .{ .sampled_bit = true, .transfer_dst_bit = true }, .{ .color_bit = true });
    const pixels = createMissingPixels();

    try image.transferLayout(.undefined, .transfer_dst_optimal, .{ .color_bit = true });
    try image.store(0, &pixels);
    try image.transferLayout(.transfer_dst_optimal, .shader_read_only_optimal, .{ .color_bit = true });

    return image;
}

pub fn createMissingPixels() [16 * 16 * 4]u8 {
    var pixels: [16 * 16 * 4]u8 = undefined;

    for (0..8) |x| {
        for (0..8) |y| {
            pixels[0 * 4 * 8 + y * 8 + x] = 0xcc;
            pixels[1 * 4 * 8 + y * 8 + x] = 0x40;
            pixels[2 * 4 * 8 + y * 8 + x] = 0xc4;
            pixels[3 * 4 * 8 + y * 8 + x] = 0xff;
        }
    }

    for (0..8) |x| {
        for (0..8) |y| {
            pixels[0 * 4 * 8 + (y + 8) * 8 + x] = 0;
            pixels[1 * 4 * 8 + (y + 8) * 8 + x] = 0;
            pixels[2 * 4 * 8 + (y + 8) * 8 + x] = 0;
            pixels[3 * 4 * 8 + (y + 8) * 8 + x] = 0xff;
        }
    }

    for (0..8) |x| {
        for (0..8) |y| {
            pixels[0 * 4 * 8 + y * 8 + (x + 8)] = 0xcc;
            pixels[1 * 4 * 8 + y * 8 + (x + 8)] = 0x40;
            pixels[2 * 4 * 8 + y * 8 + (x + 8)] = 0xc4;
            pixels[3 * 4 * 8 + y * 8 + (x + 8)] = 0xff;
        }
    }

    for (0..8) |x| {
        for (0..8) |y| {
            pixels[0 * 4 * 8 + (y + 8) * 8 + (x + 8)] = 0xcc;
            pixels[1 * 4 * 8 + (y + 8) * 8 + (x + 8)] = 0x40;
            pixels[2 * 4 * 8 + (y + 8) * 8 + (x + 8)] = 0xc4;
            pixels[3 * 4 * 8 + (y + 8) * 8 + (x + 8)] = 0xff;
        }
    }

    return pixels;
}

pub fn deinit(self: *const Self) void {
    Renderer.singleton.device.destroyImageView(self.image_view, null);
}

pub fn store(
    self: *Self,
    layer: u32,
    data: []const u8,
) !void {
    var staging_buffer = try Buffer.create(data.len, .{ .transfer_src_bit = true }, .cpu_to_gpu);
    defer staging_buffer.deinit();

    {
        const map_data = try staging_buffer.map();
        defer staging_buffer.unmap();

        const data_bytes: []const u8 = @as([*]const u8, @ptrCast(data.ptr))[0..data.len];
        @memcpy(map_data, data_bytes);
    }

    // Record the command buffer
    try rdr().transfer_command_buffer.resetCommandBuffer(.{});
    try rdr().transfer_command_buffer.beginCommandBuffer(&vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
    });

    const regions: []const vk.BufferImageCopy = &.{
        vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .base_array_layer = layer,
                .layer_count = 1,
                .mip_level = 0,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = self.width, .height = self.height, .depth = 1 },
        },
    };

    rdr().transfer_command_buffer.copyBufferToImage(staging_buffer.buffer, self.image, .transfer_dst_optimal, @intCast(regions.len), regions.ptr);
    try rdr().transfer_command_buffer.endCommandBuffer();

    const submit_info: vk.SubmitInfo = .{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&rdr().transfer_command_buffer),
    };

    try rdr().graphics_queue.submit(1, @ptrCast(&submit_info), .null_handle);
    try rdr().graphics_queue.waitIdle();
}

pub fn transferLayout(
    self: *const Self,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    aspect_mask: vk.ImageAspectFlags,
) !void {
    const command_buffer = Renderer.singleton.transfer_command_buffer;

    try command_buffer.beginCommandBuffer(&vk.CommandBufferBeginInfo{});

    var src_stage_mask: vk.PipelineStageFlags = undefined;
    var dst_stage_mask: vk.PipelineStageFlags = undefined;

    var barrier: vk.ImageMemoryBarrier = .{
        .src_access_mask = .{},
        .dst_access_mask = .{},
        .old_layout = old_layout,
        .new_layout = new_layout,
        .image = self.image,
        .subresource_range = .{
            .aspect_mask = aspect_mask,
            .base_array_layer = 0,
            .layer_count = self.layers,
            .base_mip_level = 0,
            .level_count = 1,
        },
        .src_queue_family_index = 0,
        .dst_queue_family_index = 0,
    };

    if (old_layout == .undefined and new_layout == .transfer_dst_optimal) {
        barrier.src_access_mask = .{};
        barrier.dst_access_mask = .{ .transfer_write_bit = true };

        src_stage_mask = .{ .top_of_pipe_bit = true };
        dst_stage_mask = .{ .transfer_bit = true };
    } else if (old_layout == .transfer_dst_optimal and new_layout == .shader_read_only_optimal) {
        barrier.src_access_mask = .{ .transfer_write_bit = true };
        barrier.dst_access_mask = .{ .shader_read_bit = true };

        src_stage_mask = .{ .transfer_bit = true };
        dst_stage_mask = .{ .fragment_shader_bit = true };
    } else if (old_layout == .undefined and new_layout == .depth_stencil_attachment_optimal) {
        barrier.src_access_mask = .{};
        barrier.dst_access_mask = .{ .depth_stencil_attachment_read_bit = true };

        src_stage_mask = .{ .transfer_bit = true };
        dst_stage_mask = .{ .early_fragment_tests_bit = true };
    } else {
        return error.UnsupportedLayouts;
    }

    command_buffer.pipelineBarrier(src_stage_mask, dst_stage_mask, .{}, 0, null, 0, null, 1, @ptrCast(&barrier));
    try command_buffer.endCommandBuffer();
    try Renderer.singleton.graphics_queue.submit(1, &.{vk.SubmitInfo{ .command_buffer_count = 1, .p_command_buffers = @ptrCast(&command_buffer) }}, .null_handle);
    try Renderer.singleton.graphics_queue.waitIdle();
}

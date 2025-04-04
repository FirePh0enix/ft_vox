const std = @import("std");
const vk = @import("vulkan");

const Image = @import("render/Image.zig");
const GraphicsPipeline = @import("render/GraphicsPipeline.zig");
const Renderer = @import("render/Renderer.zig");
const Self = @This();

const rdr = Renderer.rdr;

image: Image,
pipeline: *GraphicsPipeline,
descriptor_set: vk.DescriptorSet,
sampler: vk.Sampler,

pub fn init(image: Image, pipeline: *GraphicsPipeline) !Self {
    const sampler = try rdr().device.createSampler(&vk.SamplerCreateInfo{
        .mag_filter = .nearest, // Nearest is best for pixel art and voxels.
        .min_filter = .nearest,
        .mipmap_mode = .nearest,
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

    var self: Self = .{
        .image = image,
        .pipeline = pipeline,
        .descriptor_set = try pipeline.descriptor_pool.createDescriptorSet(),
        .sampler = sampler,
    };
    self.writeDescriptors();

    return self;
}

pub fn writeDescriptors(self: *Self) void {
    const image_info: vk.DescriptorImageInfo = .{ .image_view = self.image.image_view, .sampler = self.sampler, .image_layout = .shader_read_only_optimal };

    const writes: []const vk.WriteDescriptorSet = &.{
        vk.WriteDescriptorSet{
            .dst_set = self.descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&image_info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
    };

    rdr().device.updateDescriptorSets(@intCast(writes.len), writes.ptr, 0, null);
}

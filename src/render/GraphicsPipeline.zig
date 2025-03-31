const std = @import("std");
const vk = @import("vulkan");
const shaders = @import("shaders");

const Self = @This();
const Renderer = @import("Renderer.zig");
const Device = Renderer.Device;
const Mesh = @import("../Mesh.zig");
const Allocator = std.mem.Allocator;

pipeline: vk.Pipeline,
layout: vk.PipelineLayout,
descriptor_pool: MaterialDescriptorPool,

pub const MaterialDescriptorPool = struct {
    pools: std.ArrayList(vk.DescriptorPool),
    count: usize,
    descriptor_set_layout: vk.DescriptorSetLayout,

    const pool_size: usize = 16;

    pub fn init(allocator: Allocator) !MaterialDescriptorPool {
        // TODO: Each pipeline should define its own descriptor set layout, bindings should not be harcoded.

        const bindings: []const vk.DescriptorSetLayoutBinding = &.{
            vk.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
        };
        const descriptor_set_layout = try Renderer.singleton.device.createDescriptorSetLayout(&vk.DescriptorSetLayoutCreateInfo{
            .binding_count = @intCast(bindings.len),
            .p_bindings = bindings.ptr,
        }, null);

        return .{
            .pools = .init(allocator),
            .count = 0,
            .descriptor_set_layout = descriptor_set_layout,
        };
    }

    pub fn deinit(self: *const MaterialDescriptorPool) void {
        for (self.pools.items) |pool| Renderer.singleton.device.destroyQueryPool(pool, null);
        self.pools.deinit();
    }

    pub fn createDescriptorSet(self: *MaterialDescriptorPool) !vk.DescriptorSet {
        if (self.count >= self.pools.items.len * pool_size) {
            // TODO: Should probably allocate as much of each bindings.

            const sizes: []const vk.DescriptorPoolSize = &.{.{ .type = .combined_image_sampler, .descriptor_count = pool_size }};
            const pool = try Renderer.singleton.device.createDescriptorPool(&vk.DescriptorPoolCreateInfo{
                .pool_size_count = @intCast(sizes.len),
                .p_pool_sizes = sizes.ptr,
                .max_sets = 1,
            }, null);

            try self.pools.append(pool);
        }

        const pool: vk.DescriptorPool = self.pools.items[self.count / pool_size];
        self.count += 1;

        var descriptor_set: vk.DescriptorSet = undefined;
        try Renderer.singleton.device.allocateDescriptorSets(&vk.DescriptorSetAllocateInfo{ .descriptor_pool = pool, .descriptor_set_count = 1, .p_set_layouts = @ptrCast(&self.descriptor_set_layout) }, @ptrCast(&descriptor_set));

        return descriptor_set;
    }
};

const basic_cube_vert align(@alignOf(u32)) = shaders.basic_cube_vert;
const basic_cube_frag align(@alignOf(u32)) = shaders.basic_cube_frag;

pub fn create(allocator: Allocator) !Self {
    const shader_stages: []const vk.PipelineShaderStageCreateInfo = &.{
        .{
            .stage = .{ .vertex_bit = true },
            .module = try Renderer.singleton.createShaderModule(&basic_cube_vert),
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = try Renderer.singleton.createShaderModule(&basic_cube_frag),
            .p_name = "main",
        },
    };

    const dynamic_states: []const vk.DynamicState = &.{ .viewport, .scissor };
    const dynamic_state_info: vk.PipelineDynamicStateCreateInfo = .{
        .dynamic_state_count = @intCast(dynamic_states.len),
        .p_dynamic_states = dynamic_states.ptr,
    };

    const vertex_input_info: vk.PipelineVertexInputStateCreateInfo = .{
        .vertex_binding_description_count = @intCast(Mesh.binding_descriptions.len),
        .p_vertex_binding_descriptions = Mesh.binding_descriptions.ptr,
        .vertex_attribute_description_count = @intCast(Mesh.attribute_descriptions.len),
        .p_vertex_attribute_descriptions = Mesh.attribute_descriptions.ptr,
    };

    const input_assembly_info: vk.PipelineInputAssemblyStateCreateInfo = .{
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
    };

    const viewport_info: vk.PipelineViewportStateCreateInfo = .{
        .viewport_count = 1,
        .scissor_count = 1,
    };

    const rasterizer_info: vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = vk.FALSE,
        .depth_bias_clamp = 0.0,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .line_width = 1.0,
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise, // TODO: should be .counter_clockwise ?
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0.0,
        .depth_bias_slope_factor = 0.0,
    };

    const multisample_info: vk.PipelineMultisampleStateCreateInfo = .{
        .sample_shading_enable = vk.FALSE,
        .rasterization_samples = .{ .@"1_bit" = true },
        .min_sample_shading = 1.0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };

    const blend_state: vk.PipelineColorBlendAttachmentState = .{
        .blend_enable = vk.FALSE, // TODO: Support transparency
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };

    const blend_info: vk.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&blend_state),
        .blend_constants = .{ 0.0, 0.0, 0.0, 0.0 },
    };

    const depth_info: vk.PipelineDepthStencilStateCreateInfo = .{
        .depth_test_enable = vk.TRUE,
        .depth_write_enable = vk.TRUE,
        .depth_compare_op = .less,
        .depth_bounds_test_enable = vk.FALSE,
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
        .stencil_test_enable = vk.FALSE,
        .front = std.mem.zeroes(vk.StencilOpState),
        .back = std.mem.zeroes(vk.StencilOpState),
    };

    const push_constants: []const vk.PushConstantRange = &.{
        vk.PushConstantRange{ .offset = 0, .size = @sizeOf(Mesh.PushConstants), .stage_flags = .{ .vertex_bit = true } },
    };

    const descriptor_pool = try MaterialDescriptorPool.init(allocator);

    // TODO: Everything related to descriptor pools should be reworked to allow for customization, maybe by introducing a `Shader`
    //       type to configure everything from input bindings, descriptor set layouts and push constants.

    const layout_info: vk.PipelineLayoutCreateInfo = .{
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&descriptor_pool.descriptor_set_layout),
        .push_constant_range_count = @intCast(push_constants.len),
        .p_push_constant_ranges = push_constants.ptr,
    };

    const pipeline_layout = try Renderer.singleton.device.createPipelineLayout(&layout_info, null);

    const pipeline_info: vk.GraphicsPipelineCreateInfo = .{
        .stage_count = @intCast(shader_stages.len),
        .p_stages = shader_stages.ptr,
        .p_vertex_input_state = &vertex_input_info,
        .p_input_assembly_state = &input_assembly_info,
        .p_viewport_state = &viewport_info,
        .p_rasterization_state = &rasterizer_info,
        .p_multisample_state = &multisample_info,
        .p_depth_stencil_state = &depth_info,
        .p_color_blend_state = &blend_info,
        .p_dynamic_state = &dynamic_state_info,
        .layout = pipeline_layout,
        .render_pass = Renderer.singleton.render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = .null_handle;
    _ = try Renderer.singleton.device.createGraphicsPipelines(.null_handle, 1, @ptrCast(&pipeline_info), null, @ptrCast(&pipeline));
    errdefer Renderer.singleton.device.destroyPipeline(pipeline, null);

    return .{
        .pipeline = pipeline,
        .layout = pipeline_layout,
        .descriptor_pool = descriptor_pool,
    };
}

pub fn deinit(self: *const Self, device: Device) void {
    device.destroyPipelineLayout(self.layout, null);
    device.destroyPipeline(self.pipeline, null);
}

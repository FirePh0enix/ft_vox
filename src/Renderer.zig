const std = @import("std");
const vk = @import("vulkan");
const sdl = @import("sdl");
const builtin = @import("builtin");
const root = @import("root");
const shaders = @import("shaders");

const Allocator = std.mem.Allocator;
const Self = @This();

const apis: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
};

const Base = vk.BaseWrapper(apis);
const Instance = vk.InstanceProxy(apis);
const Device = vk.DeviceProxy(apis);
const CommandBuffer = vk.CommandBufferProxy(apis);
const Queue = vk.QueueProxy(apis);

const GetInstanceProcAddrFn = fn (instance: vk.Instance, name: [*:0]const u8) callconv(.c) ?*const fn () void;
const GetDeviceProcAddrFn = fn (device: vk.Device, name: [*:0]const u8) callconv(.c) ?*const fn () void;

allocator: Allocator,
instance: Instance,
device: Device,
surface: vk.SurfaceKHR,
physical_device: vk.PhysicalDevice,
window: *sdl.SDL_Window,
swapchain: vk.SwapchainKHR = .null_handle,
swapchain_images: []vk.Image = &.{},
swapchain_image_views: []vk.ImageView = &.{},
swapchain_framebuffers: []vk.Framebuffer = &.{},
swapchain_extent: vk.Extent2D = .{ .width = 0, .height = 0 },
swapchain_format: vk.SurfaceFormatKHR = undefined,
render_pass: vk.RenderPass = .null_handle,
command_pool: vk.CommandPool,

graphics_queue_index: u32,
graphics_queue: Queue,
present_queue_index: u32,
present_queue: Queue,

features: Features,

basic_pipeline: GraphicsPipeline = .{},

command_buffer: CommandBuffer,

image_available_semaphore: vk.Semaphore,
render_finished_semaphore: vk.Semaphore,
in_flight_fence: vk.Fence,

pub const Features = struct {
    ray_tracing: bool = false,
};

pub const GraphicsPipeline = struct {
    pipeline: vk.Pipeline = .null_handle,
    layout: vk.PipelineLayout = .null_handle,

    pub fn deinit(self: *const GraphicsPipeline, device: Device) void {
        device.destroyPipelineLayout(self.layout, null);
        device.destroyPipeline(self.pipeline, null);
    }
};

pub const InitError = error{
    /// No suitable device found to run the app.
    NoDevice,

    /// Missing Graphics or Present Queue.
    NoGraphicsQueue,
};

var instance_wrapper: vk.InstanceWrapper(apis) = undefined;
var device_wrapper: vk.DeviceWrapper(apis) = undefined;

pub var singleton: Self = undefined;

const basic_cube_vert align(@alignOf(u32)) = shaders.basic_cube_vert;
const basic_cube_frag align(@alignOf(u32)) = shaders.basic_cube_frag;

pub fn init(
    allocator: std.mem.Allocator,
    window: *sdl.SDL_Window,
    get_proc_addr: *const GetInstanceProcAddrFn,
    instance_extensions: ?[*]const ?[*:0]const u8,
    instance_extensions_count: u32,
) !void {
    const vkb = try Base.load(get_proc_addr);

    // Create a vulkan instance
    const app_info: vk.ApplicationInfo = .{
        .api_version = @bitCast(vk.API_VERSION_1_3),
        .application_version = @bitCast(vk.makeApiVersion(0, 0, 1, 0)),
        .engine_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
    };

    const instance_info: vk.InstanceCreateInfo = .{
        .p_application_info = &app_info,
        .enabled_layer_count = if (builtin.mode == .Debug) 1 else 0,
        .pp_enabled_layer_names = if (builtin.mode == .Debug) &.{"VK_LAYER_KHRONOS_validation"} else null,
        .enabled_extension_count = instance_extensions_count,
        .pp_enabled_extension_names = @ptrCast(instance_extensions),
    };

    const instance_handle = try vkb.createInstance(&instance_info, null);
    instance_wrapper = try vk.InstanceWrapper(apis).load(instance_handle, get_proc_addr);

    const instance = Instance.init(instance_handle, &instance_wrapper);
    errdefer instance.destroyInstance(null);

    const required_features: vk.PhysicalDeviceFeatures = .{};
    const optional_features: vk.PhysicalDeviceFeatures = .{};
    const required_extensions: []const [*:0]const u8 = &.{
        vk.extensions.khr_swapchain.name.ptr,
    };
    const optional_extensions: []const [*:0]const u8 = &.{
        vk.extensions.khr_deferred_host_operations.name.ptr,
        vk.extensions.khr_acceleration_structure.name.ptr,
        vk.extensions.khr_ray_tracing_pipeline.name.ptr,
    };

    // Select the best physical device.
    const physical_devices = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(physical_devices);

    const physical_device_with_info = (try getBestDevice(allocator, instance, physical_devices, required_features, optional_features, required_extensions, optional_extensions)) orelse return InitError.NoDevice;
    const physical_device = physical_device_with_info.physical_device;
    const device_properties = instance.getPhysicalDeviceProperties(physical_device);

    const features: Features = .{
        .ray_tracing = containsExtension(physical_device_with_info.extensions, vk.extensions.khr_ray_tracing_pipeline.name),
    };

    std.log.info("GPU selected: {s}", .{device_properties.device_name});

    inline for (@typeInfo(Features).@"struct".fields) |field| {
        if (@field(features, field.name)) std.log.info("Feature `{s}` is ON", .{field.name});
    }

    // Create the surface
    var sdl_surface: sdl.VkSurfaceKHR = undefined;
    const sdl_instance: sdl.VkInstance = @ptrFromInt(@as(usize, @intFromEnum(instance.handle)));
    _ = sdl.SDL_Vulkan_CreateSurface(window, sdl_instance, null, &sdl_surface);
    const surface: vk.SurfaceKHR = @enumFromInt(@as(usize, @intFromPtr(sdl_surface)));
    errdefer instance.destroySurfaceKHR(surface, null);

    // Create queues
    const queue_properties_list = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, allocator);
    defer allocator.free(queue_properties_list);

    var graphics_queue_maybe: ?u32 = null;
    var present_queue_maybe: ?u32 = null;

    for (queue_properties_list, 0..queue_properties_list.len) |queue_properties, index| {
        if (queue_properties.queue_flags.graphics_bit) {
            graphics_queue_maybe = @intCast(index);
        }

        const present_support = try instance.getPhysicalDeviceSurfaceSupportKHR(physical_device, @intCast(index), surface) != 0;

        if (present_support) {
            present_queue_maybe = @intCast(index);
        }
    }

    // Create the device.
    const graphics_queue_index = if (graphics_queue_maybe) |v| v else return InitError.NoGraphicsQueue;
    const present_queue_index = if (present_queue_maybe) |v| v else return InitError.NoGraphicsQueue;
    const queue_priorities: []const f32 = &.{1.0};

    const queue_infos: []const vk.DeviceQueueCreateInfo = &.{
        vk.DeviceQueueCreateInfo{
            .queue_family_index = graphics_queue_index,
            .queue_count = queue_priorities.len,
            .p_queue_priorities = queue_priorities.ptr,
        },
        vk.DeviceQueueCreateInfo{
            .queue_family_index = present_queue_index,
            .queue_count = queue_priorities.len,
            .p_queue_priorities = queue_priorities.ptr,
        },
    };

    const device_extensions = a: {
        var extensions = std.ArrayList([*:0]const u8).init(allocator);

        for (required_extensions) |ext| {
            try extensions.append(ext);
        }

        for (optional_extensions) |ext| {
            if (containsExtension(physical_device_with_info.extensions, ext)) try extensions.append(ext);
        }

        break :a try extensions.toOwnedSlice();
    };
    defer allocator.free(device_extensions);

    const device_features = a: {
        const actual_features = physical_device_with_info.features;
        var device_features: vk.PhysicalDeviceFeatures = required_features;

        inline for (@typeInfo(vk.PhysicalDeviceFeatures).@"struct".fields) |field| {
            if (@field(actual_features, field.name) == vk.TRUE)
                @field(device_features, field.name) = vk.TRUE;
        }

        break :a device_features;
    };

    physical_device_with_info.deinit(allocator); // free `physical_device_with_info.extensions`

    const device_info: vk.DeviceCreateInfo = .{
        .queue_create_info_count = @intCast(queue_infos.len),
        .p_queue_create_infos = queue_infos.ptr,
        .enabled_layer_count = if (builtin.mode == .Debug) 1 else 0,
        .pp_enabled_layer_names = if (builtin.mode == .Debug) &.{"VK_LAYER_KHRONOS_validation"} else null,
        .enabled_extension_count = @intCast(device_extensions.len),
        .pp_enabled_extension_names = device_extensions.ptr,
        .p_enabled_features = &device_features,
    };

    const device_proc_addr: *const GetDeviceProcAddrFn = @ptrCast(instance_wrapper.dispatch.vkGetDeviceProcAddr);

    const device_handle = try instance.createDevice(physical_device, &device_info, null);
    // errdefer instance_wrapper.dispatch.vkDestroyDevice(device_handle, null);
    device_wrapper = try .load(device_handle, device_proc_addr);

    const device = Device.init(device_handle, &device_wrapper);

    const graphics_queue = device.getDeviceQueue(graphics_queue_index, 0);
    const present_queue = device.getDeviceQueue(present_queue_index, 0);

    std.debug.assert(graphics_queue != .null_handle);
    std.debug.assert(present_queue != .null_handle);

    // Allocate command buffers
    const pool_info: vk.CommandPoolCreateInfo = .{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = graphics_queue_index,
    };

    const command_pool = try device.createCommandPool(&pool_info, null);

    const command_buffer_info: vk.CommandBufferAllocateInfo = .{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };

    var command_buffer: vk.CommandBuffer = .null_handle;
    try device.allocateCommandBuffers(&command_buffer_info, @ptrCast(&command_buffer));

    // Create synchronization primitives.

    const semaphore_info: vk.SemaphoreCreateInfo = .{};
    const fence_info: vk.FenceCreateInfo = .{
        .flags = .{ .signaled_bit = true },
    };

    const image_available_semaphore = try device.createSemaphore(&semaphore_info, null);
    const render_finished_semaphore = try device.createSemaphore(&semaphore_info, null);
    const in_flight_fence = try device.createFence(&fence_info, null);

    var self: Self = .{
        .allocator = allocator,
        .instance = instance,
        .device = device,
        .graphics_queue_index = graphics_queue_index,
        .graphics_queue = Queue.init(graphics_queue, &device_wrapper),
        .present_queue_index = present_queue_index,
        .present_queue = Queue.init(graphics_queue, &device_wrapper),
        .surface = surface,
        .physical_device = physical_device,
        .command_pool = command_pool,
        .window = window,
        .features = features,

        .command_buffer = CommandBuffer.init(command_buffer, &device_wrapper),

        .image_available_semaphore = image_available_semaphore,
        .render_finished_semaphore = render_finished_semaphore,
        .in_flight_fence = in_flight_fence,
    };

    try self.createSwapchain();
    self.basic_pipeline = try self.createGraphicsPipeline();

    singleton = self;
}

pub fn deinit(self: *const Self) void {
    self.device.deviceWaitIdle() catch {};

    // TODO
    // self.allocator.free(self.swapchain_image_views);
    // self.allocator.free(self.swapchain_images);

    // self.device.destroyDevice(&vk_allocation_callbacks);
    // self.instance.destroyInstance(&vk_allocation_callbacks);
}

pub fn draw(self: *const Self) !void {
    _ = try self.device.waitForFences(1, @ptrCast(&self.in_flight_fence), vk.TRUE, std.math.maxInt(u64));
    try self.device.resetFences(1, @ptrCast(&self.in_flight_fence));

    const image_index_result = try self.device.acquireNextImageKHR(self.swapchain, std.math.maxInt(u64), self.image_available_semaphore, .null_handle);
    const image_index = image_index_result.image_index;

    const command_buffer = self.command_buffer;

    try command_buffer.resetCommandBuffer(.{});

    // Record the command buffer
    const begin_info: vk.CommandBufferBeginInfo = .{
        .flags = .{ .one_time_submit_bit = true },
    };
    try command_buffer.beginCommandBuffer(&begin_info);

    const clear_color: vk.ClearValue = .{
        .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 0.0 } },
    };

    const render_pass_begin_info: vk.RenderPassBeginInfo = .{
        .render_pass = self.render_pass,
        .framebuffer = self.swapchain_framebuffers[image_index],
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        },
        .clear_value_count = 1,
        .p_clear_values = @ptrCast(&clear_color),
    };

    command_buffer.beginRenderPass(&render_pass_begin_info, .@"inline");

    command_buffer.bindPipeline(.graphics, self.basic_pipeline.pipeline);

    const viewport: vk.Viewport = .{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(self.swapchain_extent.width),
        .height = @floatFromInt(self.swapchain_extent.height),
        .min_depth = 0.0,
        .max_depth = 1.0,
    };

    command_buffer.setViewport(0, 1, @ptrCast(&viewport));

    const scissor: vk.Rect2D = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = self.swapchain_extent,
    };

    command_buffer.setScissor(0, 1, @ptrCast(&scissor));

    command_buffer.draw(3, 1, 0, 0);

    command_buffer.endRenderPass();

    try command_buffer.endCommandBuffer();

    // Submit the frame
    const wait_semaphores: []const vk.Semaphore = &.{self.image_available_semaphore};
    const wait_stages: []const vk.PipelineStageFlags = &.{.{ .color_attachment_output_bit = true }};

    const signal_semaphores: []const vk.Semaphore = &.{self.render_finished_semaphore};

    const submit_info: vk.SubmitInfo = .{
        .wait_semaphore_count = @intCast(wait_semaphores.len),
        .p_wait_semaphores = wait_semaphores.ptr,
        .p_wait_dst_stage_mask = wait_stages.ptr,

        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&command_buffer),

        .signal_semaphore_count = @intCast(signal_semaphores.len),
        .p_signal_semaphores = signal_semaphores.ptr,
    };

    try self.graphics_queue.submit(1, @ptrCast(&submit_info), self.in_flight_fence);

    const present_info: vk.PresentInfoKHR = .{
        .wait_semaphore_count = @intCast(signal_semaphores.len),
        .p_wait_semaphores = signal_semaphores.ptr,
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&self.swapchain),
        .p_image_indices = @ptrCast(&image_index),
    };

    _ = try self.graphics_queue.presentKHR(&present_info);
}

fn createSwapchain(
    self: *Self,
) !void {
    var width: i32 = undefined;
    var height: i32 = undefined;
    _ = sdl.SDL_GetWindowSize(self.window, &width, &height);

    const surface_capabilities = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface);
    const surface_formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(self.physical_device, self.surface, self.allocator);
    defer self.allocator.free(surface_formats);

    const surface_present_modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(self.physical_device, self.surface, self.allocator);
    defer self.allocator.free(surface_present_modes);

    const surface_format: vk.SurfaceFormatKHR = .{ .color_space = .srgb_nonlinear_khr, .format = .b8g8r8a8_srgb };
    const surface_present_mode: vk.PresentModeKHR = .fifo_khr;

    const surface_extent: vk.Extent2D = .{
        .width = @intCast(@max(surface_capabilities.min_image_extent.width, @as(u32, @intCast(width)))),
        .height = @intCast(@max(surface_capabilities.min_image_extent.height, @as(u32, @intCast(height)))),
    };

    const image_count = if (surface_capabilities.max_image_count > 0 and surface_capabilities.min_image_count + 1 > surface_capabilities.max_image_count)
        surface_capabilities.max_image_count
    else
        surface_capabilities.min_image_count + 1;

    var swapchain_info: vk.SwapchainCreateInfoKHR = .{
        .surface = self.surface,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = surface_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true },
        .image_sharing_mode = .exclusive,
        .pre_transform = surface_capabilities.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = surface_present_mode,
        .clipped = vk.TRUE,
        .old_swapchain = self.swapchain,
    };

    const queue_indices: []const u32 = &.{ self.graphics_queue_index, self.present_queue_index };

    if (self.present_queue_index != self.graphics_queue_index) {
        swapchain_info.image_sharing_mode = .concurrent;
        swapchain_info.queue_family_index_count = @intCast(queue_indices.len);
        swapchain_info.p_queue_family_indices = queue_indices.ptr;
    }

    const swapchain = try self.device.createSwapchainKHR(&swapchain_info, null);
    errdefer self.device.destroySwapchainKHR(swapchain, null);

    const color_attach: vk.AttachmentDescription = .{
        .format = surface_format.format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };

    const attach_ref: vk.AttachmentReference = .{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };

    const subpass: vk.SubpassDescription = .{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&attach_ref),
    };

    const dependency: vk.SubpassDependency = .{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output_bit = true },
        .src_access_mask = .{},
        .dst_stage_mask = .{ .color_attachment_output_bit = true },
        .dst_access_mask = .{ .color_attachment_write_bit = true },
    };

    const render_pass_info: vk.RenderPassCreateInfo = .{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&color_attach),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
        .dependency_count = 1,
        .p_dependencies = @ptrCast(&dependency),
    };

    const render_pass = try self.device.createRenderPass(&render_pass_info, null);
    errdefer self.device.destroyRenderPass(render_pass, null);

    const swapchain_images = try self.device.getSwapchainImagesAllocKHR(swapchain, self.allocator);
    errdefer self.allocator.free(swapchain_images);

    const swapchain_image_views = try self.allocator.alloc(vk.ImageView, swapchain_images.len);
    errdefer self.allocator.free(swapchain_image_views);

    const swapchain_framebuffers = try self.allocator.alloc(vk.Framebuffer, swapchain_images.len);
    errdefer self.allocator.free(swapchain_framebuffers);

    for (swapchain_images, 0..swapchain_images.len) |image, index| {
        const image_view_info: vk.ImageViewCreateInfo = .{
            .image = image,
            .view_type = .@"2d",
            .format = surface_format.format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        const image_view = try self.device.createImageView(&image_view_info, null);
        swapchain_image_views[index] = image_view;

        const attachments: []const vk.ImageView = &.{image_view};

        const framebuffer_info: vk.FramebufferCreateInfo = .{
            .render_pass = render_pass,
            .attachment_count = @intCast(attachments.len),
            .p_attachments = attachments.ptr,
            .width = surface_extent.width,
            .height = surface_extent.height,
            .layers = 1,
        };

        swapchain_framebuffers[index] = try self.device.createFramebuffer(&framebuffer_info, null);
    }

    self.destroySwapchain();

    self.swapchain = swapchain;
    self.swapchain_images = swapchain_images;
    self.swapchain_image_views = swapchain_image_views;
    self.swapchain_framebuffers = swapchain_framebuffers;
    self.swapchain_format = surface_format;
    self.swapchain_extent = surface_extent;
    self.render_pass = render_pass;
}

fn destroySwapchain(self: *const Self) void {
    if (self.swapchain != .null_handle) {
        for (self.swapchain_image_views) |image_view| {
            self.device.destroyImageView(image_view, null);
        }

        for (self.swapchain_framebuffers) |framebuffer| {
            self.device.destroyFramebuffer(framebuffer, null);
        }

        self.allocator.free(self.swapchain_images);
        self.allocator.free(self.swapchain_image_views);
        self.allocator.free(self.swapchain_framebuffers);

        self.device.destroyRenderPass(self.render_pass, null);
        self.device.destroySwapchainKHR(self.swapchain, null);
    }
}

pub fn createGraphicsPipeline(self: *const Self) !GraphicsPipeline {
    const shader_stages: []const vk.PipelineShaderStageCreateInfo = &.{
        .{
            .stage = .{ .vertex_bit = true },
            .module = try self.createShaderModule(&basic_cube_vert),
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = try self.createShaderModule(&basic_cube_frag),
            .p_name = "main",
        },
    };

    const dynamic_states: []const vk.DynamicState = &.{ .viewport, .scissor };
    const dynamic_state_info: vk.PipelineDynamicStateCreateInfo = .{
        .dynamic_state_count = @intCast(dynamic_states.len),
        .p_dynamic_states = dynamic_states.ptr,
    };

    const vertex_input_info: vk.PipelineVertexInputStateCreateInfo = .{
        .vertex_binding_description_count = 0,
        .vertex_attribute_description_count = 0,
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
        .front_face = .clockwise,
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

    const layout_info: vk.PipelineLayoutCreateInfo = .{
        .set_layout_count = 0,
        .p_set_layouts = null,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = null,
    };

    const pipeline_layout = try self.device.createPipelineLayout(&layout_info, null);

    const pipeline_info: vk.GraphicsPipelineCreateInfo = .{
        .stage_count = @intCast(shader_stages.len),
        .p_stages = shader_stages.ptr,
        .p_vertex_input_state = &vertex_input_info,
        .p_input_assembly_state = &input_assembly_info,
        .p_viewport_state = &viewport_info,
        .p_rasterization_state = &rasterizer_info,
        .p_multisample_state = &multisample_info,
        .p_depth_stencil_state = null,
        .p_color_blend_state = &blend_info,
        .p_dynamic_state = &dynamic_state_info,
        .layout = pipeline_layout,
        .render_pass = self.render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = .null_handle;
    _ = try self.device.createGraphicsPipelines(.null_handle, 1, @ptrCast(&pipeline_info), null, @ptrCast(&pipeline));

    return .{
        .pipeline = pipeline,
        .layout = pipeline_layout,
    };
}

fn createShaderModule(self: *const Self, spirv: [:0]align(4) const u8) Device.CreateShaderModuleError!vk.ShaderModule {
    const shader_info: vk.ShaderModuleCreateInfo = .{
        .code_size = spirv.len,
        .p_code = @ptrCast(spirv.ptr),
    };

    return self.device.createShaderModule(&shader_info, null);
}

const DeviceWithInfo = struct {
    physical_device: vk.PhysicalDevice,
    properties: vk.PhysicalDeviceProperties,
    features: vk.PhysicalDeviceFeatures,
    extensions: []const vk.ExtensionProperties,

    pub fn deinit(self: *const DeviceWithInfo, allocator: Allocator) void {
        allocator.free(self.extensions);
    }
};

fn calculateDeviceScore(
    properties: vk.PhysicalDeviceProperties,
    features: vk.PhysicalDeviceFeatures,
    required_features: vk.PhysicalDeviceFeatures,
    optional_features: vk.PhysicalDeviceFeatures,
    extensions: []vk.ExtensionProperties,
    required_extensions: []const [*:0]const u8,
    optional_extensions: []const [*:0]const u8,
) i32 {
    var score: i32 = 0;

    switch (properties.device_type) {
        .discrete_gpu => score += 1000,
        .virtual_gpu => score += 100,
        .integrated_gpu => score += 10,
        else => {},
    }

    inline for (@typeInfo(vk.PhysicalDeviceFeatures).@"struct".fields) |field| {
        if (@field(required_features, field.name) == vk.TRUE and @field(features, field.name) == vk.FALSE)
            return 0; // If a required feature is not supported then the GPU cannot be used.

        if (@field(optional_features, field.name) == vk.TRUE and @field(features, field.name) == vk.TRUE)
            score += 50;
    }

    _ = extensions;
    _ = required_extensions;
    _ = optional_extensions;

    return score;
}

fn getBestDevice(
    allocator: Allocator,
    instance: Instance,
    devices: []const vk.PhysicalDevice,
    required_features: vk.PhysicalDeviceFeatures,
    optional_features: vk.PhysicalDeviceFeatures,
    required_extensions: []const [*:0]const u8,
    optional_extensions: []const [*:0]const u8,
) !?DeviceWithInfo {
    var best_device: ?DeviceWithInfo = null;
    var max_score: i32 = -1;

    for (devices) |device| {
        const properties = instance.getPhysicalDeviceProperties(device);
        const features = instance.getPhysicalDeviceFeatures(device);
        const extensions = try instance.enumerateDeviceExtensionPropertiesAlloc(device, null, allocator);

        const score = calculateDeviceScore(properties, features, required_features, optional_features, extensions, required_extensions, optional_extensions);

        if (score > max_score) {
            if (best_device) |bd| bd.deinit(allocator);

            max_score = score;

            var extensions_strings = try std.ArrayList([*:0]const u8).initCapacity(allocator, extensions.len);
            for (extensions) |extension| {
                const name: [:0]const u8 = extension.extension_name[0 .. std.mem.indexOfScalar(u8, &extension.extension_name, 0) orelse 256 :0];
                extensions_strings.appendAssumeCapacity(name.ptr);
            }

            best_device = DeviceWithInfo{
                .physical_device = device,
                .properties = properties,
                .features = features,
                .extensions = extensions,
            };
        }
    }

    return best_device;
}

fn containsExtension(extensions: []const vk.ExtensionProperties, extension: [*:0]const u8) bool {
    for (extensions) |props| {
        const name = props.extension_name[0 .. std.mem.indexOfScalar(u8, &props.extension_name, 0) orelse 256];

        if (std.mem.eql(u8, name, extension[0..std.mem.len(extension)]))
            return true;
    }
    return false;
}

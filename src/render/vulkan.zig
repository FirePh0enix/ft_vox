const std = @import("std");
const vk = @import("vulkan");
const sdl = @import("sdl");
const builtin = @import("builtin");
const vma = @import("vma");
const zm = @import("zmath");
const zigimg = @import("zigimg");
const dcimgui = @import("dcimgui");

const Allocator = std.mem.Allocator;
const VmaAllocator = vma.VmaAllocator;
const Camera = @import("../Camera.zig");
const World = @import("../voxel/World.zig");
const RenderFrame = @import("../voxel/RenderFrame.zig");
const Window = @import("Window.zig");
const Graph = @import("Graph.zig");

const Renderer = @import("Renderer.zig");
const Buffer = @import("Buffer.zig");
const Image = @import("Image.zig");
const Material = @import("Material.zig");

const rdr = Renderer.rdr;

const GetInstanceProcAddrFn = fn (instance: vk.Instance, name: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void;
const GetDeviceProcAddrFn = fn (device: vk.Device, name: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void;

const use_moltenvk = builtin.os.tag.isDarwin();

pub const VulkanRenderer = struct {
    allocator: Allocator,

    get_instance_proc_addr: *const GetInstanceProcAddrFn,

    instance: vk.InstanceProxy,
    device: vk.DeviceProxy,
    surface: vk.SurfaceKHR,
    physical_device: vk.PhysicalDevice,
    physical_device_properties: vk.PhysicalDeviceProperties,
    window: *sdl.SDL_Window,
    render_pass: vk.RenderPass,
    command_pool: vk.CommandPool,

    swapchain: vk.SwapchainKHR = .null_handle,
    swapchain_images: []vk.Image = &.{},
    swapchain_image_views: []vk.ImageView = &.{},
    swapchain_framebuffers: []vk.Framebuffer = &.{},
    swapchain_extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    depth_image: Image,

    surface_capabilities: vk.SurfaceCapabilitiesKHR,
    surface_format: vk.SurfaceFormatKHR,
    surface_present_modes: []const vk.PresentModeKHR,

    timestamp_query_pool: vk.QueryPool,
    primitives_query_pool: vk.QueryPool,

    graphics_queue: vk.QueueProxy,
    graphics_queue_mutex: std.Thread.Mutex = .{},
    graphics_queue_index: u32,

    compute_queue: vk.QueueProxy,
    compute_queue_mutex: std.Thread.Mutex = .{},
    compute_queue_index: u32,

    current_frame: usize = 0,
    command_buffers: [max_frames_in_flight]vk.CommandBufferProxy,
    image_available_semaphores: [max_frames_in_flight]vk.Semaphore,
    render_finished_semaphores: [max_frames_in_flight]vk.Semaphore,
    in_flight_fences: [max_frames_in_flight]vk.Fence,

    /// Buffer used when transfering data from buffer to buffer.
    transfer_command_buffer: vk.CommandBufferProxy,

    vma_allocator: VmaAllocator,

    features: Features,
    statistics: Renderer.Statistics = .{},

    imgui_context: *dcimgui.ImGuiContext,

    temp_noise_image: Image,
    temp_noise_texture_id: dcimgui.ImTextureID,
    hum_noise_image: Image,
    hum_noise_texture_id: dcimgui.ImTextureID,
    c_noise_image: Image,
    c_noise_texture_id: dcimgui.ImTextureID,
    e_noise_image: Image,
    e_noise_texture_id: dcimgui.ImTextureID,
    w_noise_image: Image,
    w_noise_texture_id: dcimgui.ImTextureID,
    pv_noise_image: Image,
    pv_noise_texture_id: dcimgui.ImTextureID,

    h_noise_image: Image,
    h_noise_texture_id: dcimgui.ImTextureID,
    biome_noise_image: Image,
    biome_noise_texture_id: dcimgui.ImTextureID,

    const max_frames_in_flight: usize = 2;

    pub const QueueInfo = struct {
        graphics_index: ?u32 = null,
        compute_index: ?u32 = null,
    };

    var instance_wrapper: vk.InstanceWrapper = undefined;
    var device_wrapper: vk.DeviceWrapper = undefined;

    pub const vtable: Renderer.VTable = .{
        .create_device = @ptrCast(&createDevice),
        .shutdown = @ptrCast(&shutdown),
        .create_swapchain = @ptrCast(&createSwapchain),
        .process_graph = @ptrCast(&processGraph),
        .create_buffer = @ptrCast(&createBuffer),
        .destroy_buffer = @ptrCast(&destroyBuffer),
        .create_image = @ptrCast(&createImage),
        .get_statistics = @ptrCast(&getStatistics),
    };

    pub fn create(allocator: Allocator) Allocator.Error!*VulkanRenderer {
        const driver = try allocator.create(VulkanRenderer);
        driver.allocator = allocator;

        return driver;
    }

    fn createDevice(
        self: *VulkanRenderer,
        window: *Window,
    ) Renderer.CreateDeviceError!void {
        self.createDeviceVk(window) catch |e| switch (e) {
            Allocator.Error.OutOfMemory => return Renderer.CreateDeviceError.OutOfMemory,
            else => return Renderer.CreateDeviceError.NoSuitableDevice,
        };
        self.graphics_queue_mutex = .{};
    }

    fn createDeviceVk(
        self: *VulkanRenderer,
        window: *Window,
    ) !void {
        const get_instance_proc_addr: *const GetInstanceProcAddrFn = @ptrCast(window.getVkGetInstanceProcAddr());
        const instance_extensions = window.getVkInstanceExtensions();

        self.get_instance_proc_addr = get_instance_proc_addr;

        const vkb = vk.BaseWrapper.load(get_instance_proc_addr);

        // Create a vulkan instance.
        const app_info: vk.ApplicationInfo = .{
            .api_version = @bitCast(vk.API_VERSION_1_2),
            .application_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            .engine_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
        };

        var validation_layers: std.ArrayList([*:0]const u8) = .init(self.allocator);
        defer validation_layers.deinit();

        var required_instance_extensions: std.ArrayList([*:0]const u8) = try .initCapacity(self.allocator, instance_extensions.len);
        defer required_instance_extensions.deinit();
        for (0..instance_extensions.len) |index| try required_instance_extensions.append(instance_extensions[index] orelse unreachable);

        const instance_info: vk.InstanceCreateInfo = .{
            .flags = if (builtin.target.os.tag == .macos) .{ .enumerate_portability_bit_khr = true } else .{},
            .p_application_info = &app_info,
            .enabled_layer_count = if (builtin.mode == .Debug) 1 else 0,
            .pp_enabled_layer_names = if (builtin.mode == .Debug) &.{"VK_LAYER_KHRONOS_validation"} else null,
            .enabled_extension_count = @intCast(required_instance_extensions.items.len),
            .pp_enabled_extension_names = required_instance_extensions.items.ptr,
        };

        const instance_handle = try vkb.createInstance(&instance_info, null);
        instance_wrapper = .load(instance_handle, get_instance_proc_addr);

        self.instance = vk.InstanceProxy.init(instance_handle, &instance_wrapper);
        errdefer self.instance.destroyInstance(null);

        // Create the surface
        self.surface = window.createVkSurface(self.instance.handle);
        errdefer self.instance.destroySurfaceKHR(self.surface, null);

        // Select the best physical device.
        const required_features: vk.PhysicalDeviceFeatures = .{};
        const optional_features: vk.PhysicalDeviceFeatures = .{};

        var required_extensions: std.ArrayList([*:0]const u8) = .init(self.allocator);
        defer required_extensions.deinit();

        try required_extensions.appendSlice(&.{
            vk.extensions.khr_swapchain.name.ptr,
        });

        if (use_moltenvk) try required_extensions.append(vk.extensions.khr_portability_subset.name.ptr);

        const optional_extensions: []const [*:0]const u8 = &.{
            vk.extensions.khr_deferred_host_operations.name.ptr,
            vk.extensions.khr_acceleration_structure.name.ptr,
            vk.extensions.khr_ray_tracing_pipeline.name.ptr,

            vk.extensions.ext_memory_budget.name.ptr,
        };

        // According to gpuinfo support for hostQueryReset this is 99.5%.
        // TODO: Probably better to set this features as optional since it is only used for debugging purpose.
        var host_query_reset_features: vk.PhysicalDeviceHostQueryResetFeatures = .{
            .host_query_reset = vk.TRUE,
        };

        if (use_moltenvk) {
            var portability_subset_features: vk.PhysicalDevicePortabilitySubsetFeaturesKHR = .{
                .image_view_format_swizzle = vk.TRUE,
            };
            host_query_reset_features.p_next = @ptrCast(&portability_subset_features);
        }

        const physical_devices = try self.instance.enumeratePhysicalDevicesAlloc(self.allocator);
        defer self.allocator.free(physical_devices);

        const physical_device_with_info = (try getBestDevice(self.allocator, self.instance, self.surface, physical_devices, required_features, optional_features, required_extensions.items, optional_extensions)) orelse return error.NoSuitableDevice;
        defer physical_device_with_info.deinit(self.allocator);

        self.physical_device = physical_device_with_info.physical_device;
        self.physical_device_properties = self.instance.getPhysicalDeviceProperties(self.physical_device);

        const features: Features = .{
            .ray_tracing = containsExtension(physical_device_with_info.extensions, vk.extensions.khr_ray_tracing_pipeline.name),
            .vk_memory_budget = containsExtension(physical_device_with_info.extensions, vk.extensions.ext_memory_budget.name),
        };

        std.log.info("GPU selected: {s}", .{self.physical_device_properties.device_name});

        inline for (@typeInfo(Features).@"struct".fields) |field| {
            if (@field(features, field.name)) std.log.info("Feature `{s}` is supported", .{field.name});
        }

        // Query surface capabilities.
        self.surface_capabilities = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface);

        self.surface_present_modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(self.physical_device, self.surface, self.allocator);
        errdefer self.allocator.free(self.surface_present_modes);

        self.surface_format = physical_device_with_info.surface_format;

        // Create the device.
        const queue_priorities: []const f32 = &.{1.0};

        const queue_infos: []const vk.DeviceQueueCreateInfo = &.{
            vk.DeviceQueueCreateInfo{
                .queue_family_index = physical_device_with_info.queue_info.graphics_index orelse return error.NoSuitableDevice,
                .queue_count = queue_priorities.len,
                .p_queue_priorities = queue_priorities.ptr,
            },
            vk.DeviceQueueCreateInfo{
                .queue_family_index = physical_device_with_info.queue_info.compute_index orelse return error.NoSuitableDevice,
                .queue_count = queue_priorities.len,
                .p_queue_priorities = queue_priorities.ptr,
            },
        };

        const device_extensions = combine_extensions: {
            var extensions = std.ArrayList([*:0]const u8).init(self.allocator);

            for (required_extensions.items) |ext| {
                try extensions.append(ext);
            }

            for (optional_extensions) |ext| {
                if (containsExtension(physical_device_with_info.extensions, ext)) try extensions.append(ext);
            }

            break :combine_extensions try extensions.toOwnedSlice();
        };
        defer self.allocator.free(device_extensions);

        const device_features = a: {
            const actual_features = physical_device_with_info.features;
            var device_features: vk.PhysicalDeviceFeatures = required_features;

            inline for (@typeInfo(vk.PhysicalDeviceFeatures).@"struct".fields) |field| {
                if (@field(actual_features, field.name) == vk.TRUE)
                    @field(device_features, field.name) = vk.TRUE;
            }

            break :a device_features;
        };

        const get_device_proc_addr: *const GetDeviceProcAddrFn = @ptrCast(instance_wrapper.dispatch.vkGetDeviceProcAddr);

        const device_handle = try self.instance.createDevice(self.physical_device, &vk.DeviceCreateInfo{
            .queue_create_info_count = @intCast(queue_infos.len),
            .p_queue_create_infos = queue_infos.ptr,
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = null,
            .enabled_extension_count = @intCast(device_extensions.len),
            .pp_enabled_extension_names = device_extensions.ptr,
            .p_enabled_features = &device_features,
            .p_next = @ptrCast(&host_query_reset_features),
        }, null);
        // errdefer instance_wrapper.dispatch.vkDestroyDevice(device_handle, null);
        device_wrapper = .load(device_handle, get_device_proc_addr);

        self.device = vk.DeviceProxy.init(device_handle, &device_wrapper);

        self.graphics_queue_index = physical_device_with_info.queue_info.graphics_index orelse unreachable;
        self.graphics_queue = vk.QueueProxy.init(self.device.getDeviceQueue(self.graphics_queue_index, 0), &device_wrapper);
        self.compute_queue_index = physical_device_with_info.queue_info.compute_index orelse unreachable;
        self.compute_queue = vk.QueueProxy.init(self.device.getDeviceQueue(self.compute_queue_index, 0), &device_wrapper);

        // Allocate command buffers
        self.command_pool = try self.device.createCommandPool(&vk.CommandPoolCreateInfo{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = physical_device_with_info.queue_info.graphics_index orelse 0,
        }, null);

        var command_buffer_handles: [max_frames_in_flight]vk.CommandBuffer = undefined;
        try self.device.allocateCommandBuffers(&vk.CommandBufferAllocateInfo{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = max_frames_in_flight,
        }, &command_buffer_handles);

        for (0..max_frames_in_flight) |index| self.command_buffers[index] = vk.CommandBufferProxy.init(command_buffer_handles[index], &device_wrapper);

        // Create synchronization primitives.
        for (0..max_frames_in_flight) |index| {
            self.image_available_semaphores[index] = try self.device.createSemaphore(&vk.SemaphoreCreateInfo{}, null);
            self.render_finished_semaphores[index] = try self.device.createSemaphore(&vk.SemaphoreCreateInfo{}, null);
            self.in_flight_fences[index] = try self.device.createFence(&vk.FenceCreateInfo{ .flags = .{ .signaled_bit = true } }, null);
        }

        // Create the VmaAllocator
        const vulkan_functions: vma.VmaVulkanFunctions = .{
            .vkGetInstanceProcAddr = @ptrCast(get_instance_proc_addr),
            .vkGetDeviceProcAddr = @ptrCast(get_device_proc_addr),
        };

        const allocator_info: vma.VmaAllocatorCreateInfo = .{
            .flags = if (features.vk_memory_budget) vma.VMA_ALLOCATOR_CREATE_EXT_MEMORY_BUDGET_BIT else 0,
            .vulkanApiVersion = @bitCast(vk.API_VERSION_1_2),
            .physicalDevice = @ptrFromInt(@as(usize, @intFromEnum(self.physical_device))),
            .device = @ptrFromInt(@as(usize, @intFromEnum(device_handle))),
            .instance = @ptrFromInt(@as(usize, @intFromEnum(instance_handle))),
            .pVulkanFunctions = @ptrCast(&vulkan_functions),
        };
        if (vma.vmaCreateAllocator(&allocator_info, &self.vma_allocator) != vma.VK_SUCCESS) return error.Internal;

        // Allocate a command buffer to transfer data between buffers.
        var transfer_command_buffer_handle: vk.CommandBuffer = undefined;
        try self.device.allocateCommandBuffers(&vk.CommandBufferAllocateInfo{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&transfer_command_buffer_handle));

        self.transfer_command_buffer = vk.CommandBufferProxy.init(transfer_command_buffer_handle, &device_wrapper);

        self.timestamp_query_pool = try self.device.createQueryPool(&vk.QueryPoolCreateInfo{
            .pipeline_statistics = .{},
            .query_type = .timestamp,
            .query_count = max_frames_in_flight * 2,
        }, null);

        self.primitives_query_pool = if (device_features.pipeline_statistics_query == 1)
            try self.device.createQueryPool(&vk.QueryPoolCreateInfo{
                .pipeline_statistics = .{ .input_assembly_primitives_bit = true },
                .query_type = .pipeline_statistics,
                .query_count = max_frames_in_flight,
            }, null)
        else
            .null_handle;

        for (0..max_frames_in_flight) |index| {
            self.device.resetQueryPool(self.timestamp_query_pool, @intCast(index * 2), 2);
            if (device_features.pipeline_statistics_query == 1) self.device.resetQueryPool(self.primitives_query_pool, @intCast(index), 1); // TODO: Check and activate the feature
        }

        // Create the color pass
        // TODO: Move render pass creation to the Graph.
        const color_ref: vk.AttachmentReference = .{
            .attachment = 0,
            .layout = .color_attachment_optimal,
        };

        const depth_ref: vk.AttachmentReference = .{
            .attachment = 1,
            .layout = .depth_stencil_attachment_optimal,
        };

        const subpass: vk.SubpassDescription = .{
            .pipeline_bind_point = .graphics,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_ref),
            .p_depth_stencil_attachment = @ptrCast(&depth_ref),
        };

        const attachments: []const vk.AttachmentDescription = &.{
            .{
                .format = self.surface_format.format,
                .samples = .{ .@"1_bit" = true },
                .load_op = .clear,
                .store_op = .store,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .initial_layout = .undefined,
                .final_layout = .present_src_khr,
            },
            .{
                .format = .d32_sfloat, // TODO: same as `Renderer.createDepthImage`
                .samples = .{ .@"1_bit" = true },
                .load_op = .clear,
                .store_op = .dont_care,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .initial_layout = .undefined,
                .final_layout = .depth_stencil_attachment_optimal,
            },
        };

        const dependency: vk.SubpassDependency = .{
            .src_subpass = vk.SUBPASS_EXTERNAL,
            .dst_subpass = 0,
            .src_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
            .dst_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
            .src_access_mask = .{},
            .dst_access_mask = .{ .color_attachment_write_bit = true, .depth_stencil_attachment_write_bit = true },
        };

        self.render_pass = try self.device.createRenderPass(&vk.RenderPassCreateInfo{
            .attachment_count = @intCast(attachments.len),
            .p_attachments = attachments.ptr,
            .subpass_count = 1,
            .p_subpasses = @ptrCast(&subpass),
            .dependency_count = 1,
            .p_dependencies = @ptrCast(&dependency),
        }, null);
        errdefer self.device.destroyRenderPass(self.render_pass, null);

        self.current_frame = 0;
        self.physical_device = physical_device_with_info.physical_device;
        self.swapchain = .null_handle;

        // Initialize DearImGui
        // TODO: Some of this should be in the main render pass creation.
        self.imgui_context = dcimgui.ImGui_CreateContext(null) orelse @panic("Failed to initialize DearImGui");

        var io: *dcimgui.ImGuiIO = dcimgui.ImGui_GetIO() orelse unreachable;
        io.ConfigFlags |= dcimgui.ImGuiConfigFlags_NavEnableKeyboard;
        _ = dcimgui.cImGui_ImplSDL3_InitForVulkan(@ptrCast(window.handle));

        var init_info: dcimgui.ImGui_ImplVulkan_InitInfo = .{
            .Instance = @ptrFromInt(@intFromEnum(self.instance.handle)),
            .PhysicalDevice = @ptrFromInt(@intFromEnum(self.physical_device)),
            .Device = @ptrFromInt(@intFromEnum(self.device.handle)),
            .QueueFamily = self.graphics_queue_index,
            .Queue = @ptrFromInt(@intFromEnum(self.graphics_queue.handle)),
            .RenderPass = @ptrFromInt(@intFromEnum(self.render_pass)),
            .MinImageCount = @intCast(max_frames_in_flight),
            .ImageCount = @intCast(max_frames_in_flight),
            .MSAASamples = dcimgui.VK_SAMPLE_COUNT_1_BIT,
        };

        init_info.DescriptorPool = @ptrFromInt(@intFromEnum(try self.device.createDescriptorPool(&vk.DescriptorPoolCreateInfo{
            .max_sets = 16,
            .pool_size_count = 1,
            .p_pool_sizes = @ptrCast(&vk.DescriptorPoolSize{ .type = .combined_image_sampler, .descriptor_count = 16 }),
        }, null)));

        const loader = struct {
            fn func(name: [*:0]const u8, _: ?*anyopaque) callconv(.c) dcimgui.PFN_vkVoidFunction {
                return rdr().asVk().get_instance_proc_addr(rdr().asVk().instance.handle, name);
            }
        }.func;

        _ = dcimgui.cImGui_ImplVulkan_LoadFunctions(@bitCast(vk.API_VERSION_1_2), @ptrCast(&loader));
        _ = dcimgui.cImGui_ImplVulkan_Init(&init_info);

        const noise_sampler = try self.device.createSampler(&vk.SamplerCreateInfo{
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mip_lod_bias = 0.0,
            .anisotropy_enable = vk.FALSE,
            .max_anisotropy = 0.0,
            .compare_enable = vk.FALSE,
            .compare_op = .equal,
            .min_lod = 0.0,
            .max_lod = 0.0,
            .border_color = .int_opaque_black,
            .unnormalized_coordinates = vk.FALSE,
        }, null);

        self.temp_noise_image = try self.createImage(22 * 16, 22 * 16, 1, .optimal, .b8g8r8a8_srgb, .{ .transfer_dst = true, .sampled = true }, .{ .color = true }, .identity);
        self.temp_noise_texture_id = @intFromPtr(dcimgui.cImGui_ImplVulkan_AddTexture(@ptrFromInt(@intFromEnum(noise_sampler)), @ptrFromInt(@intFromEnum(self.temp_noise_image.asVkConst().image_view)), dcimgui.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL));

        self.hum_noise_image = try self.createImage(22 * 16, 22 * 16, 1, .optimal, .r8_srgb, .{ .transfer_dst = true, .sampled = true }, .{ .color = true }, .grayscale);
        self.hum_noise_texture_id = @intFromPtr(dcimgui.cImGui_ImplVulkan_AddTexture(@ptrFromInt(@intFromEnum(noise_sampler)), @ptrFromInt(@intFromEnum(self.hum_noise_image.asVkConst().image_view)), dcimgui.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL));

        self.c_noise_image = try self.createImage(22 * 16, 22 * 16, 1, .optimal, .r8_srgb, .{ .transfer_dst = true, .sampled = true }, .{ .color = true }, .grayscale);
        self.c_noise_texture_id = @intFromPtr(dcimgui.cImGui_ImplVulkan_AddTexture(@ptrFromInt(@intFromEnum(noise_sampler)), @ptrFromInt(@intFromEnum(self.c_noise_image.asVkConst().image_view)), dcimgui.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL));

        self.e_noise_image = try self.createImage(22 * 16, 22 * 16, 1, .optimal, .r8_srgb, .{ .transfer_dst = true, .sampled = true }, .{ .color = true }, .grayscale);
        self.e_noise_texture_id = @intFromPtr(dcimgui.cImGui_ImplVulkan_AddTexture(@ptrFromInt(@intFromEnum(noise_sampler)), @ptrFromInt(@intFromEnum(self.e_noise_image.asVkConst().image_view)), dcimgui.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL));

        self.w_noise_image = try self.createImage(22 * 16, 22 * 16, 1, .optimal, .r8_srgb, .{ .transfer_dst = true, .sampled = true }, .{ .color = true }, .grayscale);
        self.w_noise_texture_id = @intFromPtr(dcimgui.cImGui_ImplVulkan_AddTexture(@ptrFromInt(@intFromEnum(noise_sampler)), @ptrFromInt(@intFromEnum(self.w_noise_image.asVkConst().image_view)), dcimgui.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL));

        self.pv_noise_image = try self.createImage(22 * 16, 22 * 16, 1, .optimal, .r8_srgb, .{ .transfer_dst = true, .sampled = true }, .{ .color = true }, .grayscale);
        self.pv_noise_texture_id = @intFromPtr(dcimgui.cImGui_ImplVulkan_AddTexture(@ptrFromInt(@intFromEnum(noise_sampler)), @ptrFromInt(@intFromEnum(self.pv_noise_image.asVkConst().image_view)), dcimgui.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL));

        self.h_noise_image = try self.createImage(22 * 16, 22 * 16, 1, .optimal, .r8_srgb, .{ .transfer_dst = true, .sampled = true }, .{ .color = true }, .grayscale);
        self.h_noise_texture_id = @intFromPtr(dcimgui.cImGui_ImplVulkan_AddTexture(@ptrFromInt(@intFromEnum(noise_sampler)), @ptrFromInt(@intFromEnum(self.h_noise_image.asVkConst().image_view)), dcimgui.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL));

        self.biome_noise_image = try self.createImage(22 * 16, 22 * 16, 1, .optimal, .b8g8r8a8_srgb, .{ .transfer_dst = true, .sampled = true }, .{ .color = true }, .identity);
        self.biome_noise_texture_id = @intFromPtr(dcimgui.cImGui_ImplVulkan_AddTexture(@ptrFromInt(@intFromEnum(noise_sampler)), @ptrFromInt(@intFromEnum(self.biome_noise_image.asVkConst().image_view)), dcimgui.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL));
    }

    fn shutdown(self: *VulkanRenderer) void {
        _ = self;
        // TODO
    }

    fn createSwapchain(
        self: *VulkanRenderer,
        window: *const Window,
        options: Renderer.SwapchainOptions,
    ) Renderer.CreateSwapchainError!void {
        self.createSwapchainVk(window, options) catch return error.Unknown;
    }

    fn createSwapchainVk(
        self: *VulkanRenderer,
        window: *const Window,
        options: Renderer.SwapchainOptions,
    ) !void {
        // Wait for the device to finish process frames before recreating the swapchain.
        try self.device.deviceWaitIdle();

        const size = window.size();

        // Per the Vulkan spec only FIFO is guaranteed to be supported, so we fallback to this if others are not.
        const surface_present_mode: vk.PresentModeKHR = switch (options.vsync) {
            .off => if (std.mem.containsAtLeastScalar(vk.PresentModeKHR, self.surface_present_modes, 1, .immediate_khr)) .immediate_khr else .fifo_khr,
            .smooth => if (std.mem.containsAtLeastScalar(vk.PresentModeKHR, self.surface_present_modes, 1, .fifo_relaxed_khr)) .fifo_relaxed_khr else .fifo_khr,
            .performance => if (std.mem.containsAtLeastScalar(vk.PresentModeKHR, self.surface_present_modes, 1, .mailbox_khr)) .mailbox_khr else .fifo_khr,
            .efficient => .fifo_khr,
        };

        const surface_extent: vk.Extent2D = .{
            .width = @intCast(@max(self.surface_capabilities.min_image_extent.width, @as(u32, @intCast(size.width)))),
            .height = @intCast(@max(self.surface_capabilities.min_image_extent.height, @as(u32, @intCast(size.height)))),
        };

        const image_count = if (self.surface_capabilities.max_image_count > 0 and self.surface_capabilities.min_image_count + 1 > self.surface_capabilities.max_image_count)
            self.surface_capabilities.max_image_count
        else
            self.surface_capabilities.min_image_count + 1;

        const swapchain = try self.device.createSwapchainKHR(&vk.SwapchainCreateInfoKHR{
            .surface = self.surface,
            .min_image_count = image_count,
            .image_format = self.surface_format.format,
            .image_color_space = self.surface_format.color_space,
            .image_extent = surface_extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = self.surface_capabilities.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = surface_present_mode,
            .clipped = vk.TRUE,
            .old_swapchain = self.swapchain,
        }, null);
        errdefer self.device.destroySwapchainKHR(swapchain, null);

        const swapchain_images = try self.device.getSwapchainImagesAllocKHR(swapchain, self.allocator);
        errdefer self.allocator.free(swapchain_images);

        const swapchain_image_views = try self.allocator.alloc(vk.ImageView, swapchain_images.len);
        errdefer self.allocator.free(swapchain_image_views);

        const swapchain_framebuffers = try self.allocator.alloc(vk.Framebuffer, swapchain_images.len);
        errdefer self.allocator.free(swapchain_framebuffers);

        const depth_image = try rdr().createDepthImage(surface_extent.width, surface_extent.height);
        errdefer depth_image.deinit();

        for (swapchain_images, 0..swapchain_images.len) |image, index| {
            const image_view = try self.device.createImageView(&vk.ImageViewCreateInfo{
                .image = image,
                .view_type = .@"2d",
                .format = self.surface_format.format,
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
            }, null);
            swapchain_image_views[index] = image_view;

            const attachments: []const vk.ImageView = &.{ image_view, depth_image.asVkConst().image_view };

            swapchain_framebuffers[index] = try self.device.createFramebuffer(&vk.FramebufferCreateInfo{
                .render_pass = self.render_pass,
                .attachment_count = @intCast(attachments.len),
                .p_attachments = attachments.ptr,
                .width = surface_extent.width,
                .height = surface_extent.height,
                .layers = 1,
            }, null);
        }

        self.destroySwapchain();

        self.swapchain = swapchain;
        self.swapchain_images = swapchain_images;
        self.swapchain_image_views = swapchain_image_views;
        self.swapchain_framebuffers = swapchain_framebuffers;
        self.swapchain_extent = surface_extent;
        self.depth_image = depth_image;
    }

    fn destroySwapchain(self: *const VulkanRenderer) void {
        if (self.swapchain != .null_handle) {
            for (self.swapchain_framebuffers) |framebuffer| {
                self.device.destroyFramebuffer(framebuffer, null);
            }

            for (self.swapchain_image_views) |image_view| {
                self.device.destroyImageView(image_view, null);
            }

            self.depth_image.deinit();

            self.allocator.free(self.swapchain_images);
            self.allocator.free(self.swapchain_image_views);
            self.allocator.free(self.swapchain_framebuffers);

            self.device.destroySwapchainKHR(self.swapchain, null);
        }
    }

    fn processGraph(
        self: *VulkanRenderer,
        graph: *const Graph,
    ) !void {
        self.processGraphVk(graph) catch unreachable; // TODO
    }

    fn processGraphVk(
        self: *VulkanRenderer,
        graph: *const Graph,
    ) !void {
        _ = try self.device.waitForFences(1, @ptrCast(&self.in_flight_fences[self.current_frame]), vk.TRUE, std.math.maxInt(u64));
        try self.device.resetFences(1, @ptrCast(&self.in_flight_fences[self.current_frame]));

        const image_index_result = try self.device.acquireNextImageKHR(self.swapchain, std.math.maxInt(u64), self.image_available_semaphores[self.current_frame], .null_handle);
        const image_index = image_index_result.image_index;

        const cb = self.command_buffers[self.current_frame];
        const fb = self.swapchain_framebuffers[image_index];

        self.graphics_queue_mutex.lock();
        defer self.graphics_queue_mutex.unlock();

        try cb.resetCommandBuffer(.{});
        try cb.beginCommandBuffer(&vk.CommandBufferBeginInfo{ .flags = .{ .one_time_submit_bit = true } });

        if (graph.main_render_pass) |rp| {
            try self.processRenderPass(cb, fb, rp);
        } else {
            unreachable;
        }

        try cb.endCommandBuffer();

        // Submit the command buffer
        const wait_semaphores: []const vk.Semaphore = &.{self.image_available_semaphores[self.current_frame]};
        const wait_stages: []const vk.PipelineStageFlags = &.{.{ .color_attachment_output_bit = true }};

        const signal_semaphores: []const vk.Semaphore = &.{self.render_finished_semaphores[self.current_frame]};

        try self.graphics_queue.submit(1, @ptrCast(&vk.SubmitInfo{
            .wait_semaphore_count = @intCast(wait_semaphores.len),
            .p_wait_semaphores = wait_semaphores.ptr,
            .p_wait_dst_stage_mask = wait_stages.ptr,

            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cb),

            .signal_semaphore_count = @intCast(signal_semaphores.len),
            .p_signal_semaphores = signal_semaphores.ptr,
        }), self.in_flight_fences[self.current_frame]);

        _ = try self.graphics_queue.presentKHR(&vk.PresentInfoKHR{
            .wait_semaphore_count = @intCast(signal_semaphores.len),
            .p_wait_semaphores = signal_semaphores.ptr,
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.swapchain),
            .p_image_indices = @ptrCast(&image_index),
        });

        self.current_frame = (self.current_frame + 1) % max_frames_in_flight;
    }

    fn processRenderPass(
        self: *VulkanRenderer,
        cb: vk.CommandBufferProxy,
        fb: vk.Framebuffer,
        pass: *Graph.RenderPass,
    ) !void {
        const clear_values: []const vk.ClearValue = &.{ // TODO one per attachements.
            .{ .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 0.0 } } },
            .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0.0 } },
        };

        cb.beginRenderPass(&vk.RenderPassBeginInfo{
            .render_pass = pass.vk_pass,
            .framebuffer = switch (pass.target.framebuffer) {
                .native => fb,
                .custom => |v| v,
            },
            .render_area = switch (pass.target.viewport) {
                .native => .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = self.swapchain_extent.width, .height = self.swapchain_extent.height } },
                .custom => |v| .{ .offset = .{ .x = @intCast(v.x), .y = @intCast(v.y) }, .extent = .{ .width = @intCast(v.width), .height = @intCast(v.height) } },
            },
            .clear_value_count = @intCast(clear_values.len),
            .p_clear_values = clear_values.ptr,
        }, .@"inline");

        for (pass.draw_calls.items) |*call| {
            cb.bindPipeline(.graphics, call.material.pipeline.pipeline);
            cb.bindDescriptorSets(.graphics, call.material.pipeline.layout, 0, 1, @ptrCast(&call.material.descriptor_set), 0, null);

            cb.bindIndexBuffer(call.mesh.index_buffer.asVkConst().buffer, 0, call.mesh.index_type);

            cb.bindVertexBuffers(0, 3, &.{
                call.mesh.vertex_buffer.asVkConst().buffer,
                call.mesh.normal_buffer.asVkConst().buffer,
                call.mesh.texture_buffer.asVkConst().buffer,
            }, &.{ 0, 0, 0 });

            if (call.instance_buffer) |ib| cb.bindVertexBuffers(3, 1, @ptrCast(&ib.asVkConst().buffer), &.{0});

            cb.setViewport(0, 1, @ptrCast(&vk.Viewport{
                .x = 0.0,
                .y = 0.0,
                .width = @floatFromInt(rdr().asVk().swapchain_extent.width), // TODO
                .height = @floatFromInt(rdr().asVk().swapchain_extent.height),
                .min_depth = 0.0,
                .max_depth = 1.0,
            }));

            cb.setScissor(0, 1, @ptrCast(&vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = rdr().asVk().swapchain_extent,
            }));

            const constants: Graph.PushConstants = .{
                .view_matrix = pass.view_matrix,
            };

            cb.pushConstants(call.material.pipeline.layout, .{ .vertex_bit = true }, 0, @sizeOf(Graph.PushConstants), @ptrCast(&constants));

            cb.drawIndexed(@intCast(call.mesh.count), @intCast(call.instance_count), 0, 0, 0);
        }

        // TODO: This sould be moved somewhere in the graph
        dcimgui.cImGui_ImplSDL3_NewFrame();
        dcimgui.cImGui_ImplVulkan_NewFrame();
        dcimgui.ImGui_NewFrame();

        const x = -pass.view_matrix[0][3];
        const z = -pass.view_matrix[2][3];

        const noise = @import("../world_gen.zig").getNoise(x, z);
        dcimgui.ImGui_Text(
            "t = %.2f | h = %.2f | c = %.2f | e = %.2f | d = ???\n",
            noise.temperature,
            noise.humidity,
            noise.continentalness,
            noise.erosion,
        );
        dcimgui.ImGui_Text(
            "w = %.2f | pv = %.2f | as = ??? | n = ???\n",
            noise.weirdness,
            noise.peaks_and_valleys,
        );

        dcimgui.ImGui_Text(
            "el = %d\n",
            @import("../world_gen.zig").getErosionLevel(noise.erosion),
        );

        dcimgui.ImGui_Text("Temperature | Humidity\n");
        dcimgui.ImGui_Image(self.temp_noise_texture_id, .{ .x = 100, .y = 100 });
        dcimgui.ImGui_SameLine();
        dcimgui.ImGui_Image(self.hum_noise_texture_id, .{ .x = 100, .y = 100 });

        dcimgui.ImGui_Text("Continentalness | Erosion | Weirdness | Peaks & Valleys\n");
        dcimgui.ImGui_Image(self.c_noise_texture_id, .{ .x = 100, .y = 100 });
        dcimgui.ImGui_SameLine();
        dcimgui.ImGui_Image(self.e_noise_texture_id, .{ .x = 100, .y = 100 });
        dcimgui.ImGui_SameLine();
        dcimgui.ImGui_Image(self.w_noise_texture_id, .{ .x = 100, .y = 100 });
        dcimgui.ImGui_SameLine();
        dcimgui.ImGui_Image(self.pv_noise_texture_id, .{ .x = 100, .y = 100 });

        dcimgui.ImGui_Text("Biome | Final heightmap\n");
        dcimgui.ImGui_Image(self.biome_noise_texture_id, .{ .x = 100, .y = 100 });
        dcimgui.ImGui_SameLine();
        dcimgui.ImGui_Image(self.h_noise_texture_id, .{ .x = 100, .y = 100 });

        dcimgui.ImGui_Render();
        dcimgui.cImGui_ImplVulkan_RenderDrawData(dcimgui.ImGui_GetDrawData(), @ptrFromInt(@intFromEnum(cb.handle)));

        cb.endRenderPass();
    }

    fn createBuffer(
        self: *VulkanRenderer,
        size: usize,
        usage: Renderer.BufferUsage,
        flags: Renderer.BufferUsageFlags,
    ) Renderer.CreateBufferError!Buffer {
        const alloc_info: vma.VmaAllocationCreateInfo = .{
            .usage = switch (usage) {
                .gpu_only => vma.VMA_MEMORY_USAGE_GPU_ONLY,
                .cpu_to_gpu => vma.VMA_MEMORY_USAGE_CPU_TO_GPU,
            },
        };

        const buffer_info: vk.BufferCreateInfo = .{
            .size = @intCast(size),
            .usage = .{
                .transfer_src_bit = flags.transfer_src,
                .transfer_dst_bit = flags.transfer_dst,
                .uniform_buffer_bit = flags.uniform_buffer,
                .index_buffer_bit = flags.index_buffer,
                .vertex_buffer_bit = flags.vertex_buffer,
            },
            .sharing_mode = .exclusive,
        };

        var vk_buffer: vk.Buffer = undefined;
        var allocation: vma.VmaAllocation = undefined;

        if (vma.vmaCreateBuffer(self.vma_allocator, @ptrCast(&buffer_info), @ptrCast(&alloc_info), @ptrCast(&vk_buffer), @ptrCast(&allocation), null) != vma.VK_SUCCESS)
            return Renderer.CreateBufferError.Fail;

        const buffer = try self.allocator.create(VulkanBuffer);
        buffer.* = .{
            .buffer = vk_buffer,
            .allocation = allocation,
            .size = size,
        };

        return .{
            .ptr = buffer,
            .vtable = &VulkanBuffer.vtable,
        };
    }

    fn destroyBuffer(
        self: *VulkanRenderer,
        buffer: Buffer,
    ) void {
        vma.vmaDestroyBuffer(self.vma_allocator, @ptrFromInt(@intFromEnum(buffer.asVkConst().buffer)), buffer.asVkConst().allocation);
    }

    fn createImage(
        self: *VulkanRenderer,
        width: usize,
        height: usize,
        layers: usize,
        tiling: Renderer.ImageTiling,
        format: Renderer.Format,
        usage: Renderer.ImageUsageFlags,
        aspect_mask: Renderer.ImageAspectFlags,
        mapping: Renderer.PixelMapping,
    ) Renderer.CreateImageError!Image {
        return self.createImageVk(width, height, layers, tiling, format, usage, aspect_mask, mapping) catch unreachable;
    }

    fn createImageVk(
        self: *VulkanRenderer,
        width: usize,
        height: usize,
        layers: usize,
        tiling: Renderer.ImageTiling,
        format: Renderer.Format,
        usage: Renderer.ImageUsageFlags,
        aspect_mask: Renderer.ImageAspectFlags,
        mapping: Renderer.PixelMapping,
    ) !Image {
        std.debug.assert(layers > 0);

        const image_info: vk.ImageCreateInfo = .{
            .image_type = .@"2d",
            .format = format.asVk(),
            .extent = .{ .width = @intCast(width), .height = @intCast(height), .depth = 1 },
            .mip_levels = 1,
            .array_layers = @intCast(layers),
            .samples = .{ .@"1_bit" = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
            .tiling = tiling.asVk(),
            .usage = usage.asVk(),
        };

        const alloc_info: vma.VmaAllocationCreateInfo = .{
            .usage = vma.VMA_MEMORY_USAGE_GPU_ONLY,
        };

        var vk_image: vk.Image = .null_handle;
        var alloc: vma.VmaAllocation = undefined;

        if (vma.vmaCreateImage(self.vma_allocator, @ptrCast(&image_info), @ptrCast(&alloc_info), @ptrCast(&vk_image), &alloc, null) != vma.VK_SUCCESS)
            return Renderer.CreateImageError.AllocationFailed;
        errdefer vma.vmaDestroyImage(self.vma_allocator, @ptrFromInt(@as(usize, @intFromEnum(vk_image))), alloc);

        const image_view = try self.device.createImageView(&vk.ImageViewCreateInfo{
            .image = vk_image,
            .view_type = if (layers == 1) .@"2d" else .@"2d_array",
            .format = format.asVk(),
            .components = switch (mapping) {
                .identity => .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .grayscale => .{ .r = .identity, .g = .r, .b = .r, .a = .one },
            },
            .subresource_range = .{
                .aspect_mask = aspect_mask.asVk(),
                .base_array_layer = 0,
                .layer_count = @intCast(layers),
                .base_mip_level = 0,
                .level_count = 1,
            },
        }, null);
        errdefer self.device.destroyImageView(image_view, null);

        const image = try self.allocator.create(VulkanImage);
        image.* = .{
            .width = width,
            .height = height,
            .layers = layers,

            .image = vk_image,
            .image_view = image_view,
            .allocation = alloc,
        };

        return .{
            .ptr = @ptrCast(image),
            .vtable = &VulkanImage.vtable,
        };
    }

    fn getStatistics(self: *const VulkanRenderer) Renderer.Statistics {
        var total_vram: usize = 0;

        var budgets: [vma.VK_MAX_MEMORY_HEAPS]vma.VmaBudget = @splat(.{});
        vma.vmaGetHeapBudgets(self.vma_allocator, &budgets);
        var index: usize = 0;
        while (index < @as(usize, @intCast(vma.VK_MAX_MEMORY_HEAPS))) : (index += 1) {
            total_vram += budgets[index].statistics.allocationBytes;
        }

        return .{
            .gpu_time = self.statistics.gpu_time,
            .primitives_drawn = self.statistics.primitives_drawn,
            .vram_used = total_vram,
        };
    }

    pub fn printDebugStats(self: *const VulkanRenderer) void {
        // Calculate the total GPU memory allocated by VMA.
        // TODO: Add other types of memory like swapchain images to the total.
        // TODO: Print also CPU memory, including vulkan objects using allocation callbacks.
        var total_bytes: usize = 0;

        var budgets: [vma.VK_MAX_MEMORY_HEAPS]vma.VmaBudget = @splat(.{});
        vma.vmaGetHeapBudgets(self.vma_allocator, &budgets);
        var index: usize = 0;
        while (index < @as(usize, @intCast(vma.VK_MAX_MEMORY_HEAPS))) : (index += 1) {
            total_bytes += budgets[index].statistics.allocationBytes;
        }

        std.debug.print("CPU Time   : prev = {d} ms\n", .{self.statistics.prv_cpu_time});
        std.debug.print("CPU Memory : {d:.2}\n\n", .{std.fmt.fmtIntSizeBin(@import("root").tracking_allocator.total_allocated_bytes)});
        std.debug.print("GPU Time   : prev = {d} ms, min = {d} ms, max = {d} ms\n", .{ self.statistics.prv_gpu_time, self.statistics.min_gpu_time, self.statistics.max_gpu_time });
        std.debug.print("GPU Memory : {d:.2}\n\n", .{std.fmt.fmtIntSizeBin(total_bytes)});
        std.debug.print("Primitives : {}\n", .{self.statistics.primitives});
    }

    pub fn createShaderModule(self: *const VulkanRenderer, spirv: [:0]align(4) const u8) vk.DeviceProxy.CreateShaderModuleError!vk.ShaderModule {
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
        queue_info: QueueInfo,
        surface_format: vk.SurfaceFormatKHR,

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

        for (required_extensions) |ext| {
            if (!containsExtension(extensions, ext))
                return 0;
        }

        for (optional_extensions) |ext| {
            if (!containsExtension(extensions, ext))
                score += 50;
        }

        return score;
    }

    fn getBestDevice(
        allocator: Allocator,
        instance: vk.InstanceProxy,
        surface: vk.SurfaceKHR,
        devices: []const vk.PhysicalDevice,
        required_features: vk.PhysicalDeviceFeatures,
        optional_features: vk.PhysicalDeviceFeatures,
        required_extensions: []const [*:0]const u8,
        optional_extensions: []const [*:0]const u8,
    ) !?DeviceWithInfo {
        var best_device: ?DeviceWithInfo = null;
        var max_score: i32 = 0;

        for (devices) |device| {
            const properties = instance.getPhysicalDeviceProperties(device);
            const features = instance.getPhysicalDeviceFeatures(device);

            const extensions = try instance.enumerateDeviceExtensionPropertiesAlloc(device, null, allocator);
            errdefer allocator.free(extensions);

            const queue_properties = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(device, allocator);
            errdefer allocator.free(queue_properties);

            const surface_formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(device, surface, allocator);
            defer allocator.free(surface_formats);

            const score = calculateDeviceScore(properties, features, required_features, optional_features, extensions, required_extensions, optional_extensions);
            const queue_info = findQueues(instance, device, surface, queue_properties) catch {
                allocator.free(extensions);
                allocator.free(queue_properties);
                continue;
            };
            const surface_format = chooseSurfaceFormat(&.{
                vk.SurfaceFormatKHR{ .format = .b8g8r8a8_srgb, .color_space = .srgb_nonlinear_khr },
                vk.SurfaceFormatKHR{ .format = .r8g8b8a8_srgb, .color_space = .srgb_nonlinear_khr },
            }, surface_formats);

            if (score > max_score and surface_format != null) {
                if (best_device) |bd| bd.deinit(allocator);

                max_score = score;

                best_device = DeviceWithInfo{
                    .physical_device = device,
                    .properties = properties,
                    .features = features,
                    .extensions = extensions,
                    .queue_info = queue_info,
                    .surface_format = surface_format orelse unreachable,
                };
            } else {
                allocator.free(extensions);
                allocator.free(queue_properties);
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

    fn chooseSurfaceFormat(wanted_formats: []const vk.SurfaceFormatKHR, supported_formats: []const vk.SurfaceFormatKHR) ?vk.SurfaceFormatKHR {
        for (wanted_formats) |fmt| {
            for (supported_formats) |fmt2| {
                if (fmt.color_space == fmt2.color_space and fmt.format == fmt.format) return fmt;
            }
        }
        return null;
    }

    fn findQueues(
        instance: vk.InstanceProxy,
        device: vk.PhysicalDevice,
        surface: vk.SurfaceKHR,
        properties: []const vk.QueueFamilyProperties,
    ) !QueueInfo {
        var queue: QueueInfo = .{};

        for (properties, 0..properties.len) |queue_properties, index| {
            if (queue_properties.queue_flags.graphics_bit and queue.graphics_index == null) {
                queue.graphics_index = @intCast(index);

                // All graphics queue supports presentation, some compute queues could also support it.
                const present_support = try instance.getPhysicalDeviceSurfaceSupportKHR(device, @intCast(index), surface) != 0;

                if (!present_support) return error.NoGraphicsQueue;
            }
        }

        for (properties, 0..properties.len) |queue_properties, index| {
            // On some device queues can be both graphics and compute this will make sure we use two different queues in that case.
            if (queue_properties.queue_flags.compute_bit and queue.compute_index == null and queue.graphics_index != null and @as(u32, @intCast(index)) != queue.graphics_index) {
                queue.compute_index = @intCast(index);
            }
        }

        return queue;
    }
};

pub const Features = struct {
    ray_tracing: bool = false,
    vk_memory_budget: bool = false,
};

// pub const Statistics = struct {
//     prv_gpu_time: f32 = 0.0,
//     acc_gpu_time: f32 = 0.0,
//     min_gpu_time: f32 = std.math.inf(f32),
//     max_gpu_time: f32 = 0.0,

//     prv_cpu_time: f32 = 0.0,

//     frames_recorded: usize = 0,

//     /// Number of primitives drawn during last frame.
//     primitives: u64 = 0,

//     pub fn putGpuTimeValue(self: *Statistics, value: f32) void {
//         self.prv_gpu_time = value;
//         if (value > self.max_gpu_time) self.max_gpu_time = value;
//         if (value < self.min_gpu_time) self.min_gpu_time = value;
//         self.acc_gpu_time += value;
//         self.frames_recorded += 1;
//     }

//     pub fn getAverageGpuTime(self: *const Statistics) f32 {
//         if (self.frames_recorded > 0) return self.acc_gpu_time / @as(f32, @floatFromInt(self.frames_recorded));
//         return 0;
//     }
// };

pub const VulkanBuffer = struct {
    const Self = @This();

    buffer: vk.Buffer,
    allocation: vma.VmaAllocation,
    size: usize,

    pub const vtable: Buffer.VTable = .{
        .update = @ptrCast(&update),
        .destroy = @ptrCast(&destroy),
    };

    pub fn destroy(self: *const Self) void {
        vma.vmaDestroyBuffer(rdr().asVk().vma_allocator, @ptrFromInt(@intFromEnum(self.buffer)), self.allocation);
    }

    pub fn update(self: *Self, data: []const u8) !void {
        var staging_buffer = try rdr().createBuffer(self.size, .cpu_to_gpu, .{ .transfer_src = true });
        defer staging_buffer.deinit();

        {
            const map_data = try staging_buffer.asVk().map();
            defer staging_buffer.asVk().unmap();

            @memcpy(map_data[0..data.len], data);
        }

        // Record the command buffer
        rdr().asVk().graphics_queue_mutex.lock();
        defer rdr().asVk().graphics_queue_mutex.unlock();

        try rdr().asVk().transfer_command_buffer.resetCommandBuffer(.{});
        try rdr().asVk().transfer_command_buffer.beginCommandBuffer(&vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
        });

        const regions: []const vk.BufferCopy = &.{
            vk.BufferCopy{ .src_offset = 0, .dst_offset = 0, .size = self.size },
        };

        rdr().asVk().transfer_command_buffer.copyBuffer(staging_buffer.asVk().buffer, self.buffer, @intCast(regions.len), regions.ptr);
        try rdr().asVk().transfer_command_buffer.endCommandBuffer();

        const submit_info: vk.SubmitInfo = .{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&rdr().asVk().transfer_command_buffer),
        };

        try rdr().asVk().graphics_queue.submit(1, @ptrCast(&submit_info), .null_handle);
        try rdr().asVk().graphics_queue.waitIdle();
    }

    pub fn deinit(self: *const Self) void {
        vma.vmaDestroyBuffer(rdr().asVk().vma_allocator, @ptrFromInt(@as(usize, @intFromEnum(self.buffer))), self.allocation);
    }

    pub fn map(self: *const Self) ![]u8 {
        var data: ?*anyopaque = null;

        if (vma.vmaMapMemory(rdr().asVk().vma_allocator, self.allocation, &data) != vma.VK_SUCCESS)
            return error.Internal;

        if (data) |ptr| {
            return @as([*]u8, @ptrCast(ptr))[0..self.size];
        } else {
            return error.Internal;
        }
    }

    pub fn unmap(self: *const Self) void {
        vma.vmaUnmapMemory(rdr().asVk().vma_allocator, self.allocation);
    }
};

pub const VulkanImage = struct {
    const Self = @This();

    width: usize,
    height: usize,
    layers: usize,

    image: vk.Image,
    image_view: vk.ImageView,
    allocation: vma.VmaAllocation,

    pub const vtable: Image.VTable = .{
        .destroy = @ptrCast(&destroy),
        .update = @ptrCast(&update),
    };

    pub fn destroy(self: *const Self) void {
        vma.vmaDestroyImage(rdr().asVk().vma_allocator, @ptrFromInt(@intFromEnum(self.image)), self.allocation);
        rdr().asVk().device.destroyImageView(self.image_view, null);
    }

    pub fn getMissingPixels() [16 * 16 * 4]u8 {
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

    pub fn update(
        self: *Self,
        layer: usize,
        data: []const u8,
    ) !void {
        var staging_buffer = try rdr().createBuffer(data.len, .cpu_to_gpu, .{ .transfer_src = true });
        defer staging_buffer.deinit();

        {
            const map_data = try staging_buffer.asVk().map();
            defer staging_buffer.asVk().unmap();

            const data_bytes: []const u8 = @as([*]const u8, @ptrCast(data.ptr))[0..data.len];
            @memcpy(map_data, data_bytes);
        }

        // Record the command buffer
        rdr().asVk().graphics_queue_mutex.lock();
        defer rdr().asVk().graphics_queue_mutex.unlock();

        try rdr().asVk().transfer_command_buffer.resetCommandBuffer(.{});
        try rdr().asVk().transfer_command_buffer.beginCommandBuffer(&vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
        });

        const regions: []const vk.BufferImageCopy = &.{
            vk.BufferImageCopy{
                .buffer_offset = 0,
                .buffer_row_length = 0,
                .buffer_image_height = 0,
                .image_subresource = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_array_layer = @intCast(layer),
                    .layer_count = 1,
                    .mip_level = 0,
                },
                .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                .image_extent = .{ .width = @intCast(self.width), .height = @intCast(self.height), .depth = 1 },
            },
        };

        rdr().asVk().transfer_command_buffer.copyBufferToImage(staging_buffer.asVkConst().buffer, self.image, .transfer_dst_optimal, @intCast(regions.len), regions.ptr);
        try rdr().asVk().transfer_command_buffer.endCommandBuffer();

        try rdr().asVk().graphics_queue.submit(1, @ptrCast(&vk.SubmitInfo{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&rdr().asVk().transfer_command_buffer),
        }), .null_handle);
        try rdr().asVk().graphics_queue.waitIdle();
    }

    pub fn transferLayout(
        self: *const Self,
        old_layout: vk.ImageLayout,
        new_layout: vk.ImageLayout,
        aspect_mask: vk.ImageAspectFlags,
    ) !void {
        const command_buffer = rdr().asVk().transfer_command_buffer;

        rdr().asVk().graphics_queue_mutex.lock();
        defer rdr().asVk().graphics_queue_mutex.unlock();

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
                .layer_count = @intCast(self.layers),
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
            std.log.err("old = {}, new = {}\n", .{ old_layout, new_layout });
            return error.UnsupportedLayouts;
        }

        command_buffer.pipelineBarrier(src_stage_mask, dst_stage_mask, .{}, 0, null, 0, null, 1, @ptrCast(&barrier));
        try command_buffer.endCommandBuffer();
        try rdr().asVk().graphics_queue.submit(1, &.{vk.SubmitInfo{ .command_buffer_count = 1, .p_command_buffers = @ptrCast(&command_buffer) }}, .null_handle);
        try rdr().asVk().graphics_queue.waitIdle();
    }
};

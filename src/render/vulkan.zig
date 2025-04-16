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
const Window = @import("Window.zig");
const Graph = @import("Graph.zig");

const Renderer = @import("Renderer.zig");
const RID = Renderer.RID;
const Image = @import("Image.zig");
const Material = @import("Material.zig");
const ShaderModel = @import("ShaderModel.zig");

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
    command_pool: vk.CommandPool,

    swapchain: vk.SwapchainKHR = .null_handle,
    swapchain_images: []RID = &.{},
    swapchain_framebuffers: []RID = &.{},
    swapchain_extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    depth_image: RID,

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

    output_render_pass: RID,

    /// Buffer used when transfering data from buffer to buffer.
    transfer_command_buffer: vk.CommandBufferProxy,

    vma_allocator: VmaAllocator,

    features: Features,
    statistics: Renderer.Statistics = .{},

    imgui_context: *dcimgui.ImGuiContext,
    imgui_sampler: vk.Sampler,
    imgui_descriptor_pool: vk.DescriptorPool,

    const max_frames_in_flight: usize = 2;

    pub const QueueInfo = struct {
        graphics_index: ?u32 = null,
        compute_index: ?u32 = null,
    };

    var instance_wrapper: vk.InstanceWrapper = undefined;
    var device_wrapper: vk.DeviceWrapper = undefined;

    pub const vtable: Renderer.VTable = .{
        .create_device = @ptrCast(&createDevice),
        .process_graph = @ptrCast(&processGraph),
        .get_size = @ptrCast(&getSize),
        .get_statistics = @ptrCast(&getStatistics),

        .destroy = @ptrCast(&destroy),
        .configure = @ptrCast(&configure),
        .get_output_render_pass = @ptrCast(&getOutputRenderPass),

        .imgui_init = @ptrCast(&imguiInit),
        .imgui_add_texture = @ptrCast(&imguiAddTexture),

        .free_rid = @ptrCast(&freeRid),

        .buffer_create = @ptrCast(&bufferCreate),
        .buffer_update = @ptrCast(&bufferUpdate),
        .buffer_map = @ptrCast(&bufferMap),
        .buffer_unmap = @ptrCast(&bufferUnmap),

        .image_create = @ptrCast(&imageCreate),
        .image_update = @ptrCast(&imageUpdate),
        .image_set_layout = @ptrCast(&imageSetLayout),

        .pipeline_create_graphics = @ptrCast(&pipelineCreateGraphics),

        .renderpass_create = @ptrCast(&renderPassCreate),

        .framebuffer_create = @ptrCast(&framebufferCreate),
    };

    pub fn create(allocator: Allocator) Allocator.Error!*VulkanRenderer {
        const driver = try createWithDefault(VulkanRenderer, allocator);
        driver.allocator = allocator;

        return driver;
    }

    pub fn createDevice(self: *VulkanRenderer, window: *Window) Renderer.CreateDeviceError!void {
        self.createDeviceVk(window) catch |e| switch (e) {
            Allocator.Error.OutOfMemory => return Renderer.CreateDeviceError.OutOfMemory,
            else => return Renderer.CreateDeviceError.NoSuitableDevice,
        };
    }

    fn createDeviceVk(self: *VulkanRenderer, window: *Window) !void {
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
        if (vma.vmaCreateAllocator(&vma.VmaAllocatorCreateInfo{
            .flags = if (features.vk_memory_budget) vma.VMA_ALLOCATOR_CREATE_EXT_MEMORY_BUDGET_BIT else 0,
            .vulkanApiVersion = @bitCast(vk.API_VERSION_1_2),
            .physicalDevice = @ptrFromInt(@as(usize, @intFromEnum(self.physical_device))),
            .device = @ptrFromInt(@as(usize, @intFromEnum(device_handle))),
            .instance = @ptrFromInt(@as(usize, @intFromEnum(instance_handle))),
            .pVulkanFunctions = @ptrCast(&vma.VmaVulkanFunctions{
                .vkGetInstanceProcAddr = @ptrCast(get_instance_proc_addr),
                .vkGetDeviceProcAddr = @ptrCast(get_device_proc_addr),
            }),
        }, &self.vma_allocator) != vma.VK_SUCCESS) return error.Internal;

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

        self.current_frame = 0;
        self.physical_device = physical_device_with_info.physical_device;
        self.swapchain = .null_handle;

        // Create a renderpass attached
        self.output_render_pass = try rdr().renderPassCreate(.{});
    }

    pub fn processGraph(self: *VulkanRenderer, graph: *const Graph) !void {
        self.processGraphVk(graph) catch unreachable; // TODO
    }

    fn processGraphVk(self: *VulkanRenderer, graph: *const Graph) !void {
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

    fn processRenderPass(self: *VulkanRenderer, cb: vk.CommandBufferProxy, fb: RID, pass: *Graph.RenderPass) !void {
        const clear_values: []const vk.ClearValue = &.{ // TODO one per attachements.
            .{ .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 0.0 } } },
            .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0.0 } },
        };

        const framebuffer = fb.as(VulkanFramebuffer);
        const render_pass = pass.render_pass.as(VulkanRenderPass);

        cb.beginRenderPass(&vk.RenderPassBeginInfo{
            .render_pass = render_pass.render_pass,
            .framebuffer = switch (pass.target.framebuffer) {
                .native => framebuffer.framebuffer,
                .custom => |v| v.as(VulkanFramebuffer).framebuffer,
            },
            .render_area = switch (pass.target.viewport) {
                .native => .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = self.swapchain_extent.width, .height = self.swapchain_extent.height } },
                .custom => |v| .{ .offset = .{ .x = @intCast(v.x), .y = @intCast(v.y) }, .extent = .{ .width = @intCast(v.width), .height = @intCast(v.height) } },
            },
            .clear_value_count = @intCast(clear_values.len),
            .p_clear_values = clear_values.ptr,
        }, .@"inline");

        for (pass.draw_calls.items) |*call| {
            const pipeline = call.material.pipeline.as(VulkanPipeline);

            cb.bindPipeline(.graphics, pipeline.pipeline);
            cb.bindDescriptorSets(.graphics, pipeline.layout, 0, 1, @ptrCast(&call.material.descriptor_set), 0, null);

            cb.bindIndexBuffer(call.mesh.index_buffer.as(VulkanBuffer).buffer, 0, call.mesh.index_type.asVk());

            cb.bindVertexBuffers(0, 3, &.{
                call.mesh.vertex_buffer.as(VulkanBuffer).buffer,
                call.mesh.normal_buffer.as(VulkanBuffer).buffer,
                call.mesh.texture_buffer.as(VulkanBuffer).buffer,
            }, &.{ 0, 0, 0 });

            if (call.instance_buffer) |ib| cb.bindVertexBuffers(3, 1, @ptrCast(&ib.as(VulkanBuffer).buffer), &.{0});

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

            cb.pushConstants(pipeline.layout, .{ .vertex_bit = true }, 0, @sizeOf(Graph.PushConstants), @ptrCast(&constants));

            cb.drawIndexed(@intCast(call.mesh.count), @intCast(call.instance_count), 0, 0, 0);
        }

        for (pass.hooks.items) |hook| {
            hook(pass);
        }

        if (pass.imgui_hooks.items.len > 0) {
            dcimgui.cImGui_ImplSDL3_NewFrame();
            dcimgui.cImGui_ImplVulkan_NewFrame();
            dcimgui.ImGui_NewFrame();

            for (pass.imgui_hooks.items) |hook| {
                hook(pass);
            }

            dcimgui.ImGui_Render();
            dcimgui.cImGui_ImplVulkan_RenderDrawData(dcimgui.ImGui_GetDrawData(), @ptrFromInt(@intFromEnum(cb.handle)));
        }

        cb.endRenderPass();
    }

    pub fn getSize(self: *const VulkanRenderer) Renderer.Size {
        return .{ .width = @intCast(self.swapchain_extent.width), .height = @intCast(self.swapchain_extent.height) };
    }

    pub fn getStatistics(self: *const VulkanRenderer) Renderer.Statistics {
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

    pub fn destroy(self: *const VulkanRenderer) void {
        _ = self;
        // TODO
    }

    fn destroySwapchain(self: *VulkanRenderer) void {
        if (self.swapchain != .null_handle) {
            for (self.swapchain_framebuffers) |framebuffer_rid| {
                self.freeRid(framebuffer_rid);
            }

            for (self.swapchain_images) |image_rid| {
                // self.freeRid(image_rid); FIXME
                _ = image_rid;
            }

            self.freeRid(self.depth_image);

            self.allocator.free(self.swapchain_images);
            self.allocator.free(self.swapchain_framebuffers);

            self.device.destroySwapchainKHR(self.swapchain, null);
        }
    }

    pub fn configure(self: *VulkanRenderer, options: Renderer.ConfigureOptions) Renderer.ConfigureError!void {
        // Wait for the device to finish process frames before recreating the swapchain.
        self.device.deviceWaitIdle() catch return error.Failed;

        // Per the Vulkan spec only FIFO is guaranteed to be supported, so we fallback to this if others are not.
        const surface_present_mode: vk.PresentModeKHR = switch (options.vsync) {
            .off => if (std.mem.containsAtLeastScalar(vk.PresentModeKHR, self.surface_present_modes, 1, .immediate_khr)) .immediate_khr else .fifo_khr,
            .smooth => if (std.mem.containsAtLeastScalar(vk.PresentModeKHR, self.surface_present_modes, 1, .fifo_relaxed_khr)) .fifo_relaxed_khr else .fifo_khr,
            .performance => if (std.mem.containsAtLeastScalar(vk.PresentModeKHR, self.surface_present_modes, 1, .mailbox_khr)) .mailbox_khr else .fifo_khr,
            .efficient => .fifo_khr,
        };

        const surface_extent: vk.Extent2D = .{
            .width = @intCast(@max(self.surface_capabilities.min_image_extent.width, @as(u32, @intCast(options.width)))),
            .height = @intCast(@max(self.surface_capabilities.min_image_extent.height, @as(u32, @intCast(options.height)))),
        };

        const image_count = if (self.surface_capabilities.max_image_count > 0 and self.surface_capabilities.min_image_count + 1 > self.surface_capabilities.max_image_count)
            self.surface_capabilities.max_image_count
        else
            self.surface_capabilities.min_image_count + 1;

        const swapchain = self.device.createSwapchainKHR(&vk.SwapchainCreateInfoKHR{
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
        }, null) catch return error.Failed;
        errdefer self.device.destroySwapchainKHR(swapchain, null);

        const depth_image_rid = try rdr().imageCreate(.{ .width = @intCast(surface_extent.width), .height = @intCast(surface_extent.height), .format = .d32_sfloat, .aspect_mask = .{ .depth = true }, .usage = .{ .depth_stencil_attachment = true } });
        errdefer self.freeRid(depth_image_rid);

        const swapchain_images = self.device.getSwapchainImagesAllocKHR(swapchain, self.allocator) catch return error.Failed;
        defer self.allocator.free(swapchain_images);

        const images = try self.allocator.alloc(RID, swapchain_images.len);
        for (swapchain_images, 0..swapchain_images.len) |vk_image, index| images[index] = try self.imageCreateFromVkHandle(vk_image, self.surface_format.format);

        const framebuffers = try self.allocator.alloc(RID, swapchain_images.len);
        for (images, 0..swapchain_images.len) |image, index|
            framebuffers[index] = try self.framebufferCreate(.{
                .attachments = &.{ image, depth_image_rid },
                .render_pass = self.output_render_pass,
                .width = @intCast(surface_extent.width),
                .height = @intCast(surface_extent.height),
            });

        self.destroySwapchain();

        self.swapchain = swapchain;
        self.swapchain_images = images;
        self.swapchain_framebuffers = framebuffers;
        self.swapchain_extent = surface_extent;
        self.depth_image = depth_image_rid;
    }

    pub fn getOutputRenderPass(self: *VulkanRenderer) RID {
        return self.output_render_pass;
    }

    pub fn imguiInit(self: *VulkanRenderer, window: *const Window, render_pass_rid: RID) Renderer.ImGuiInitError!void {
        self.imgui_context = dcimgui.ImGui_CreateContext(null) orelse @panic("Failed to initialize DearImGui");

        var io: *dcimgui.ImGuiIO = dcimgui.ImGui_GetIO() orelse unreachable;
        io.ConfigFlags |= dcimgui.ImGuiConfigFlags_NavEnableKeyboard;
        _ = dcimgui.cImGui_ImplSDL3_InitForVulkan(@ptrCast(window.handle));

        self.imgui_descriptor_pool = self.device.createDescriptorPool(&vk.DescriptorPoolCreateInfo{
            .max_sets = 16,
            .pool_size_count = 1,
            .p_pool_sizes = @ptrCast(&vk.DescriptorPoolSize{ .type = .combined_image_sampler, .descriptor_count = 16 }),
        }, null) catch return error.Failed;

        var init_info: dcimgui.ImGui_ImplVulkan_InitInfo = .{
            .Instance = @ptrFromInt(@intFromEnum(self.instance.handle)),
            .PhysicalDevice = @ptrFromInt(@intFromEnum(self.physical_device)),
            .Device = @ptrFromInt(@intFromEnum(self.device.handle)),
            .QueueFamily = self.graphics_queue_index,
            .Queue = @ptrFromInt(@intFromEnum(self.graphics_queue.handle)),
            .RenderPass = @ptrFromInt(@intFromEnum(render_pass_rid.as(VulkanRenderPass).render_pass)),
            .MinImageCount = @intCast(max_frames_in_flight),
            .ImageCount = @intCast(max_frames_in_flight),
            .MSAASamples = dcimgui.VK_SAMPLE_COUNT_1_BIT,
            .DescriptorPool = @ptrFromInt(@intFromEnum(self.imgui_descriptor_pool)),
        };

        const loader = struct {
            fn func(name: [*:0]const u8, _: ?*anyopaque) callconv(.c) dcimgui.PFN_vkVoidFunction {
                return rdr().asVk().get_instance_proc_addr(rdr().asVk().instance.handle, name);
            }
        }.func;

        _ = dcimgui.cImGui_ImplVulkan_LoadFunctions(@bitCast(vk.API_VERSION_1_2), @ptrCast(&loader));
        _ = dcimgui.cImGui_ImplVulkan_Init(&init_info);

        self.imgui_sampler = self.device.createSampler(&vk.SamplerCreateInfo{
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
        }, null) catch return error.Failed;
    }

    pub fn imguiAddTexture(self: *VulkanRenderer, image_rid: RID) Renderer.ImGuiAddTextureError!c_ulonglong {
        return @intFromPtr(dcimgui.cImGui_ImplVulkan_AddTexture(@ptrFromInt(@intFromEnum(self.imgui_sampler)), @ptrFromInt(@intFromEnum(image_rid.as(VulkanImage).view)), dcimgui.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL));
    }

    //
    // Common
    //

    pub fn freeRid(self: *VulkanRenderer, rid: RID) void {
        if (rid.tryAs(VulkanBuffer)) |buffer| {
            vma.vmaDestroyBuffer(self.vma_allocator, @ptrFromInt(@intFromEnum(buffer.buffer)), buffer.allocation);
        } else if (rid.tryAs(VulkanImage)) |image| {
            self.device.destroyImageView(image.view, null);
            vma.vmaDestroyImage(self.vma_allocator, @ptrFromInt(@intFromEnum(image.image)), image.allocation);
        } else if (rid.tryAs(VulkanFramebuffer)) |framebuffer| {
            self.device.destroyFramebuffer(framebuffer.framebuffer, null);
        } else if (rid.tryAs(VulkanRenderPass)) |render_pass| {
            self.device.destroyRenderPass(render_pass.render_pass, null);
        } else {
            unreachable;
        }
    }

    //
    // Buffer
    //

    pub fn bufferCreate(self: *const VulkanRenderer, options: Renderer.BufferOptions) Renderer.BufferCreateError!RID {
        const alloc_info: vma.VmaAllocationCreateInfo = .{
            .usage = switch (options.alloc_usage) {
                .gpu_only => vma.VMA_MEMORY_USAGE_GPU_ONLY,
                .cpu_to_gpu => vma.VMA_MEMORY_USAGE_CPU_TO_GPU,
            },
        };

        const buffer_info: vk.BufferCreateInfo = .{
            .size = @intCast(options.size),
            .usage = options.usage.asVk(),
            .sharing_mode = .exclusive,
        };

        var buffer: vk.Buffer = undefined;
        var allocation: vma.VmaAllocation = undefined;

        if (vma.vmaCreateBuffer(self.vma_allocator, @ptrCast(&buffer_info), @ptrCast(&alloc_info), @ptrCast(&buffer), @ptrCast(&allocation), null) != vma.VK_SUCCESS) {
            return error.Failed;
        }

        return .{ .inner = @intFromPtr(try createWithInit(VulkanBuffer, self.allocator, .{
            .size = options.size,
            .buffer = buffer,
            .allocation = allocation,
        })) };
    }

    pub fn bufferDestroy(self: *VulkanRenderer, buffer_rid: RID) void {
        const buffer = buffer_rid.as(VulkanBuffer);
        vma.vmaDestroyBuffer(self.vma_allocator, @ptrFromInt(@intFromEnum(buffer.buffer)), buffer.allocation);
    }

    pub fn bufferUpdate(self: *VulkanRenderer, buffer_rid: RID, s: []const u8, offset: usize) Renderer.BufferUpdateError!void {
        const buffer = buffer_rid.as(VulkanBuffer);

        std.debug.assert(s.len <= buffer.size - offset);

        var staging_buffer_rid = try self.bufferCreate(.{ .size = s.len, .usage = .{ .transfer_src = true }, .alloc_usage = .cpu_to_gpu });
        const staging_buffer = staging_buffer_rid.as(VulkanBuffer);
        defer self.bufferDestroy(staging_buffer_rid);

        {
            const map_data = try self.bufferMap(staging_buffer_rid);
            defer self.bufferUnmap(staging_buffer_rid);

            @memcpy(map_data[0..s.len], s);
        }

        // Record the command buffer
        self.graphics_queue_mutex.lock();
        defer self.graphics_queue_mutex.unlock();

        self.transfer_command_buffer.resetCommandBuffer(.{}) catch return error.Failed;
        self.transfer_command_buffer.beginCommandBuffer(&vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
        }) catch return error.Failed;

        const regions: []const vk.BufferCopy = &.{
            vk.BufferCopy{ .src_offset = 0, .dst_offset = @intCast(offset), .size = @intCast(s.len) },
        };

        self.transfer_command_buffer.copyBuffer(staging_buffer.buffer, buffer.buffer, @intCast(regions.len), regions.ptr);
        self.transfer_command_buffer.endCommandBuffer() catch return error.Failed;

        self.graphics_queue.submit(1, @ptrCast(&vk.SubmitInfo{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&self.transfer_command_buffer),
        }), .null_handle) catch return error.Failed;
        self.graphics_queue.waitIdle() catch return error.Failed;
    }

    pub fn bufferMap(self: *VulkanRenderer, buffer_rid: RID) Renderer.BufferMapError![]u8 {
        const buffer = buffer_rid.as(VulkanBuffer);

        var data: ?*anyopaque = null;

        if (vma.vmaMapMemory(self.vma_allocator, buffer.allocation, &data) != vma.VK_SUCCESS) {
            return error.Failed;
        }

        if (data) |ptr| {
            return @as([*]u8, @ptrCast(ptr))[0..buffer.size];
        } else {
            return error.Failed;
        }
    }

    pub fn bufferUnmap(self: *VulkanRenderer, buffer_rid: RID) void {
        const buffer = buffer_rid.as(VulkanBuffer);
        vma.vmaUnmapMemory(self.vma_allocator, buffer.allocation);
    }

    //
    // Image
    //

    pub fn imageCreate(self: *VulkanRenderer, options: Renderer.ImageOptions) Renderer.ImageCreateError!RID {
        const image_info: vk.ImageCreateInfo = .{
            .image_type = .@"2d",
            .format = options.format.asVk(),
            .extent = .{ .width = @intCast(options.width), .height = @intCast(options.height), .depth = 1 },
            .mip_levels = 1,
            .array_layers = @intCast(options.layers),
            .samples = .{ .@"1_bit" = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
            .tiling = options.tiling.asVk(),
            .usage = options.usage.asVk(),
        };

        const alloc_info: vma.VmaAllocationCreateInfo = .{
            .usage = vma.VMA_MEMORY_USAGE_GPU_ONLY,
        };

        var image: vk.Image = .null_handle;
        var alloc: vma.VmaAllocation = undefined;

        if (vma.vmaCreateImage(self.vma_allocator, @ptrCast(&image_info), @ptrCast(&alloc_info), @ptrCast(&image), &alloc, null) != vma.VK_SUCCESS)
            return error.OutOfDeviceMemory;
        errdefer vma.vmaDestroyImage(self.vma_allocator, @ptrFromInt(@as(usize, @intFromEnum(image))), alloc);

        const image_view = self.device.createImageView(&vk.ImageViewCreateInfo{
            .image = image,
            .view_type = if (options.layers == 1) .@"2d" else .@"2d_array",
            .format = options.format.asVk(),
            .components = switch (options.pixel_mapping) {
                .identity => .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .grayscale => .{ .r = .identity, .g = .r, .b = .r, .a = .one },
            },
            .subresource_range = .{
                .aspect_mask = options.aspect_mask.asVk(),
                .base_array_layer = 0,
                .layer_count = @intCast(options.layers),
                .base_mip_level = 0,
                .level_count = 1,
            },
        }, null) catch return error.OutOfDeviceMemory;
        errdefer self.device.destroyImageView(image_view, null);

        return .{ .inner = @intFromPtr(try createWithInit(VulkanImage, self.allocator, .{
            .width = options.width,
            .height = options.height,
            .layers = options.layers,
            .size = options.format.sizeBytes() * options.width * options.height,
            .image = image,
            .view = image_view,
            .allocation = alloc,
            .layout = .undefined,
            .aspect_mask = options.aspect_mask.asVk(),
        })) };
    }

    fn imageCreateFromVkHandle(self: *VulkanRenderer, image: vk.Image, format: vk.Format) Renderer.ImageCreateError!RID {
        const image_view = self.device.createImageView(&vk.ImageViewCreateInfo{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_array_layer = 0,
                .layer_count = 1,
                .base_mip_level = 0,
                .level_count = 1,
            },
        }, null) catch return error.OutOfDeviceMemory;
        errdefer self.device.destroyImageView(image_view, null);

        return .{ .inner = @intFromPtr(try createWithInit(VulkanImage, self.allocator, .{
            .width = undefined,
            .height = undefined,
            .size = undefined,
            .layers = 1,
            .image = image,
            .view = image_view,
            .allocation = undefined,
            .layout = .undefined,
            .aspect_mask = .{ .color_bit = true },
        })) };
    }

    pub fn imageUpdate(self: *VulkanRenderer, image_rid: RID, s: []const u8, offset: usize, layer: usize) Renderer.UpdateImageError!void {
        const image = image_rid.as(VulkanImage);

        std.debug.assert(s.len <= image.size - offset);

        var staging_buffer_rid = try self.bufferCreate(.{ .size = s.len, .usage = .{ .transfer_src = true }, .alloc_usage = .cpu_to_gpu });
        const staging_buffer = staging_buffer_rid.as(VulkanBuffer);
        defer self.bufferDestroy(staging_buffer_rid);

        {
            const map_data = try self.bufferMap(staging_buffer_rid);
            defer self.bufferUnmap(staging_buffer_rid);

            @memcpy(map_data[0..s.len], s);
        }

        // Record the command buffer
        self.graphics_queue_mutex.lock();
        defer self.graphics_queue_mutex.unlock();

        self.transfer_command_buffer.resetCommandBuffer(.{}) catch return error.Failed;
        self.transfer_command_buffer.beginCommandBuffer(&vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
        }) catch return error.Failed;

        const regions: []const vk.BufferImageCopy = &.{
            vk.BufferImageCopy{
                .buffer_offset = @intCast(offset),
                .buffer_row_length = 0,
                .buffer_image_height = 0,
                .image_subresource = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_array_layer = @intCast(layer),
                    .layer_count = 1,
                    .mip_level = 0,
                },
                .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                .image_extent = .{ .width = @intCast(image.width), .height = @intCast(image.height), .depth = 1 },
            },
        };

        self.transfer_command_buffer.copyBufferToImage(staging_buffer.buffer, image.image, .transfer_dst_optimal, @intCast(regions.len), regions.ptr);
        self.transfer_command_buffer.endCommandBuffer() catch return error.Failed;

        self.graphics_queue.submit(1, @ptrCast(&vk.SubmitInfo{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&self.transfer_command_buffer),
        }), .null_handle) catch return error.Failed;
        self.graphics_queue.waitIdle() catch return error.Failed;
    }

    pub fn imageSetLayout(self: *VulkanRenderer, image_rid: RID, new_layout: vk.ImageLayout) Renderer.ImageSetLayoutError!void {
        const image = image_rid.as(VulkanImage);

        const cb = self.transfer_command_buffer;

        self.graphics_queue_mutex.lock();
        defer self.graphics_queue_mutex.unlock();

        cb.beginCommandBuffer(&vk.CommandBufferBeginInfo{}) catch return error.Failed;

        var src_stage_mask: vk.PipelineStageFlags = undefined;
        var dst_stage_mask: vk.PipelineStageFlags = undefined;

        var barrier: vk.ImageMemoryBarrier = .{
            .src_access_mask = .{},
            .dst_access_mask = .{},
            .old_layout = image.layout,
            .new_layout = new_layout,
            .image = image.image,
            .subresource_range = .{
                .aspect_mask = image.aspect_mask,
                .base_array_layer = 0,
                .layer_count = @intCast(image.layers),
                .base_mip_level = 0,
                .level_count = 1,
            },
            .src_queue_family_index = 0,
            .dst_queue_family_index = 0,
        };

        if (image.layout == .undefined and new_layout == .transfer_dst_optimal) {
            barrier.src_access_mask = .{};
            barrier.dst_access_mask = .{ .transfer_write_bit = true };

            src_stage_mask = .{ .top_of_pipe_bit = true };
            dst_stage_mask = .{ .transfer_bit = true };
        } else if (image.layout == .transfer_dst_optimal and new_layout == .shader_read_only_optimal) {
            barrier.src_access_mask = .{ .transfer_write_bit = true };
            barrier.dst_access_mask = .{ .shader_read_bit = true };

            src_stage_mask = .{ .transfer_bit = true };
            dst_stage_mask = .{ .fragment_shader_bit = true };
        } else if (image.layout == .undefined and new_layout == .depth_stencil_attachment_optimal) {
            barrier.src_access_mask = .{};
            barrier.dst_access_mask = .{ .depth_stencil_attachment_read_bit = true };

            src_stage_mask = .{ .transfer_bit = true };
            dst_stage_mask = .{ .early_fragment_tests_bit = true };
        } else {
            std.debug.panic("unsupported layout: old = {}, new = {}\n", .{ image.layout, new_layout });
        }

        cb.pipelineBarrier(src_stage_mask, dst_stage_mask, .{}, 0, null, 0, null, 1, @ptrCast(&barrier));
        cb.endCommandBuffer() catch return error.Failed;
        self.graphics_queue.submit(1, &.{vk.SubmitInfo{ .command_buffer_count = 1, .p_command_buffers = @ptrCast(&cb) }}, .null_handle) catch return error.Failed;
        self.graphics_queue.waitIdle() catch return error.Failed;

        image.layout = new_layout;
    }

    //
    // Pipeline
    //

    const shaders = @import("shaders");

    const basic_cube_vert align(@alignOf(u32)) = shaders.basic_cube_vert;
    const basic_cube_frag align(@alignOf(u32)) = shaders.basic_cube_frag;

    pub fn pipelineCreateGraphics(self: *VulkanRenderer, options: Renderer.PipelineGraphicsOptions) Renderer.PipelineCreateError!RID {
        const shader_stages: []const vk.PipelineShaderStageCreateInfo = &.{
            .{
                .stage = .{ .vertex_bit = true },
                .module = self.createShaderModule(&basic_cube_vert) catch return error.ShaderCompilationFailed,
                .p_name = "main",
            },
            .{
                .stage = .{ .fragment_bit = true },
                .module = self.createShaderModule(&basic_cube_frag) catch return error.ShaderCompilationFailed,
                .p_name = "main",
            },
        };

        const dynamic_states: []const vk.DynamicState = &.{ .viewport, .scissor };
        const dynamic_state_info: vk.PipelineDynamicStateCreateInfo = .{
            .dynamic_state_count = @intCast(dynamic_states.len),
            .p_dynamic_states = dynamic_states.ptr,
        };

        const vertex_input_info: vk.PipelineVertexInputStateCreateInfo = .{
            .vertex_binding_description_count = @intCast(options.shader_model.vk_bindings.items.len),
            .p_vertex_binding_descriptions = options.shader_model.vk_bindings.items.ptr,
            .vertex_attribute_description_count = @intCast(options.shader_model.vk_attribs.items.len),
            .p_vertex_attribute_descriptions = options.shader_model.vk_attribs.items.ptr,
        };

        const input_assembly_info: vk.PipelineInputAssemblyStateCreateInfo = .{
            .topology = options.shader_model.topology,
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
            .polygon_mode = options.shader_model.polygon_mode,
            .line_width = 1.0,
            .cull_mode = .{ .back_bit = true },
            .front_face = .counter_clockwise,
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

        const descriptor_pool = MaterialDescriptorPool.init(self.allocator, options.shader_model) catch return error.Failed;

        const layout_info: vk.PipelineLayoutCreateInfo = .{
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&descriptor_pool.descriptor_set_layout),
            .push_constant_range_count = @intCast(options.shader_model.vk_push_constants.items.len),
            .p_push_constant_ranges = options.shader_model.vk_push_constants.items.ptr,
        };

        const pipeline_layout = self.device.createPipelineLayout(&layout_info, null) catch return error.Failed;

        var pipeline: vk.Pipeline = .null_handle;
        _ = self.device.createGraphicsPipelines(.null_handle, 1, @ptrCast(&vk.GraphicsPipelineCreateInfo{
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
            .render_pass = options.render_pass.as(VulkanRenderPass).render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        }), null, @ptrCast(&pipeline)) catch return error.Failed;
        errdefer rdr().asVk().device.destroyPipeline(pipeline, null);

        return .{ .inner = @intFromPtr(try createWithInit(VulkanPipeline, self.allocator, .{
            .pipeline = pipeline,
            .layout = pipeline_layout,
            .descriptor_pool = descriptor_pool,
        })) };
    }

    //
    // RenderPass
    //

    pub fn renderPassCreate(self: *VulkanRenderer, options: Renderer.RenderPassOptions) Renderer.RenderPassCreateError!RID {
        _ = options; // TODO

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

        const render_pass = self.device.createRenderPass(&vk.RenderPassCreateInfo{
            .attachment_count = @intCast(attachments.len),
            .p_attachments = attachments.ptr,
            .subpass_count = 1,
            .p_subpasses = @ptrCast(&subpass),
            .dependency_count = 1,
            .p_dependencies = @ptrCast(&dependency),
        }, null) catch return error.Failed;
        errdefer self.device.destroyRenderPass(render_pass, null);

        return .{ .inner = @intFromPtr(try createWithInit(VulkanRenderPass, self.allocator, .{
            .render_pass = render_pass,
        })) };
    }

    //
    // Framebuffer
    //

    pub fn framebufferCreate(self: *VulkanRenderer, options: Renderer.FramebufferOptions) Renderer.FramebufferCreateError!RID {
        // Ideally there should not be more than 2 attachments at the same time: one for color and one for depth.
        const max_attachments = 2;

        std.debug.assert(options.attachments.len <= max_attachments);

        var attachments: [max_attachments]vk.ImageView = undefined;

        for (options.attachments, 0..options.attachments.len) |attach_rid, index| {
            const image = attach_rid.as(VulkanImage);
            attachments[index] = image.view;
        }

        const framebuffer = self.device.createFramebuffer(&vk.FramebufferCreateInfo{
            .render_pass = options.render_pass.as(VulkanRenderPass).render_pass,
            .attachment_count = @intCast(options.attachments.len),
            .p_attachments = attachments[0..options.attachments.len].ptr,
            .width = @intCast(options.width),
            .height = @intCast(options.height),
            .layers = 1,
        }, null) catch return error.Failed;

        return .{ .inner = @intFromPtr(try createWithInit(VulkanFramebuffer, self.allocator, .{
            .framebuffer = framebuffer,
        })) };
    }

    pub fn createShaderModule(self: *VulkanRenderer, spirv: [:0]align(4) const u8) vk.DeviceProxy.CreateShaderModuleError!vk.ShaderModule {
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

pub const VulkanBuffer = struct {
    pub const resource_signature: usize = @truncate(0x5e165628f7e0b61a);

    signature: usize = resource_signature,
    size: usize,
    buffer: vk.Buffer,
    allocation: vma.VmaAllocation,
};

pub const VulkanImage = struct {
    pub const resource_signature: usize = @truncate(0x97d7ecd5e0bffa7c);

    signature: usize = resource_signature,

    width: usize,
    height: usize,
    layers: usize,

    /// Total size in bytes.
    size: usize,

    image: vk.Image,
    view: vk.ImageView,
    allocation: vma.VmaAllocation,

    layout: vk.ImageLayout,
    aspect_mask: vk.ImageAspectFlags,
};

pub const VulkanPipeline = struct {
    pub const resource_signature: usize = @truncate(0x5789d7753bca202c);

    signature: usize = resource_signature,
    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,
    descriptor_pool: MaterialDescriptorPool,
};

const MaterialDescriptorPool = struct {
    pools: std.ArrayList(vk.DescriptorPool),
    count: usize,
    descriptor_set_layout: vk.DescriptorSetLayout,
    shader_model: ShaderModel,

    const pool_size: usize = 16;

    pub fn init(allocator: Allocator, shader_model: ShaderModel) !MaterialDescriptorPool {
        const descriptor_set_layout = try rdr().asVk().device.createDescriptorSetLayout(&vk.DescriptorSetLayoutCreateInfo{
            .binding_count = @intCast(shader_model.vk_descriptor_bindings.items.len),
            .p_bindings = shader_model.vk_descriptor_bindings.items.ptr,
        }, null);

        return .{
            .pools = .init(allocator),
            .count = 0,
            .descriptor_set_layout = descriptor_set_layout,
            .shader_model = shader_model,
        };
    }

    pub fn deinit(self: *const MaterialDescriptorPool) void {
        for (self.pools.items) |pool| rdr().asVk().device.destroyQueryPool(pool, null);
        self.pools.deinit();
    }

    pub fn createDescriptorSet(self: *MaterialDescriptorPool) !vk.DescriptorSet {
        if (self.count >= self.pools.items.len * pool_size) {
            // TODO: Should probably allocate as much of each bindings.

            // Funnily enough, on linux it seems that it does not care about what we are giving it here, but it crash
            // with moltenvk if we don't correctly specify the pool size.
            const sizes: []const vk.DescriptorPoolSize = &.{
                .{ .type = .combined_image_sampler, .descriptor_count = pool_size },
                .{ .type = .uniform_buffer, .descriptor_count = pool_size },
            };
            const pool = try rdr().asVk().device.createDescriptorPool(&vk.DescriptorPoolCreateInfo{
                .pool_size_count = @intCast(sizes.len),
                .p_pool_sizes = sizes.ptr,
                .max_sets = 1,
            }, null);

            try self.pools.append(pool);
        }

        const pool: vk.DescriptorPool = self.pools.items[self.count / pool_size];
        self.count += 1;

        var descriptor_set: vk.DescriptorSet = undefined;
        try rdr().asVk().device.allocateDescriptorSets(&vk.DescriptorSetAllocateInfo{ .descriptor_pool = pool, .descriptor_set_count = 1, .p_set_layouts = @ptrCast(&self.descriptor_set_layout) }, @ptrCast(&descriptor_set));

        return descriptor_set;
    }
};

pub const VulkanRenderPass = struct {
    pub const resource_signature: usize = @truncate(0xb848438b714985aa);

    signature: usize = resource_signature,
    render_pass: vk.RenderPass,
};

pub const VulkanFramebuffer = struct {
    pub const resource_signature: usize = @truncate(0x264657ac2e68fd36);

    signature: usize = resource_signature,
    framebuffer: vk.Framebuffer,
};

/// Create a value and initialize it right away to prevent `undefined` values from getting into `T`.
fn createWithInit(comptime T: type, allocator: Allocator, value: T) Allocator.Error!*T {
    const ptr = try allocator.create(T);
    ptr.* = value;
    return ptr;
}

/// Create a value and fill its field with default values if applicable.
fn createWithDefault(comptime T: type, allocator: Allocator) Allocator.Error!*T {
    const info = @typeInfo(T);
    const ptr = try allocator.create(T);

    switch (info) {
        .@"struct" => |s| {
            inline for (s.fields) |field| {
                if (field.defaultValue()) |value|
                    @field(ptr.*, field.name) = value;
            }
        },
        else => {},
    }

    return ptr;
}

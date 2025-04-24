const std = @import("std");
const vk = @import("vulkan");
const sdl = @import("sdl");
const builtin = @import("builtin");
const zm = @import("zmath");
const zigimg = @import("zigimg");
const dcimgui = @import("dcimgui");
const assets = @import("../assets.zig");

const Allocator = std.mem.Allocator;
const Camera = @import("../Camera.zig");
const World = @import("../voxel/World.zig");
const Window = @import("Window.zig");
const Graph = @import("Graph.zig");
const Renderer = @import("Renderer.zig");
const RID = Renderer.RID;

const rdr = Renderer.rdr;
const createWithInit = Renderer.createWithInit;

const GetInstanceProcAddrFn = fn (instance: vk.Instance, name: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void;
const GetDeviceProcAddrFn = fn (device: vk.Device, name: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void;

const use_moltenvk = builtin.os.tag.isDarwin();

const RIDAllocInfo = struct {
    stack_trace: std.debug.Trace,
};

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

    // Device memory allocation
    memory_properties: vk.PhysicalDeviceMemoryProperties,

    output_render_pass: RID,
    pipeline_cache: PipelineCache = .{},

    /// Buffer used when transfering data from buffer to buffer.
    transfer_command_buffer: vk.CommandBufferProxy,

    features: Features,
    statistics: Renderer.Statistics = .{},

    imgui_context: *dcimgui.ImGuiContext,
    imgui_sampler: vk.Sampler,
    imgui_descriptor_pool: vk.DescriptorPool,

    rid_infos_mutex: if (builtin.mode == .Debug) std.Thread.Mutex else DummyMutex = .{},
    rid_infos: if (builtin.mode == .Debug) std.AutoArrayHashMapUnmanaged(RID, RIDAllocInfo) else void = if (builtin.mode == .Debug) .empty else {},

    const max_frames_in_flight: usize = 2;

    const DummyMutex = struct {
        pub inline fn lock(_: *DummyMutex) void {}
        pub inline fn unlock(_: *DummyMutex) void {}
    };

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
        .wait_idle = @ptrCast(&waitIdle),

        .imgui_init = @ptrCast(&imguiInit),
        .imgui_destroy = @ptrCast(&imguiDestroy),
        .imgui_add_texture = @ptrCast(&imguiAddTexture),
        .imgui_remove_texture = @ptrCast(&imguiRemoveTexture),

        .free_rid = @ptrCast(&freeRid),

        .buffer_create = @ptrCast(&bufferCreate),
        .buffer_update = @ptrCast(&bufferUpdate),
        .buffer_map = @ptrCast(&bufferMap),
        .buffer_unmap = @ptrCast(&bufferUnmap),

        .image_create = @ptrCast(&imageCreate),
        .image_update = @ptrCast(&imageUpdate),
        .image_set_layout = @ptrCast(&imageSetLayout),

        .material_create = @ptrCast(&materialCreate),
        .material_set_param = @ptrCast(&materialSetParam),

        .mesh_create = @ptrCast(&meshCreate),
        .mesh_get_indices_count = @ptrCast(&meshGetIndicesCount),

        .renderpass_create = @ptrCast(&renderPassCreate),

        .framebuffer_create = @ptrCast(&framebufferCreate),
    };

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

        const instance_handle = try vkb.createInstance(&vk.InstanceCreateInfo{
            .flags = if (builtin.target.os.tag == .macos) .{ .enumerate_portability_bit_khr = true } else .{},
            .p_application_info = &app_info,
            .enabled_layer_count = if (builtin.mode == .Debug) 1 else 0,
            .pp_enabled_layer_names = if (builtin.mode == .Debug) &.{"VK_LAYER_KHRONOS_validation"} else null,
            .enabled_extension_count = @intCast(required_instance_extensions.items.len),
            .pp_enabled_extension_names = required_instance_extensions.items.ptr,
        }, null);
        instance_wrapper = .load(instance_handle, get_instance_proc_addr);

        self.instance = vk.InstanceProxy.init(instance_handle, &instance_wrapper);
        errdefer self.instance.destroyInstance(null);

        // Create the surface
        self.surface = window.createVkSurface(self.instance.handle, null);
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

        self.memory_properties = self.instance.getPhysicalDeviceMemoryProperties(self.physical_device);

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

        self.output_render_pass = try rdr().renderPassCreate(.{
            .attachments = &.{
                .{
                    .type = .color,
                    .layout = .color_attachment_optimal,
                    .format = Renderer.Format.fromVk(self.surface_format.format),
                    .load_op = .clear,
                    .store_op = .store,
                    .stencil_load_op = .dont_care,
                    .stencil_store_op = .dont_care,
                    .initial_layout = .undefined,
                    .final_layout = .present_src,
                },
                .{
                    .type = .depth,
                    .layout = .depth_stencil_attachment_optimal,
                    .format = .d32_sfloat, // TODO: Detect supported depth format.
                    .load_op = .clear,
                    .store_op = .dont_care,
                    .stencil_load_op = .dont_care,
                    .stencil_store_op = .dont_care,
                    .initial_layout = .undefined,
                    .final_layout = .depth_stencil_attachment_optimal,
                },
            },
        });
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
        for (pass.dependencies.items) |dep| {
            try self.processRenderPass(cb, fb, dep);
        }

        const render_pass = pass.render_pass.as(VulkanRenderPass);

        var clears: [4]vk.ClearValue = undefined;

        for (render_pass.attachments, 0..render_pass.attachments.len) |attach, index| {
            switch (attach.type) {
                .color => {
                    clears[index] = .{ .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 0.0 } } };
                },
                .depth => {
                    clears[index] = .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0.0 } };
                },
            }
        }

        cb.beginRenderPass(&vk.RenderPassBeginInfo{
            .render_pass = render_pass.render_pass,
            .framebuffer = switch (pass.target.framebuffer) {
                .native => fb.as(VulkanFramebuffer).framebuffer,
                .custom => |v| v.as(VulkanFramebuffer).framebuffer,
            },
            .render_area = switch (pass.target.viewport) {
                .native => .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = self.swapchain_extent.width, .height = self.swapchain_extent.height } },
                .custom => |v| .{ .offset = .{ .x = @intCast(v.x), .y = @intCast(v.y) }, .extent = .{ .width = @intCast(v.width), .height = @intCast(v.height) } },
            },
            .clear_value_count = @intCast(render_pass.attachments.len),
            .p_clear_values = &clears,
        }, .@"inline");

        for (pass.draw_calls.items) |*call| {
            const material = call.material.as(VulkanMaterial);
            const mesh = call.mesh.as(VulkanMesh);

            const pipeline = try self.pipeline_cache.getOrCreate(self, .{
                .render_pass = pass.render_pass,
                .transparency = false, // TODO
                .material = material,
            });

            cb.bindPipeline(.graphics, pipeline.pipeline);
            cb.bindDescriptorSets(.graphics, pipeline.layout, 0, 1, @ptrCast(&material.descriptor_set), 0, null);

            cb.bindIndexBuffer(mesh.index_buffer.as(VulkanBuffer).buffer, 0, mesh.index_type);

            cb.bindVertexBuffers(0, 3, &.{
                mesh.vertex_buffer.as(VulkanBuffer).buffer,
                mesh.normal_buffer.as(VulkanBuffer).buffer,
                mesh.texture_coords_buffer.as(VulkanBuffer).buffer,
            }, &.{ 0, 0, 0 });

            if (call.instance_buffer) |ib| cb.bindVertexBuffers(3, 1, @ptrCast(&ib.as(VulkanBuffer).buffer), &.{0});

            cb.setViewport(0, 1, @ptrCast(&vk.Viewport{
                .x = 0.0,
                .y = 0.0,
                .width = @floatFromInt(self.swapchain_extent.width), // TODO
                .height = @floatFromInt(self.swapchain_extent.height),
                .min_depth = 0.0,
                .max_depth = 1.0,
            }));

            cb.setScissor(0, 1, @ptrCast(&vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.swapchain_extent,
            }));

            const constants: Graph.PushConstants = .{
                .view_matrix = pass.view_matrix,
            };

            cb.pushConstants(pipeline.layout, .{ .vertex_bit = true }, 0, @sizeOf(Graph.PushConstants), @ptrCast(&constants));

            cb.drawIndexed(@intCast(call.vertex_count), @intCast(call.instance_count), 0, 0, 0);
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
        // var total_vram: usize = 0;

        // var budgets: [vma.VK_MAX_MEMORY_HEAPS]vma.VmaBudget = @splat(.{});
        // vma.vmaGetHeapBudgets(self.vma_allocator, &budgets);
        // var index: usize = 0;
        // while (index < @as(usize, @intCast(vma.VK_MAX_MEMORY_HEAPS))) : (index += 1) {
        //     total_vram += budgets[index].statistics.allocationBytes;
        // }

        return .{
            .gpu_time = self.statistics.gpu_time,
            .primitives_drawn = self.statistics.primitives_drawn,
            .vram_used = 0,
        };
    }

    pub fn destroy(self: *VulkanRenderer) void {
        self.device.deviceWaitIdle() catch {};

        self.freeRid(self.output_render_pass);

        self.device.destroySampler(self.imgui_sampler, null);

        self.pipeline_cache.deinit(self);

        // Destroy swapchain related resourcess
        for (self.swapchain_framebuffers) |fb| self.freeRid(fb);
        self.allocator.free(self.swapchain_framebuffers);

        for (self.swapchain_images) |image| self.freeRid(image);
        self.allocator.free(self.swapchain_images);

        self.device.destroySwapchainKHR(self.swapchain, null);

        self.device.destroyQueryPool(self.timestamp_query_pool, null);
        self.device.destroyQueryPool(self.primitives_query_pool, null);

        // Destroy resources allocated for each frame in flight.
        for (self.command_buffers) |cb| self.device.freeCommandBuffers(self.command_pool, 1, @ptrCast(&cb.handle));
        for (self.image_available_semaphores) |semaphore| self.device.destroySemaphore(semaphore, null);
        for (self.render_finished_semaphores) |semaphore| self.device.destroySemaphore(semaphore, null);
        for (self.in_flight_fences) |fence| self.device.destroyFence(fence, null);

        self.device.freeCommandBuffers(self.command_pool, 1, @ptrCast(&self.transfer_command_buffer.handle));
        self.device.destroyCommandPool(self.command_pool, null);

        self.freeRid(self.depth_image);

        if (builtin.mode == .Debug) {
            if (self.rid_infos.count() > 0) {
                std.log.err("Found RIDs when destroying the rendering device:", .{});

                var iter = self.rid_infos.iterator();

                while (iter.next()) |entry| {
                    std.debug.print("RID 0x{x}\n", .{entry.key_ptr.inner});
                    entry.value_ptr.stack_trace.dump();
                }
            }
        }

        self.device.destroyDevice(null);
        self.instance.destroySurfaceKHR(self.surface, null);
        self.instance.destroyInstance(null);
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
        for (images, 0..swapchain_images.len) |image, index| {
            framebuffers[index] = try self.framebufferCreate(.{
                .attachments = &.{ image, depth_image_rid },
                .render_pass = self.output_render_pass,
                .width = @intCast(surface_extent.width),
                .height = @intCast(surface_extent.height),
            });
        }

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

    pub fn waitIdle(self: *VulkanRenderer) void {
        self.graphics_queue_mutex.lock();
        defer self.graphics_queue_mutex.unlock();

        self.graphics_queue.waitIdle() catch {};
    }

    pub fn imguiInit(self: *VulkanRenderer, window: *const Window, render_pass_rid: RID) Renderer.ImGuiInitError!void {
        self.imgui_context = dcimgui.ImGui_CreateContext(null) orelse @panic("Failed to initialize DearImGui");

        var io: *dcimgui.ImGuiIO = dcimgui.ImGui_GetIO() orelse unreachable;
        io.ConfigFlags |= dcimgui.ImGuiConfigFlags_NavEnableKeyboard;
        _ = dcimgui.cImGui_ImplSDL3_InitForVulkan(@ptrCast(window.handle));

        self.imgui_descriptor_pool = self.device.createDescriptorPool(&vk.DescriptorPoolCreateInfo{
            .flags = .{ .free_descriptor_set_bit = true },
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

    pub fn imguiDestroy(self: *VulkanRenderer) void {
        dcimgui.cImGui_ImplVulkan_Shutdown();
        dcimgui.cImGui_ImplSDL3_Shutdown();
        dcimgui.ImGui_DestroyContext(self.imgui_context);

        self.device.destroyDescriptorPool(self.imgui_descriptor_pool, null);
    }

    pub fn imguiAddTexture(self: *VulkanRenderer, image_rid: RID, layout: Renderer.ImageLayout) Renderer.ImGuiAddTextureError!c_ulonglong {
        return @intFromPtr(dcimgui.cImGui_ImplVulkan_AddTexture(@ptrFromInt(@intFromEnum(self.imgui_sampler)), @ptrFromInt(@intFromEnum(image_rid.as(VulkanImage).view)), @intCast(@intFromEnum(layout.asVk()))));
    }

    pub fn imguiRemoveTexture(self: *VulkanRenderer, id: c_ulonglong) void {
        _ = self;
        dcimgui.cImGui_ImplVulkan_RemoveTexture(@ptrFromInt(id));
    }

    //
    // Common
    //

    pub fn freeRid(self: *VulkanRenderer, rid: RID) void {
        if (rid.tryAs(VulkanBuffer)) |buffer| {
            buffer.deinit(self);
        } else if (rid.tryAs(VulkanImage)) |image| {
            image.deinit(self);
        } else if (rid.tryAs(VulkanFramebuffer)) |framebuffer| {
            self.device.destroyFramebuffer(framebuffer.framebuffer, null);
        } else if (rid.tryAs(VulkanRenderPass)) |render_pass| {
            self.device.destroyRenderPass(render_pass.render_pass, null);
        } else if (rid.tryAs(VulkanMaterial)) |material| {
            material.deinit(self);
        } else if (rid.tryAs(VulkanMesh)) |mesh| {
            mesh.deinit(self);
        } else {
            std.debug.panic("Trying to free rid with signature {x}", .{@as(*const usize, @ptrFromInt(rid.inner)).*});
        }

        self.rid_infos_mutex.lock();
        defer self.rid_infos_mutex.unlock();

        _ = self.rid_infos.swapRemove(rid);
    }

    inline fn addRIDInfo(self: *VulkanRenderer, rid: RID, ret_addr: usize) error{OutOfMemory}!void {
        if (builtin.mode == .Debug) {
            var trace: std.debug.Trace = .init;
            trace.addAddr(ret_addr, "");
            try self.rid_infos.put(self.allocator, rid, .{ .stack_trace = trace });
        }
    }

    //
    // Buffer
    //

    pub fn bufferCreate(self: *VulkanRenderer, options: Renderer.BufferOptions) Renderer.BufferCreateError!RID {
        const alloc_flags: vk.MemoryPropertyFlags = switch (options.alloc_usage) {
            .gpu_only => .{ .device_local_bit = true },
            .cpu_to_gpu => .{ .device_local_bit = true, .host_visible_bit = true },
        };

        const buffer = self.device.createBuffer(&vk.BufferCreateInfo{
            .size = @intCast(options.size),
            .usage = options.usage.asVk(),
            .sharing_mode = .exclusive,
        }, null) catch return error.Failed;
        errdefer self.device.destroyBuffer(buffer, null);

        const memory = self.allocMemoryForBuffer(buffer, alloc_flags) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OutOfDeviceMemory => return error.OutOfDeviceMemory,
            else => return error.Failed,
        };
        errdefer self.device.freeMemory(memory, null);

        const rid: RID = .{ .inner = @intFromPtr(try createWithInit(VulkanBuffer, self.allocator, .{
            .size = options.size,
            .buffer = buffer,
            .memory = memory,
        })) };

        self.rid_infos_mutex.lock();
        defer self.rid_infos_mutex.unlock();

        try self.addRIDInfo(rid, @returnAddress());
        return rid;
    }

    pub fn bufferUpdate(self: *VulkanRenderer, buffer_rid: RID, s: []const u8, offset: usize) Renderer.BufferUpdateError!void {
        const buffer = buffer_rid.as(VulkanBuffer);

        std.debug.assert(s.len <= buffer.size - offset);

        // Nothing to update, skip it otherwise `bufferCreate` will fail.
        if (s.len == 0) {
            return;
        }

        var staging_buffer_rid = try self.bufferCreate(.{ .size = s.len, .usage = .{ .transfer_src = true }, .alloc_usage = .cpu_to_gpu });
        defer self.freeRid(staging_buffer_rid);

        const staging_buffer = staging_buffer_rid.as(VulkanBuffer);

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

        const data: ?*anyopaque = self.device.mapMemory(buffer.memory, 0, buffer.size, .{}) catch return error.Failed;

        if (data) |ptr| {
            return @as([*]u8, @ptrCast(ptr))[0..buffer.size];
        } else {
            return error.Failed;
        }
    }

    pub fn bufferUnmap(self: *VulkanRenderer, buffer_rid: RID) void {
        const buffer = buffer_rid.as(VulkanBuffer);
        self.device.unmapMemory(buffer.memory);
    }

    //
    // Image
    //

    pub fn imageCreate(self: *VulkanRenderer, options: Renderer.ImageOptions) Renderer.ImageCreateError!RID {
        const image = self.device.createImage(&vk.ImageCreateInfo{
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
        }, null) catch return error.Failed;
        errdefer self.device.destroyImage(image, null);

        const memory = self.allocMemoryForImage(image, .{ .device_local_bit = true }) catch |e| switch (e) {
            error.OutOfDeviceMemory => return error.OutOfDeviceMemory,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Failed,
        };
        errdefer self.device.freeMemory(memory, null);

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

        const rid: RID = .{ .inner = @intFromPtr(try createWithInit(VulkanImage, self.allocator, .{
            .width = options.width,
            .height = options.height,
            .layers = options.layers,
            .size = options.format.sizeBytes() * options.width * options.height,
            .image = image,
            .view = image_view,
            .memory = memory,
            .layout = .undefined,
            .aspect_mask = options.aspect_mask.asVk(),
        })) };

        self.rid_infos_mutex.lock();
        defer self.rid_infos_mutex.unlock();

        try self.addRIDInfo(rid, @returnAddress());
        return rid;
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

        const rid: RID = .{ .inner = @intFromPtr(try createWithInit(VulkanImage, self.allocator, .{
            .width = undefined,
            .height = undefined,
            .size = undefined,
            .layers = 1,
            .image = image,
            .external_image = true,
            .view = image_view,
            .memory = undefined,
            .layout = .undefined,
            .aspect_mask = .{ .color_bit = true },
        })) };

        self.rid_infos_mutex.lock();
        defer self.rid_infos_mutex.unlock();

        try self.addRIDInfo(rid, @returnAddress());
        return rid;
    }

    pub fn imageUpdate(self: *VulkanRenderer, image_rid: RID, s: []const u8, offset: usize, layer: usize) Renderer.UpdateImageError!void {
        const image = image_rid.as(VulkanImage);

        std.debug.assert(s.len <= image.size - offset);

        var staging_buffer_rid = try self.bufferCreate(.{ .size = s.len, .usage = .{ .transfer_src = true }, .alloc_usage = .cpu_to_gpu });
        const staging_buffer = staging_buffer_rid.as(VulkanBuffer);
        defer self.freeRid(staging_buffer_rid);

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

    pub fn imageSetLayout(self: *VulkanRenderer, image_rid: RID, new_layout: Renderer.ImageLayout) Renderer.ImageSetLayoutError!void {
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
            .new_layout = new_layout.asVk(),
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

        image.layout = new_layout.asVk();
    }

    //
    // Material
    //

    pub fn materialCreate(self: *VulkanRenderer, options: Renderer.MaterialOptions) Renderer.MaterialCreateError!RID {
        var descriptor_pool = DynamicDescriptorPool.init(self.allocator, options.params) catch return error.Failed;
        const descriptor_set = descriptor_pool.createDescriptorSet() catch return error.Failed;

        const params = try self.allocator.alloc(VulkanMaterial.Param, options.params.len);

        for (options.params, 0..options.params.len) |param, index| {
            params[index] = .{
                .name = try self.allocator.dupe(u8, param.name),
                .binding = index,
                .type = param.type,
            };
        }

        const rid: RID = .{
            .inner = @intFromPtr(try createWithInit(VulkanMaterial, self.allocator, .{
                .descriptor_pool = descriptor_pool,
                .descriptor_set = descriptor_set,
                .descriptor_set_layout = descriptor_pool.descriptor_set_layout,
                .shaders = options.shaders, // TODO: Duplicate this ?
                .params = params,
                .instance_layout = options.instance_layout,
                .topology = options.topology.asVk(),
                .polygon_mode = options.polygon_mode.asVk(),
                .cull_mode = options.cull_mode.asVk(),
                .transparency = options.transparency,
            })),
        };

        self.rid_infos_mutex.lock();
        defer self.rid_infos_mutex.unlock();

        try self.addRIDInfo(rid, @returnAddress());
        return rid;
    }

    pub fn materialSetParam(self: *VulkanRenderer, material_rid: RID, name: []const u8, value: Renderer.MaterialParameterValue) Renderer.MaterialSetParamError!void {
        const material = material_rid.as(VulkanMaterial);
        const param = material.getParam(name) orelse return error.InvalidParam;

        switch (value) {
            .image => |i| {
                var sampler: vk.Sampler = undefined;

                if (param.value == null or !std.meta.eql(i.sampler, param.value.?.image.sampler_options)) {
                    sampler = self.device.createSampler(&vk.SamplerCreateInfo{
                        .min_filter = i.sampler.min_filter.asVk(),
                        .mag_filter = i.sampler.mag_filter.asVk(),
                        .address_mode_u = i.sampler.address_mode.u.asVk(),
                        .address_mode_v = i.sampler.address_mode.v.asVk(),
                        .address_mode_w = i.sampler.address_mode.w.asVk(),
                        .mipmap_mode = .nearest, // TODO: Implement Mipmaps
                        .mip_lod_bias = 0.0,
                        .anisotropy_enable = vk.FALSE, // TODO: What is this
                        .max_anisotropy = 0.0,
                        .compare_enable = vk.FALSE,
                        .compare_op = .equal,
                        .min_lod = 0.0,
                        .max_lod = 0.0,
                        .border_color = .int_opaque_black,
                        .unnormalized_coordinates = vk.FALSE,
                    }, null) catch return error.Failed;
                } else {
                    sampler = param.value.?.image.sampler;
                }

                param.value = .{ .image = .{ .sampler = sampler, .sampler_options = i.sampler, .rid = i.rid } };

                const image = i.rid.as(VulkanImage);

                const image_info: vk.DescriptorImageInfo = .{ .image_view = image.view, .sampler = sampler, .image_layout = i.layout.asVk() };
                const writes: []const vk.WriteDescriptorSet = &.{
                    vk.WriteDescriptorSet{
                        .dst_set = material.descriptor_set,
                        .dst_binding = @intCast(param.binding),
                        .dst_array_element = 0,
                        .descriptor_count = 1,
                        .descriptor_type = .combined_image_sampler,
                        .p_image_info = @ptrCast(&image_info),
                        .p_buffer_info = undefined,
                        .p_texel_buffer_view = undefined,
                    },
                };

                self.device.updateDescriptorSets(@intCast(writes.len), writes.ptr, 0, null);
            },
            .buffer => |b| {
                const buffer = b.as(VulkanBuffer);

                param.value = .{ .buffer = b };

                const buffer_info: vk.DescriptorBufferInfo = .{ .buffer = buffer.buffer, .offset = 0, .range = buffer.size };

                const writes: []const vk.WriteDescriptorSet = &.{
                    vk.WriteDescriptorSet{
                        .dst_set = material.descriptor_set,
                        .dst_binding = @intCast(param.binding),
                        .dst_array_element = 0,
                        .descriptor_count = 1,
                        .descriptor_type = .uniform_buffer,
                        .p_image_info = undefined,
                        .p_buffer_info = @ptrCast(&buffer_info),
                        .p_texel_buffer_view = undefined,
                    },
                };

                self.device.updateDescriptorSets(@intCast(writes.len), writes.ptr, 0, null);
            },
        }
    }

    //
    // Mesh
    //

    pub fn meshCreate(self: *VulkanRenderer, options: Renderer.MeshOptions) Renderer.MeshCreateError!RID {
        const index_buffer = try self.bufferCreate(.{ .size = options.indices.len, .usage = .{ .index_buffer = true, .transfer_dst = true } });
        const vertex_buffer = try self.bufferCreate(.{ .size = options.vertices.len, .usage = .{ .vertex_buffer = true, .transfer_dst = true } });
        const normal_buffer = try self.bufferCreate(.{ .size = options.normals.len, .usage = .{ .vertex_buffer = true, .transfer_dst = true } });
        const texture_coords_buffer = try self.bufferCreate(.{ .size = options.texture_coords.len, .usage = .{ .vertex_buffer = true, .transfer_dst = true } });

        self.bufferUpdate(index_buffer, options.indices, 0) catch return error.Failed;
        self.bufferUpdate(vertex_buffer, options.vertices, 0) catch return error.Failed;
        self.bufferUpdate(normal_buffer, options.normals, 0) catch return error.Failed;
        self.bufferUpdate(texture_coords_buffer, options.texture_coords, 0) catch return error.Failed;

        const rid: RID = .{ .inner = @intFromPtr(try createWithInit(VulkanMesh, self.allocator, .{
            .index_buffer = index_buffer,
            .vertex_buffer = vertex_buffer,
            .normal_buffer = normal_buffer,
            .texture_coords_buffer = texture_coords_buffer,
            .indices_count = options.indices.len / options.index_type.bytes(),
            .index_type = options.index_type.asVk(),
        })) };

        self.rid_infos_mutex.lock();
        defer self.rid_infos_mutex.unlock();

        try self.addRIDInfo(rid, @returnAddress());
        return rid;
    }

    pub fn meshGetIndicesCount(self: *VulkanRenderer, mesh_rid: RID) usize {
        _ = self;
        return mesh_rid.as(VulkanMesh).indices_count;
    }

    //
    // RenderPass
    //

    pub fn renderPassCreate(self: *VulkanRenderer, options: Renderer.RenderPassOptions) Renderer.RenderPassCreateError!RID {
        std.debug.assert(options.attachments.len <= 8);

        var color_refs: [4]vk.AttachmentReference = undefined;
        var color_ref_count: u32 = 0;
        var depth_refs: [4]vk.AttachmentReference = undefined;
        var depth_ref_count: u32 = 0;

        for (options.attachments, 0..options.attachments.len) |attach, index| {
            const attach_ref: vk.AttachmentReference = .{
                .attachment = @intCast(index),
                .layout = attach.layout.asVk(),
            };

            switch (attach.type) {
                .color => {
                    color_refs[color_ref_count] = attach_ref;
                    color_ref_count += 1;
                },
                .depth => {
                    depth_refs[depth_ref_count] = attach_ref;
                    depth_ref_count += 1;
                },
            }
        }

        const subpass: vk.SubpassDescription = .{
            .pipeline_bind_point = .graphics,
            .color_attachment_count = color_ref_count,
            .p_color_attachments = if (color_ref_count > 0) @ptrCast(&color_refs) else null,
            .p_depth_stencil_attachment = if (depth_ref_count > 0) @ptrCast(&depth_refs) else null,
        };

        var descriptions: [8]vk.AttachmentDescription = undefined;

        for (options.attachments, 0..options.attachments.len) |attach, index| {
            descriptions[index] = .{
                .format = attach.format.asVk(),
                .samples = .{ .@"1_bit" = true },
                .load_op = attach.load_op.asVk(),
                .store_op = attach.store_op.asVk(),
                .stencil_load_op = attach.stencil_load_op.asVk(),
                .stencil_store_op = attach.stencil_store_op.asVk(),
                .initial_layout = attach.initial_layout.asVk(),
                .final_layout = attach.final_layout.asVk(),
            };
        }

        var dependencies: []const vk.SubpassDependency = undefined;

        if (!options.transition_depth_layout) {
            dependencies = &.{
                .{
                    .src_subpass = vk.SUBPASS_EXTERNAL,
                    .dst_subpass = 0,
                    .src_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
                    .dst_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
                    .src_access_mask = .{},
                    .dst_access_mask = .{ .color_attachment_write_bit = true, .depth_stencil_attachment_write_bit = true },
                },
            };
        } else {
            dependencies = &.{
                .{
                    .src_subpass = vk.SUBPASS_EXTERNAL,
                    .dst_subpass = 0,
                    .src_stage_mask = .{ .fragment_shader_bit = true },
                    .dst_stage_mask = .{ .early_fragment_tests_bit = true },
                    .src_access_mask = .{ .shader_read_bit = true },
                    .dst_access_mask = .{ .depth_stencil_attachment_write_bit = true },
                    .dependency_flags = .{ .by_region_bit = true },
                },
                .{
                    .src_subpass = 0,
                    .dst_subpass = vk.SUBPASS_EXTERNAL,
                    .src_stage_mask = .{ .late_fragment_tests_bit = true },
                    .dst_stage_mask = .{ .fragment_shader_bit = true },
                    .src_access_mask = .{ .depth_stencil_attachment_write_bit = true },
                    .dst_access_mask = .{ .shader_read_bit = true },
                    .dependency_flags = .{ .by_region_bit = true },
                },
            };
        }

        const render_pass = self.device.createRenderPass(&vk.RenderPassCreateInfo{
            .attachment_count = @intCast(options.attachments.len),
            .p_attachments = &descriptions,
            .subpass_count = 1,
            .p_subpasses = @ptrCast(&subpass),
            .dependency_count = @intCast(dependencies.len),
            .p_dependencies = dependencies.ptr,
        }, null) catch return error.Failed;
        errdefer self.device.destroyRenderPass(render_pass, null);

        const rid: RID = .{ .inner = @intFromPtr(try createWithInit(VulkanRenderPass, self.allocator, .{
            .render_pass = render_pass,
            .attachments = try self.allocator.dupe(Renderer.Attachment, options.attachments),
        })) };

        self.rid_infos_mutex.lock();
        defer self.rid_infos_mutex.unlock();

        try self.addRIDInfo(rid, @returnAddress());
        return rid;
    }

    //
    // Framebuffer
    //

    pub fn framebufferCreate(self: *VulkanRenderer, options: Renderer.FramebufferOptions) Renderer.FramebufferCreateError!RID {
        const max_attachments = 4;

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

        const rid: RID = .{ .inner = @intFromPtr(try createWithInit(VulkanFramebuffer, self.allocator, .{
            .framebuffer = framebuffer,
        })) };

        self.rid_infos_mutex.lock();
        defer self.rid_infos_mutex.unlock();

        try self.addRIDInfo(rid, @returnAddress());
        return rid;
    }

    fn createShaderModule(self: *VulkanRenderer, spirv: [:0]align(4) const u8) vk.DeviceProxy.CreateShaderModuleError!vk.ShaderModule {
        return self.device.createShaderModule(&vk.ShaderModuleCreateInfo{
            .code_size = spirv.len,
            .p_code = @ptrCast(spirv.ptr),
        }, null);
    }

    pub fn createGraphicsPipeline(self: *VulkanRenderer, options: GraphicsPipelineOptions) error{ OutOfMemory, Failed, ShaderCompilationFailed }!Pipeline {
        var shader_stages: [4]vk.PipelineShaderStageCreateInfo = undefined;

        for (options.material.shaders, 0..options.material.shaders.len) |shader, index| {
            shader_stages[index] = .{
                .stage = shader.stage.asVk(),
                .module = self.createShaderModule(assets.getShaderData(shader.path)) catch return error.ShaderCompilationFailed,
                .p_name = "main",
            };
        }

        defer for (0..options.material.shaders.len) |index| self.device.destroyShaderModule(shader_stages[index].module, null);

        var input_bindings: std.ArrayList(vk.VertexInputBindingDescription) = try .initCapacity(self.allocator, if (options.material.instance_layout) |_| 4 else 3);
        defer input_bindings.deinit();

        var input_attribs: std.ArrayList(vk.VertexInputAttributeDescription) = try .initCapacity(self.allocator, if (options.material.instance_layout) |layout| 3 + layout.inputs.len else 3);
        defer input_attribs.deinit();

        // Vertex attributes
        input_bindings.appendAssumeCapacity(.{ .binding = 0, .stride = 3 * @sizeOf(f32), .input_rate = .vertex });
        input_bindings.appendAssumeCapacity(.{ .binding = 1, .stride = 3 * @sizeOf(f32), .input_rate = .vertex });
        input_bindings.appendAssumeCapacity(.{ .binding = 2, .stride = 2 * @sizeOf(f32), .input_rate = .vertex });

        input_attribs.appendAssumeCapacity(.{ .binding = 0, .location = 0, .format = .r32g32b32_sfloat, .offset = 0 });
        input_attribs.appendAssumeCapacity(.{ .binding = 1, .location = 1, .format = .r32g32b32_sfloat, .offset = 0 });
        input_attribs.appendAssumeCapacity(.{ .binding = 2, .location = 2, .format = .r32g32_sfloat, .offset = 0 });

        // Instance inputs
        if (options.material.instance_layout) |instance_layout| {
            input_bindings.appendAssumeCapacity(.{ .binding = 3, .stride = @intCast(instance_layout.stride), .input_rate = .instance });

            for (instance_layout.inputs, 0..instance_layout.inputs.len) |input, index| {
                input_attribs.appendAssumeCapacity(.{ .binding = 3, .location = 3 + @as(u32, @intCast(index)), .format = input.type.asVkFormat(), .offset = @intCast(input.offset) });
            }
        }

        const dynamic_states: []const vk.DynamicState = &.{ .viewport, .scissor };
        const dynamic_state_info: vk.PipelineDynamicStateCreateInfo = .{
            .dynamic_state_count = @intCast(dynamic_states.len),
            .p_dynamic_states = dynamic_states.ptr,
        };

        const vertex_input_info: vk.PipelineVertexInputStateCreateInfo = .{
            .vertex_binding_description_count = @intCast(input_bindings.items.len),
            .p_vertex_binding_descriptions = input_bindings.items.ptr,
            .vertex_attribute_description_count = @intCast(input_attribs.items.len),
            .p_vertex_attribute_descriptions = input_attribs.items.ptr,
        };

        const input_assembly_info: vk.PipelineInputAssemblyStateCreateInfo = .{
            .topology = options.material.topology,
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
            .polygon_mode = options.material.polygon_mode,
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

        const blend_state: vk.PipelineColorBlendAttachmentState = if (!options.material.transparency)
            .{
                .blend_enable = vk.FALSE,
                .src_color_blend_factor = .one,
                .dst_color_blend_factor = .zero,
                .color_blend_op = .add,
                .src_alpha_blend_factor = .one,
                .dst_alpha_blend_factor = .zero,
                .alpha_blend_op = .add,
                .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
            }
        else
            .{
                .blend_enable = vk.TRUE,
                .src_color_blend_factor = .src_alpha,
                .dst_color_blend_factor = .one_minus_src_alpha,
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

        // TODO: Probably should not hardcode push constant ranges. For now it can only store one mat4.
        // TODO: Move the pipeline layout in the material

        const push_constant_rages: []const vk.PushConstantRange = &.{
            .{ .offset = 0, .size = @sizeOf([16]f32), .stage_flags = .{ .vertex_bit = true } },
        };

        const layout = self.device.createPipelineLayout(&vk.PipelineLayoutCreateInfo{
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&options.material.descriptor_pool.descriptor_set_layout),
            .push_constant_range_count = @intCast(push_constant_rages.len),
            .p_push_constant_ranges = push_constant_rages.ptr,
        }, null) catch return error.Failed;

        var pipeline: vk.Pipeline = .null_handle;
        _ = self.device.createGraphicsPipelines(.null_handle, 1, @ptrCast(&vk.GraphicsPipelineCreateInfo{
            .stage_count = @intCast(options.material.shaders.len),
            .p_stages = &shader_stages,
            .p_vertex_input_state = &vertex_input_info,
            .p_input_assembly_state = &input_assembly_info,
            .p_viewport_state = &viewport_info,
            .p_rasterization_state = &rasterizer_info,
            .p_multisample_state = &multisample_info,
            .p_depth_stencil_state = &depth_info,
            .p_color_blend_state = &blend_info,
            .p_dynamic_state = &dynamic_state_info,
            .layout = layout,
            .render_pass = options.render_pass.as(VulkanRenderPass).render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        }), null, @ptrCast(&pipeline)) catch return error.Failed;
        errdefer self.device.destroyPipeline(pipeline, null);

        return .{
            .pipeline = pipeline,
            .layout = layout,
        };
    }

    fn allocMemoryForImage(self: *const VulkanRenderer, image: vk.Image, flags: vk.MemoryPropertyFlags) error{ InvalidParam, OutOfMemory, OutOfDeviceMemory }!vk.DeviceMemory {
        const memory_requirements: vk.MemoryRequirements = self.device.getImageMemoryRequirements(image);
        const device_memory = self.device.allocateMemory(&vk.MemoryAllocateInfo{
            .memory_type_index = self.findMemoryTypeIndex(memory_requirements.memory_type_bits, flags) orelse return error.InvalidParam,
            .allocation_size = memory_requirements.size,
        }, null) catch |e| switch (e) {
            error.OutOfHostMemory => return error.OutOfMemory,
            else => return error.OutOfDeviceMemory,
        };
        self.device.bindImageMemory(image, device_memory, 0) catch |e| switch (e) {
            error.OutOfHostMemory => return error.OutOfMemory,
            else => return error.OutOfDeviceMemory,
        };
        return device_memory;
    }

    fn allocMemoryForBuffer(self: *const VulkanRenderer, buffer: vk.Buffer, flags: vk.MemoryPropertyFlags) error{ InvalidParam, OutOfMemory, OutOfDeviceMemory }!vk.DeviceMemory {
        const memory_requirements: vk.MemoryRequirements = self.device.getBufferMemoryRequirements(buffer);
        const device_memory = self.device.allocateMemory(&vk.MemoryAllocateInfo{
            .memory_type_index = self.findMemoryTypeIndex(memory_requirements.memory_type_bits, flags) orelse return error.InvalidParam,
            .allocation_size = memory_requirements.size,
        }, null) catch |e| switch (e) {
            error.OutOfHostMemory => return error.OutOfMemory,
            else => return error.OutOfDeviceMemory,
        };
        self.device.bindBufferMemory(buffer, device_memory, 0) catch |e| switch (e) {
            error.OutOfHostMemory => return error.OutOfMemory,
            else => return error.OutOfDeviceMemory,
        };
        return device_memory;
    }

    /// Find the index of a memory types with all the required properties bits.
    fn findMemoryTypeIndex(self: *const VulkanRenderer, type_bits: u32, properties: vk.MemoryPropertyFlags) ?u32 {
        var bits = type_bits;

        for (0..@as(usize, @intCast(self.memory_properties.memory_type_count))) |i| {
            if ((bits & 1) == 1 and self.memory_properties.memory_types[i].property_flags.contains(properties)) {
                return @intCast(i);
            }

            bits >>= 1;
        }

        return null;
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
    memory: vk.DeviceMemory,

    pub fn deinit(self: *const VulkanBuffer, r: *VulkanRenderer) void {
        r.device.freeMemory(self.memory, null);
        r.device.destroyBuffer(self.buffer, null);
    }
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
    external_image: bool = false,
    view: vk.ImageView,
    memory: vk.DeviceMemory,

    layout: vk.ImageLayout,
    aspect_mask: vk.ImageAspectFlags,

    pub fn deinit(self: *const VulkanImage, r: *VulkanRenderer) void {
        r.device.destroyImageView(self.view, null);
        if (!self.external_image) {
            r.device.freeMemory(self.memory, null);
            r.device.destroyImage(self.image, null);
        }
    }
};

pub const VulkanPipeline = struct {
    pub const resource_signature: usize = @truncate(0x5789d7753bca202c);

    signature: usize = resource_signature,
    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,
    // descriptor_pool: DynamicDescriptorPool,
};

pub const VulkanRenderPass = struct {
    pub const resource_signature: usize = @truncate(0xb848438b714985aa);

    signature: usize = resource_signature,
    render_pass: vk.RenderPass,
    attachments: []const Renderer.Attachment,
};

pub const VulkanFramebuffer = struct {
    pub const resource_signature: usize = @truncate(0x264657ac2e68fd36);

    signature: usize = resource_signature,
    framebuffer: vk.Framebuffer,
};

const DynamicDescriptorPool = struct {
    pools: std.ArrayList(vk.DescriptorPool),
    count: usize,
    descriptor_set_layout: vk.DescriptorSetLayout,

    const pool_size: usize = 16;

    pub fn init(allocator: Allocator, params: []const Renderer.MaterialParameter) !DynamicDescriptorPool {
        var descriptor_bindings: std.ArrayList(vk.DescriptorSetLayoutBinding) = .init(allocator);
        defer descriptor_bindings.deinit();

        for (params, 0..params.len) |param, index| {
            try descriptor_bindings.append(.{ .binding = @intCast(index), .stage_flags = param.stage.asVk(), .descriptor_type = param.type.asVk(), .descriptor_count = 1, .p_immutable_samplers = null });
        }

        const descriptor_set_layout = try rdr().asVk().device.createDescriptorSetLayout(&vk.DescriptorSetLayoutCreateInfo{
            .binding_count = @intCast(descriptor_bindings.items.len),
            .p_bindings = descriptor_bindings.items.ptr,
        }, null);

        return .{
            .pools = .init(allocator),
            .count = 0,
            .descriptor_set_layout = descriptor_set_layout,
        };
    }

    pub fn deinit(self: *const DynamicDescriptorPool, r: *VulkanRenderer) void {
        for (self.pools.items) |pool| r.device.destroyDescriptorPool(pool, null);
        self.pools.deinit();
    }

    pub fn createDescriptorSet(self: *DynamicDescriptorPool) !vk.DescriptorSet {
        if (self.count >= self.pools.items.len * pool_size) {
            // Funnily enough, on linux it seems that it does not care about what we are giving it here, but it crash
            // with moltenvk if we don't correctly specify the pool size.
            const sizes: []const vk.DescriptorPoolSize = &.{
                .{ .type = .combined_image_sampler, .descriptor_count = pool_size },
                .{ .type = .uniform_buffer, .descriptor_count = pool_size },
            };
            const pool = try rdr().asVk().device.createDescriptorPool(&vk.DescriptorPoolCreateInfo{
                .flags = .{ .free_descriptor_set_bit = true },
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

pub const VulkanMaterial = struct {
    pub const resource_signature: usize = @truncate(0x53df5135a9cc62f3);

    pub const ParamCachedValue = union(Renderer.MaterialParameterValueType) {
        image: struct {
            sampler_options: Renderer.SamplerOptions,
            sampler: vk.Sampler,
            rid: RID,
        },
        buffer: RID,
    };

    pub const Param = struct {
        name: []const u8,
        binding: usize,
        type: Renderer.MaterialParameterValueType,
        value: ?ParamCachedValue = null,
    };

    signature: usize = resource_signature,
    descriptor_pool: DynamicDescriptorPool,
    descriptor_set: vk.DescriptorSet,
    descriptor_set_layout: vk.DescriptorSetLayout,

    shaders: []const Renderer.ShaderRef,
    instance_layout: ?Renderer.MaterialInstanceLayout,
    params: []Param,

    topology: vk.PrimitiveTopology,
    polygon_mode: vk.PolygonMode,
    cull_mode: vk.CullModeFlags,

    transparency: bool,

    pub fn deinit(self: *const VulkanMaterial, r: *VulkanRenderer) void {
        self.descriptor_pool.deinit(r);
        r.device.destroyDescriptorSetLayout(self.descriptor_set_layout, null);

        for (self.params) |param| {
            if (param.value) |value| switch (value) {
                .image => |i| {
                    r.device.destroySampler(i.sampler, null);
                },
                else => {},
            };
        }

        for (self.params) |param| r.allocator.free(param.name);
        r.allocator.free(self.params);
    }

    pub fn getParam(self: *const VulkanMaterial, name: []const u8) ?*Param {
        for (self.params) |*param| {
            if (std.mem.eql(u8, param.name, name)) return param;
        }
        return null;
    }
};

pub const VulkanMesh = struct {
    pub const resource_signature: usize = @truncate(0x3cfa6bf786e88701);

    signature: usize = resource_signature,

    index_buffer: RID,
    vertex_buffer: RID,
    normal_buffer: RID,
    texture_coords_buffer: RID,

    indices_count: usize,
    index_type: vk.IndexType,

    pub fn deinit(self: *const VulkanMesh, r: *VulkanRenderer) void {
        r.freeRid(self.index_buffer);
        r.freeRid(self.vertex_buffer);
        r.freeRid(self.normal_buffer);
        r.freeRid(self.texture_coords_buffer);
    }
};

pub const GraphicsPipelineOptions = struct {
    render_pass: RID,
    transparency: bool,
    material: *VulkanMaterial,
};

const Pipeline = struct {
    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,

    pub fn deinit(self: *const Pipeline, r: *VulkanRenderer) void {
        r.device.destroyPipelineLayout(self.layout, null);
        r.device.destroyPipeline(self.pipeline, null);
    }
};

const PipelineKey = struct {
    name_hash: usize,
    transparency: bool,
    render_pass: RID,
};

const PipelineCache = struct {
    pipelines: std.AutoArrayHashMapUnmanaged(PipelineKey, Pipeline) = .empty,

    pub fn deinit(self: *PipelineCache, r: *VulkanRenderer) void {
        for (self.pipelines.values()) |pipeline| pipeline.deinit(r);

        self.pipelines.deinit(r.allocator);
    }

    pub fn getOrCreate(self: *PipelineCache, r: *VulkanRenderer, options: GraphicsPipelineOptions) error{ Failed, OutOfMemory, ShaderCompilationFailed }!Pipeline {
        var hasher = std.hash.Wyhash.init(0);

        for (options.material.shaders) |shader| hasher.update(shader.path);

        const key: PipelineKey = .{
            .name_hash = @truncate(hasher.final()),
            .render_pass = options.render_pass,
            .transparency = options.transparency,
        };

        if (self.pipelines.get(key)) |pipeline| {
            return pipeline;
        } else {
            const pipeline = try r.createGraphicsPipeline(options);
            try self.pipelines.put(r.allocator, key, pipeline);
            return pipeline;
        }
    }
};

const allocation_callbacks: vk.AllocationCallbacks = .{
    .p_user_data = null,
    .pfn_allocation = @ptrCast(&vkAllocate),
    .pfn_reallocation = @ptrCast(&vkReallocate),
    .pfn_free = @ptrCast(&vkFree),
};

fn vkAllocate(user_data: ?*anyopaque, size: usize, alignment: usize, allocation_scope: vk.SystemAllocationScope) callconv(vk.vulkan_call_conv) ?*anyopaque {
    _ = user_data;
    _ = alignment;
    _ = allocation_scope;

    if (size == 0) return null;

    const allocator: Allocator = @import("root").allocator;
    const slice = allocator.alignedAlloc(u8, 8, size) catch return null;

    return @ptrCast(slice.ptr);
}

fn vkReallocate(user_data: ?*anyopaque, original: ?*anyopaque, size: usize, alignment: usize, allocation_scope: vk.SystemAllocationScope) callconv(vk.vulkan_call_conv) ?*anyopaque {
    _ = user_data;
    _ = alignment;
    _ = allocation_scope;

    const allocator: Allocator = @import("root").allocator;
    const original_slice: []u8 = @as([*]u8, @ptrCast(original orelse unreachable))[0..0];
    const slice = allocator.realloc(original_slice, size) catch return null;
    return @ptrCast(slice.ptr);
}

fn vkFree(user_data: ?*anyopaque, memory: ?*anyopaque) callconv(vk.vulkan_call_conv) void {
    _ = user_data;

    const allocator: Allocator = @import("root").allocator;
    const memory_slice: []u8 = @as([*]u8, @ptrCast(memory orelse unreachable))[0..0];

    allocator.free(memory_slice);
}

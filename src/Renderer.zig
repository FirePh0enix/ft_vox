const std = @import("std");
const vk = @import("vulkan");
const sdl = @import("sdl");
const builtin = @import("builtin");

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
graphics_queue: Queue,
present_queue: Queue,
surface: vk.SurfaceKHR,
swapchain: vk.SwapchainKHR,
swapchain_images: []vk.Image,
swapchain_image_views: []vk.ImageView,
swapchain_extent: vk.Extent2D,

var instance_wrapper: vk.InstanceWrapper(apis) = undefined;
var device_wrapper: vk.DeviceWrapper(apis) = undefined;

pub const InitError = error{
    /// No suitable device found to run the app.
    NoDevice,
    NoGraphicsQueue,
};

pub fn init(
    allocator: std.mem.Allocator,
    window: *sdl.SDL_Window,
    get_proc_addr: *const GetInstanceProcAddrFn,
    instance_extensions: ?[*]const ?[*:0]const u8,
    instance_extensions_count: u32,
) !Self {
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

    // Select the best physical device.
    const physical_devices = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(physical_devices);

    const physical_device = getBestDevice(instance, physical_devices) orelse return InitError.NoDevice;
    const device_properties = instance.getPhysicalDeviceProperties(physical_device);

    std.log.info("GPU selected: {s}", .{device_properties.device_name});

    // Create the surface
    var sdl_surface: sdl.VkSurfaceKHR = undefined;
    const sdl_instance: sdl.VkInstance = @ptrFromInt(@as(usize, @intFromEnum(instance.handle)));
    _ = sdl.SDL_Vulkan_CreateSurface(window, sdl_instance, null, &sdl_surface);
    const surface: vk.SurfaceKHR = @enumFromInt(@as(usize, @intFromPtr(sdl_surface)));

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

    const extensions: []const [*:0]const u8 = &.{
        vk.extensions.khr_swapchain.name.ptr,
    };

    const device_features: vk.PhysicalDeviceFeatures = .{};

    const device_info: vk.DeviceCreateInfo = .{
        .queue_create_info_count = @intCast(queue_infos.len),
        .p_queue_create_infos = queue_infos.ptr,
        .enabled_layer_count = if (builtin.mode == .Debug) 1 else 0,
        .pp_enabled_layer_names = if (builtin.mode == .Debug) &.{"VK_LAYER_KHRONOS_validation"} else null,
        .enabled_extension_count = @intCast(extensions.len),
        .pp_enabled_extension_names = extensions.ptr,
        .p_enabled_features = &device_features,
    };

    const device_proc_addr: *const GetDeviceProcAddrFn = @ptrCast(instance_wrapper.dispatch.vkGetDeviceProcAddr);

    const device_handle = try instance.createDevice(physical_device, &device_info, null);
    device_wrapper = try .load(device_handle, device_proc_addr);

    const device = Device.init(device_handle, &device_wrapper);
    const graphics_queue = device.getDeviceQueue(graphics_queue_index, 0);
    const present_queue = device.getDeviceQueue(present_queue_index, 0);

    std.debug.assert(graphics_queue != .null_handle);
    std.debug.assert(present_queue != .null_handle);

    // Create the swapchain
    const surface_capabilities = try instance.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface);
    const surface_formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(physical_device, surface, allocator);
    defer allocator.free(surface_formats);

    const surface_present_modes = try instance.getPhysicalDeviceSurfacePresentModesAllocKHR(physical_device, surface, allocator);
    defer allocator.free(surface_present_modes);

    const surface_format: vk.SurfaceFormatKHR = .{ .color_space = .srgb_nonlinear_khr, .format = .b8g8r8a8_srgb };
    const surface_present_mode: vk.PresentModeKHR = .fifo_khr;

    var width: i32 = undefined;
    var height: i32 = undefined;
    _ = sdl.SDL_GetWindowSize(window, &width, &height);

    const surface_extent: vk.Extent2D = .{
        .width = @intCast(@max(surface_capabilities.min_image_extent.width, @as(u32, @intCast(width)))),
        .height = @intCast(@max(surface_capabilities.min_image_extent.height, @as(u32, @intCast(height)))),
    };

    const image_count = if (surface_capabilities.max_image_count > 0 and surface_capabilities.min_image_count + 1 > surface_capabilities.max_image_count)
        surface_capabilities.max_image_count
    else
        surface_capabilities.min_image_count + 1;

    var swapchain_info: vk.SwapchainCreateInfoKHR = .{
        .surface = surface,
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
        .old_swapchain = .null_handle,
    };

    const queue_indices: []const u32 = &.{ graphics_queue_index, present_queue_index };

    if (present_queue_index != graphics_queue_index) {
        swapchain_info.image_sharing_mode = .concurrent;
        swapchain_info.queue_family_index_count = @intCast(queue_indices.len);
        swapchain_info.p_queue_family_indices = queue_indices.ptr;
    }

    const swapchain = try device.createSwapchainKHR(&swapchain_info, null);
    const swapchain_images = try device.getSwapchainImagesAllocKHR(swapchain, allocator);
    const swapchain_image_views = try allocator.alloc(vk.ImageView, swapchain_images.len);

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

        swapchain_image_views[index] = try device.createImageView(&image_view_info, null);
    }

    return Self{
        .allocator = allocator,
        .instance = instance,
        .device = device,
        .graphics_queue = Queue.init(graphics_queue, &device_wrapper),
        .present_queue = Queue.init(graphics_queue, &device_wrapper),
        .surface = surface,
        .swapchain = swapchain,
        .swapchain_images = swapchain_images,
        .swapchain_extent = surface_extent,
        .swapchain_image_views = swapchain_image_views,
    };
}

pub fn deinit(self: *const Self) void {
    _ = self;

    // self.allocator.free(self.swapchain_image_views);
    // self.allocator.free(self.swapchain_images);

    // TODO
    // self.device.destroyDevice(null);
    // self.instance.destroyInstance(null);
}

fn calculateDeviceScore(properties: vk.PhysicalDeviceProperties) i32 {
    var score: i32 = 0;

    switch (properties.device_type) {
        .discrete_gpu => score += 1000,
        .virtual_gpu => score += 100,
        .integrated_gpu => score += 10,
        else => {},
    }

    return score;
}

fn getBestDevice(instance: Instance, devices: []const vk.PhysicalDevice) ?vk.PhysicalDevice {
    var best_device: ?vk.PhysicalDevice = null;
    var max_score: i32 = -1;

    for (devices) |device| {
        const properties = instance.getPhysicalDeviceProperties(device);
        const score = calculateDeviceScore(properties);

        if (score > max_score) {
            max_score = score;
            best_device = device;
        }
    }

    return best_device;
}

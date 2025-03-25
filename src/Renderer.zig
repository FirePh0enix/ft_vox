const std = @import("std");
const vk = @import("vulkan");
const sdl = @import("sdl");
const builtin = @import("builtin");
const root = @import("root");

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
swapchain_extent: vk.Extent2D = .{ .width = 0, .height = 0 },

graphics_queue_index: u32,
graphics_queue: Queue,
present_queue_index: u32,
present_queue: Queue,

features: Features,

pub const Features = struct {
    ray_tracing: bool = false,
};

pub const InitError = error{
    /// No suitable device found to run the app.
    NoDevice,

    /// Missing Graphics or Present Queue.
    NoGraphicsQueue,
};

var instance_wrapper: vk.InstanceWrapper(apis) = undefined;
var device_wrapper: vk.DeviceWrapper(apis) = undefined;

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
        .window = window,
        .features = features,
    };

    try self.createSwapchain();

    return self;
}

pub fn deinit(self: *const Self) void {
    _ = self;

    // TODO
    // self.allocator.free(self.swapchain_image_views);
    // self.allocator.free(self.swapchain_images);

    // self.device.destroyDevice(&vk_allocation_callbacks);
    // self.instance.destroyInstance(&vk_allocation_callbacks);
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

    const swapchain_images = try self.device.getSwapchainImagesAllocKHR(swapchain, self.allocator);
    errdefer self.allocator.free(swapchain_images);

    const swapchain_image_views = try self.allocator.alloc(vk.ImageView, swapchain_images.len);
    errdefer self.allocator.free(swapchain_image_views);

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

        swapchain_image_views[index] = try self.device.createImageView(&image_view_info, null);
    }

    self.destroySwapchain();

    self.swapchain = swapchain;
    self.swapchain_images = swapchain_images;
    self.swapchain_image_views = swapchain_image_views;
}

fn destroySwapchain(self: *const Self) void {
    for (self.swapchain_image_views) |image_view| {
        self.device.destroyImageView(image_view, null);
    }

    self.allocator.free(self.swapchain_images);
    self.allocator.free(self.swapchain_image_views);

    self.device.destroySwapchainKHR(self.swapchain, null);
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

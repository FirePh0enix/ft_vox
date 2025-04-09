const std = @import("std");
const builtin = @import("builtin");

const Self = @This();
const Allocator = std.mem.Allocator;
const Graph = @import("Graph.zig");
const Device = @import("Device.zig");
const Window = @import("Window.zig");
const Image = @import("Image.zig");
const Buffer = @import("Buffer.zig");

const zigimg = @import("zigimg");

const vk = @import("vulkan");
const VulkanRenderer = @import("vulkan.zig").VulkanRenderer;

ptr: *anyopaque,
vtable: *const VTable,

pub const Driver = enum {
    vulkan,
};

pub const VSync = enum {
    off,
    performance,
    smooth,
    efficient,
};

pub const CreateDeviceError = error{
    /// No device are suitable to run the engine.
    NoSuitableDevice,
} || Allocator.Error;

pub const CreateSwapchainError = error{
    Unknown,
} || Allocator.Error;

pub const SwapchainOptions = struct {
    vsync: VSync,
};

pub const ProcessGraphError = error{} || Allocator.Error;

pub const CreateBufferError = error{
    Fail,
} || Allocator.Error;

pub const BufferUsage = enum {
    gpu_only,
    cpu_to_gpu,
};

// Flags are lifted from `vk.BufferUsageFlags`.
pub const BufferUsageFlags = packed struct {
    transfer_src: bool = false,
    transfer_dst: bool = false,
    uniform_buffer: bool = false,
    index_buffer: bool = false,
    vertex_buffer: bool = false,
};

pub const CreateImageError = error{
    AllocationFailed,
} || Allocator.Error;

pub const ImageTiling = enum {
    optimal,
    linear,

    pub fn asVk(self: ImageTiling) vk.ImageTiling {
        switch (self) {
            .optimal => return .optimal,
            .linear => return .linear,
        }
    }
};

pub const Format = enum {
    r8_srgb,
    r8g8b8a8_srgb,
    b8g8r8a8_srgb,
    d32_sfloat,

    pub fn asVk(self: Format) vk.Format {
        switch (self) {
            .r8_srgb => return .r8_srgb,
            .r8g8b8a8_srgb => return .r8g8b8a8_srgb,
            .b8g8r8a8_srgb => return .b8g8r8a8_srgb,
            .d32_sfloat => return .d32_sfloat,
        }
    }
};

pub const PixelMapping = enum {
    identity,
    grayscale,
};

pub const ImageUsageFlags = packed struct {
    transfer_src: bool = false,
    transfer_dst: bool = false,
    sampled: bool = false,
    color_attachment: bool = false,
    depth_stencil_attachment: bool = false,

    pub fn asVk(self: ImageUsageFlags) vk.ImageUsageFlags {
        return .{
            .transfer_src_bit = self.transfer_src,
            .transfer_dst_bit = self.transfer_dst,
            .sampled_bit = self.sampled,
            .color_attachment_bit = self.color_attachment,
            .depth_stencil_attachment_bit = self.depth_stencil_attachment,
        };
    }
};

pub const ImageAspectFlags = packed struct {
    color: bool = false,
    depth: bool = false,

    pub fn asVk(self: ImageAspectFlags) vk.ImageAspectFlags {
        return .{
            .color_bit = self.color,
            .depth_bit = self.depth,
        };
    }
};

pub const VTable = struct {
    /// Initialize the driver and create the rendering device. If `index` is not null then the driver will try to use it, otherwise the most
    /// suitable device will be selected.
    create_device: *const fn (self: *anyopaque, window: *const Window, index: ?usize) CreateDeviceError!void,

    /// Shutdown the driver, freeing all related resources.
    shutdown: *const fn (self: *anyopaque) void,

    /// Create or recreate the swapchain.
    ///
    /// The swapchain will be invalidated and must be recreated when:
    /// - The window is resized
    /// - Enabling or disabling V-Sync
    create_swapchain: *const fn (self: *anyopaque, window: *const Window, options: SwapchainOptions) CreateSwapchainError!void,

    /// Process a render graph, displaying an image to the window at the end.
    process_graph: *const fn (self: *anyopaque, graph: *const Graph) ProcessGraphError!void,

    /// Return the currently used device.
    // get_current_device: *const fn (self: *anyopaque) Device,

    /// Create a buffer given its size and usage.
    create_buffer: *const fn (self: *anyopaque, size: usize, usage: BufferUsage, flags: BufferUsageFlags) CreateBufferError!Buffer,

    /// Create an image given its dimensions and usage.
    create_image: *const fn (self: *anyopaque, width: usize, height: usize, layers: usize, tiling: ImageTiling, format: Format, usage: ImageUsageFlags, aspect_mask: ImageAspectFlags, mapping: PixelMapping) CreateImageError!Image,
};

pub const CreateError = error{} || Allocator.Error;

var singleton: Self = undefined;

pub fn rdr() *Self {
    return &singleton;
}

pub fn create(allocator: Allocator, driver: Driver) CreateError!void {
    _ = driver; // We only have `vulkan` for now.
    const renderer = try VulkanRenderer.create(allocator);
    singleton = .{
        .ptr = renderer,
        .vtable = &VulkanRenderer.vtable,
    };
}

pub fn deinit(self: *const Self) void {
    self.vtable.shutdown(self.ptr);
}

pub fn asVk(self: *const Self) *VulkanRenderer {
    return @ptrCast(@alignCast(self.ptr));
}

pub fn createDevice(self: *Self, window: *const Window, index: ?usize) CreateDeviceError!void {
    return self.vtable.create_device(self.ptr, window, index);
}

pub fn createSwapchain(self: *Self, window: *const Window, options: SwapchainOptions) CreateSwapchainError!void {
    return self.vtable.create_swapchain(self.ptr, window, options);
}

pub fn processGraph(self: *Self, graph: *const Graph) ProcessGraphError!void {
    return self.vtable.process_graph(self.ptr, graph);
}

pub fn getCurrentDevice(self: *Self) Device {
    return self.vtable.get_current_device(self.ptr);
}

pub fn createBuffer(self: *Self, size: usize, usage: BufferUsage, flags: BufferUsageFlags) CreateBufferError!Buffer {
    return self.vtable.create_buffer(self.ptr, size, usage, flags);
}

pub fn createBufferFromData(
    self: *Self,
    comptime T: type,
    data: []const T,
    usage: BufferUsage,
    flags: BufferUsageFlags,
) CreateBufferError!Buffer {
    var buffer = try self.createBuffer(@sizeOf(T) * data.len, usage, flags);
    try buffer.update(std.mem.sliceAsBytes(data));
    return buffer;
}

pub fn createImage(
    self: *Self,
    width: usize,
    height: usize,
    layers: usize,
    tiling: ImageTiling,
    format: Format,
    usage: ImageUsageFlags,
    aspect_mask: ImageAspectFlags,
    mapping: PixelMapping,
) CreateImageError!Image {
    return self.vtable.create_image(self.ptr, width, height, layers, tiling, format, usage, aspect_mask, mapping);
}

pub fn createImageFromFile(
    self: *Self,
    allocator: Allocator,
    path: []const u8,
) (CreateImageError || Image.UpdateError)!Image {
    var image_data = try zigimg.Image.fromFilePath(allocator, path);
    defer image_data.deinit();

    const format: Format = .r8g8b8a8_srgb; // TODO: Select the correct image format.
    var image = try self.createImage(image_data.width, image_data.height, 1, .optimal, format, .{ .sampled = true, .transfer_dst = true }, .{ .color = true }, .identity);

    image.asVk().transferLayout(.undefined, .transfer_dst_optimal, .{ .color_bit = true }) catch unreachable;
    try image.update(0, image_data.rawBytes());
    image.asVk().transferLayout(.transfer_dst_optimal, .shader_read_only_optimal, .{ .color_bit = true }) catch unreachable;

    return image;
}

pub fn createDepthImage(
    self: *Self,
    width: usize,
    height: usize,
) CreateImageError!Image {
    const depth_format: Format = .d32_sfloat; // TODO: Check support for depth format.

    var image = try self.createImage(width, height, 1, .optimal, depth_format, .{ .depth_stencil_attachment = true }, .{ .depth = true }, .identity);
    image.asVk().transferLayout(.undefined, .depth_stencil_attachment_optimal, .{ .depth_bit = true }) catch unreachable;

    return image;
}

const std = @import("std");
const sdl = @import("sdl");
const builtin = @import("builtin");
const vma = @import("vma");
const zm = @import("zmath");
const wgpu = @import("webgpu");
const zigimg = @import("zigimg");

const Allocator = std.mem.Allocator;
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

pub const WebGPURenderer = struct {
    const Self = @This();

    allocator: Allocator,
    instance: wgpu.Instance,

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

    pub fn create(allocator: Allocator) Allocator.Error!*Self {
        const driver = try allocator.create(WebGPURenderer);
        driver.allocator = allocator;

        return driver;
    }

    pub fn createDevice(
        self: *Self,
        window: *Window,
    ) Renderer.CreateDeviceError!void {
        self.instance = wgpu.createInstance(null);
        self.instance.createSurface(&wgpu.SurfaceDescriptor{});
    }
};

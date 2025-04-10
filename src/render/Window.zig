const std = @import("std");
const sdl = @import("sdl");

const Self = @This();
const Driver = @import("Renderer.zig").Driver;

handle: *sdl.SDL_Window,

pub const Options = struct {
    title: [:0]const u8,
    width: usize,
    height: usize,
    driver: Driver,
    resizable: bool = false,
};

pub fn create(options: Options) !Self {
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_EVENTS)) {
        return error.NoWindow;
    }

    var window_flags: sdl.SDL_WindowFlags = 0;

    if (options.resizable) window_flags |= sdl.SDL_WINDOW_RESIZABLE;

    switch (options.driver) {
        .vulkan => window_flags |= sdl.SDL_WINDOW_VULKAN,
    }

    const window = sdl.SDL_CreateWindow(options.title.ptr, @intCast(options.width), @intCast(options.height), window_flags);

    return .{
        .handle = window orelse return error.NoWindow,
    };
}

pub fn deinit(self: *const Self) void {
    sdl.SDL_DestroyWindow(self.handle);
    sdl.SDL_Quit();
}

pub fn size(self: *const Self) struct { width: usize, height: usize } {
    var width: c_int = undefined;
    var height: c_int = undefined;

    _ = sdl.SDL_GetWindowSize(self.handle, &width, &height);

    return .{
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

// Vulkan specific stuff

const vk = @import("vulkan");

// TODO: Don't use `*c` here.
pub fn getVkInstanceExtensions(self: *const Self) []const [*c]const u8 {
    _ = self;
    var count: sdl.Uint32 = undefined;
    const extensions = sdl.SDL_Vulkan_GetInstanceExtensions(&count);
    return extensions[0..@as(usize, @intCast(count))];
}

pub fn getVkGetInstanceProcAddr(self: *const Self) *const fn () callconv(.c) void {
    _ = self;
    return sdl.SDL_Vulkan_GetVkGetInstanceProcAddr() orelse unreachable;
}

pub fn createVkSurface(self: *const Self, instance: vk.Instance) vk.SurfaceKHR {
    var surface: sdl.VkSurfaceKHR = undefined;
    _ = sdl.SDL_Vulkan_CreateSurface(self.handle, @ptrFromInt(@intFromEnum(instance)), null, &surface); // TODO: Check errors
    return @enumFromInt(@intFromPtr(surface));
}

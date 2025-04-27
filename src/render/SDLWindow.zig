const std = @import("std");
const sdl = @import("sdl");

const Self = @This();
const Window = @import("Window.zig");
const Event = Window.Event;
const Options = Window.Options;

handle: *sdl.SDL_Window,

pub fn create(options: Options) !Self {
    const init_flags: sdl.SDL_InitFlags = sdl.SDL_INIT_EVENTS | sdl.SDL_INIT_VIDEO;

    if (!sdl.SDL_Init(init_flags)) {
        return error.NoWindow;
    }

    var window_flags: sdl.SDL_WindowFlags = 0;

    if (options.resizable) window_flags |= sdl.SDL_WINDOW_RESIZABLE;

    switch (options.driver) {
        .vulkan => window_flags |= sdl.SDL_WINDOW_VULKAN,
    }

    const window = sdl.SDL_CreateWindow(options.title.ptr, @intCast(options.width orelse 1280), @intCast(options.height orelse 720), window_flags);

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

fn convertEvent(event: sdl.SDL_Event) Event {
    switch (event.type) {
        sdl.SDL_EVENT_KEY_DOWN => .{ .key = .{ .state = .down, .key = event.key.key, .repeat = event.key.repeat } },
        sdl.SDL_EVENT_KEY_UP => .{ .key = .{ .state = .down, .key = event.key.key, .repeat = event.key.repeat } },
        else => .unknown,
    }
}

pub fn pollEvent(self: *const Self) ?Event {
    _ = self;

    var event: sdl.SDL_Event = undefined;
    if (sdl.SDL_PollEvent(&event)) {
        return convertEvent(event);
    } else {
        return null;
    }
}

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

pub fn createVkSurface(self: *const Self, instance: vk.Instance, callbacks: ?*const vk.AllocationCallbacks) vk.SurfaceKHR {
    var surface: sdl.VkSurfaceKHR = undefined;
    _ = sdl.SDL_Vulkan_CreateSurface(self.handle, @ptrFromInt(@intFromEnum(instance)), @ptrCast(callbacks), &surface); // TODO: Check errors
    return @enumFromInt(@intFromPtr(surface));
}

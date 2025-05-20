const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

const Self = @This();
const Window = @import("../Window.zig");
const Event = Window.Event;
const Options = Window.Options;

handle: *c.SDL_Window,
is_running: bool,

pub fn create(options: Options) !Self {
    const init_flags: c.SDL_InitFlags = c.SDL_INIT_EVENTS | c.SDL_INIT_VIDEO;

    if (!c.SDL_Init(init_flags)) {
        return error.NoWindow;
    }

    var window_flags: c.SDL_WindowFlags = 0;

    if (options.resizable) window_flags |= c.SDL_WINDOW_RESIZABLE;

    if (builtin.os.tag != .emscripten) {
        switch (options.driver) {
            .vulkan => window_flags |= c.SDL_WINDOW_VULKAN,
        }
    } else {
        switch (options.driver) {
            .gles => window_flags |= c.SDL_WINDOW_OPENGL,
        }
    }

    const window = c.SDL_CreateWindow(options.title.ptr, @intCast(options.width orelse 1280), @intCast(options.height orelse 720), window_flags);

    return .{
        .handle = window orelse return error.NoWindow,
        .is_running = true,
    };
}

pub fn deinit(self: *const Self) void {
    c.SDL_DestroyWindow(self.handle);
    c.SDL_Vulkan_UnloadLibrary();
    c.SDL_Quit();
}

pub fn size(self: *const Self) struct { width: usize, height: usize } {
    var width: c_int = undefined;
    var height: c_int = undefined;

    _ = c.SDL_GetWindowSize(self.handle, &width, &height);

    return .{
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

fn convertEvent(self: *const Self, event: c.SDL_Event) Event {
    return switch (event.type) {
        c.SDL_EVENT_KEY_DOWN => .{ .key = .{ .state = .down, .key = event.key.key, .repeat = event.key.repeat } },
        c.SDL_EVENT_KEY_UP => .{ .key = .{ .state = .up, .key = event.key.key, .repeat = event.key.repeat } },

        c.SDL_EVENT_MOUSE_BUTTON_DOWN => .{ .button = .{ .state = .down, .button = @intCast(event.button.button) } },
        c.SDL_EVENT_MOUSE_BUTTON_UP => .{ .button = .{ .state = .up, .button = @intCast(event.button.button) } },

        c.SDL_EVENT_MOUSE_MOTION => .{ .motion = .{ .x_relative = event.motion.xrel, .y_relative = event.motion.yrel } },

        c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => .{ .close = {} },

        c.SDL_EVENT_WINDOW_RESIZED => a: {
            const s = self.size();
            break :a .{ .resized = .{ .width = s.width, .height = s.height } };
        },

        else => .{ .unknown = {} },
    };
}

pub fn pollEvent(self: *const Self) ?Event {
    var event: c.SDL_Event = undefined;
    if (c.SDL_PollEvent(&event)) {
        return self.convertEvent(event);
    } else {
        return null;
    }
}

pub fn close(self: *Self) void {
    self.is_running = false;
}

pub fn running(self: *const Self) bool {
    return self.is_running;
}

pub fn setFullscreen(self: *Self, f: bool) void {
    _ = c.SDL_SetWindowFullscreen(self.handle, f);
}

const vk = @import("vulkan");

// TODO: Don't use `*c` here.
pub fn getVkInstanceExtensions(self: *const Self) []const [*c]const u8 {
    _ = self;
    var count: c.Uint32 = undefined;
    const extensions = c.SDL_Vulkan_GetInstanceExtensions(&count);
    return extensions[0..@as(usize, @intCast(count))];
}

pub fn getVkGetInstanceProcAddr(self: *const Self) *const fn () callconv(.c) void {
    _ = self;
    return c.SDL_Vulkan_GetVkGetInstanceProcAddr() orelse unreachable;
}

pub fn createVkSurface(self: *const Self, instance: vk.Instance, callbacks: ?*const vk.AllocationCallbacks) vk.SurfaceKHR {
    var surface: c.VkSurfaceKHR = undefined;
    _ = c.SDL_Vulkan_CreateSurface(self.handle, @ptrFromInt(@intFromEnum(instance)), @ptrCast(callbacks), &surface); // TODO: Check errors
    return @enumFromInt(@intFromPtr(surface));
}

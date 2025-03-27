const std = @import("std");
const vk = @import("vulkan");
const sdl = @import("sdl");
const builtin = @import("builtin");

const Renderer = @import("render/Renderer.zig");
const Mesh = @import("Mesh.zig");
const Image = @import("render/Image.zig");
const Material = @import("Material.zig");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub const allocator: std.mem.Allocator = if (builtin.mode == .Debug)
    debug_allocator.allocator()
else
    std.heap.smp_allocator;

pub fn main() !void {
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_EVENTS)) {
        std.log.err("SDL init failed", .{});
        return;
    }
    // defer sdl.SDL_Quit();

    const window = sdl.SDL_CreateWindow("ft_vox", 1280, 720, sdl.SDL_WINDOW_VULKAN | sdl.SDL_WINDOW_HIDDEN) orelse {
        std.log.err("Create window failed", .{});
        return;
    };
    defer sdl.SDL_DestroyWindow(window);

    var instance_extensions_count: u32 = undefined;
    const instance_extensions = sdl.SDL_Vulkan_GetInstanceExtensions(&instance_extensions_count);

    Renderer.init(allocator, window, @ptrCast(sdl.SDL_Vulkan_GetVkGetInstanceProcAddr() orelse unreachable), instance_extensions, instance_extensions_count) catch |e| {
        std.log.err("Failed to initialize vulkan", .{});
        return e;
    };
    // defer Renderer.singleton.deinit();

    _ = sdl.SDL_ShowWindow(window);

    var running = true;

    const mesh = try Mesh.init(u16, &.{
        0, 1, 2,
        0, 2, 3,
    }, &.{
        .{ -0.5, -0.5, 0.0 },
        .{ 0.5, -0.5, 0.0 },
        .{ 0.5, 0.5, 0.0 },
        .{ -0.5, 0.5, 0.0 },
    }, &.{
        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 1.0, 1.0 },
        .{ 0.0, 1.0 },
    });

    const image = try Image.createFromFile(allocator, "assets/textures/None.png");
    const material = try Material.init(image, Renderer.singleton.basic_pipeline);

    while (running) {
        var event: sdl.SDL_Event = undefined;

        while (sdl.SDL_PollEvent(&event)) {
            if (event.type == sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED) {
                running = false;
            }
        }

        try Renderer.singleton.draw(mesh, material);
    }

    // if (@import("builtin").mode == .Debug) _ = debug_allocator.detectLeaks();
}

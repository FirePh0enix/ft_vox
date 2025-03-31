const std = @import("std");
const vk = @import("vulkan");
const sdl = @import("sdl");
const builtin = @import("builtin");
const console = @import("console.zig");

const Renderer = @import("render/Renderer.zig");
const Mesh = @import("Mesh.zig");
const Image = @import("render/Image.zig");
const Material = @import("Material.zig");
const GraphicsPipeline = @import("render/GraphicsPipeline.zig");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub const allocator: std.mem.Allocator = if (builtin.mode == .Debug)
    debug_allocator.allocator()
else
    std.heap.smp_allocator;

// export VK_LAYER_MESSAGE_ID_FILTER=UNASSIGNED-CoreValidation-DrawState-QueryNotReset

pub fn main() !void {
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_EVENTS)) {
        std.log.err("SDL init failed", .{});
        return;
    }
    // defer sdl.SDL_Quit();

    const window = sdl.SDL_CreateWindow("ft_vox", 1280, 720, sdl.SDL_WINDOW_VULKAN | sdl.SDL_WINDOW_HIDDEN | sdl.SDL_WINDOW_RESIZABLE) orelse {
        std.log.err("Create window failed", .{});
        return;
    };
    defer sdl.SDL_DestroyWindow(window);

    var instance_extensions_count: u32 = undefined;
    const instance_extensions = sdl.SDL_Vulkan_GetInstanceExtensions(&instance_extensions_count);

    Renderer.init(allocator, window, @ptrCast(sdl.SDL_Vulkan_GetVkGetInstanceProcAddr() orelse unreachable), instance_extensions, instance_extensions_count, .{ .vsync = .performance }) catch |e| {
        std.log.err("Failed to initialize vulkan", .{});
        return e;
    };
    // defer Renderer.singleton.deinit();

    _ = sdl.SDL_ShowWindow(window);

    var running = true;
    var fullscreen = false;

    const mesh = try Mesh.init(u16, &.{
        3, 6, 7, 2, 6, 3, // back
        0, 4, 5, 1, 0, 5, // front
        3, 7, 4, 0, 3, 4, // left
        2, 5, 6, 1, 5, 2, // right
        5, 4, 7, 6, 5, 7, // top
        3, 0, 1, 1, 2, 3, // bottom
    }, &.{
        .{ 0.0, 0.0, 0.0 }, // 0
        .{ 1.0, 0.0, 0.0 }, // 1
        .{ 1.0, 0.0, 1.0 }, // 2
        .{ 0.0, 0.0, 1.0 }, // 3
        .{ 0.0, 1.0, 0.0 }, // 4
        .{ 1.0, 1.0, 0.0 }, // 5
        .{ 1.0, 1.0, 1.0 }, // 6
        .{ 0.0, 1.0, 1.0 }, // 7
    }, &.{
        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 1.0, 1.0 },
        .{ 0.0, 1.0 },

        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 1.0, 1.0 },
        .{ 0.0, 1.0 },
    });

    const pipeline = try allocator.create(GraphicsPipeline);
    pipeline.* = try GraphicsPipeline.create(allocator);

    const image = try Image.createFromFile(allocator, "assets/textures/None.png");
    const material = try Material.init(image, pipeline);

    // var last_time: i64 = 0;

    while (running) {
        var event: sdl.SDL_Event = undefined;

        while (sdl.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => running = false,
                sdl.SDL_EVENT_WINDOW_RESIZED => try Renderer.singleton.resize(),
                sdl.SDL_EVENT_KEY_DOWN => {
                    if (event.key.key == sdl.SDLK_F) {
                        _ = sdl.SDL_SetWindowFullscreen(window, !fullscreen);
                        fullscreen = !fullscreen;
                        try Renderer.singleton.resize();
                    }
                },
                else => {},
            }
        }

        try Renderer.singleton.draw(mesh, material);

        // if (std.time.milliTimestamp() - last_time >= 500) {
        //     console.clear();
        //     console.moveToStart();

        //     Renderer.singleton.printDebugStats();

        //     last_time = std.time.milliTimestamp();
        // }
    }

    // if (@import("builtin").mode == .Debug) _ = debug_allocator.detectLeaks();
}

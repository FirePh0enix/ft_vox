const std = @import("std");
const vk = @import("vulkan");
const sdl = @import("sdl");
const builtin = @import("builtin");
const console = @import("console.zig");
const zm = @import("zmath");

const Renderer = @import("render/Renderer.zig");
const Buffer = @import("render/Buffer.zig");
const Mesh = @import("Mesh.zig");
const Image = @import("render/Image.zig");
const Material = @import("Material.zig");
const GraphicsPipeline = @import("render/GraphicsPipeline.zig");
const ShaderModel = @import("render/ShaderModel.zig");

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
        0, 1, 2, 2, 3, 0, // front
        4, 5, 6, 6, 7, 4, // right
        8, 9, 10, 10, 11, 8, // top
        12, 13, 14, 14, 15, 12, // left
        16, 17, 18, 18, 19, 16, // bottom
        20, 21, 22, 22, 23, 20, // back
    }, &.{
        // front
        .{ 0.0, 0.0, 1.0 },
        .{ 1.0, 0.0, 1.0 },
        .{ 1.0, 1.0, 1.0 },
        .{ 0.0, 1.0, 1.0 },
        // top
        .{ 0.0, 1.0, 1.0 },
        .{ 1.0, 1.0, 1.0 },
        .{ 1.0, 1.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        // back
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 1.0, 1.0, 0.0 },
        // bottom
        .{ 0.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 1.0 },
        .{ 0.0, 0.0, 1.0 },
        // left
        .{ 0.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 1.0 },
        .{ 0.0, 1.0, 1.0 },
        .{ 0.0, 1.0, 0.0 },
        // right
        .{ 1.0, 0.0, 1.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 1.0, 1.0, 0.0 },
        .{ 1.0, 1.0, 1.0 },
    }, &.{
        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 1.0, 1.0 },
        .{ 0.0, 1.0 },

        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 1.0, 1.0 },
        .{ 0.0, 1.0 },

        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 1.0, 1.0 },
        .{ 0.0, 1.0 },

        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 1.0, 1.0 },
        .{ 0.0, 1.0 },

        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 1.0, 1.0 },
        .{ 0.0, 1.0 },

        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 1.0, 1.0 },
        .{ 0.0, 1.0 },
    });

    const shader_model = try ShaderModel.init(allocator, .{
        .buffers = &.{
            ShaderModel.Buffer{ .element_type = .vec3, .rate = .vertex },
            ShaderModel.Buffer{ .element_type = .vec2, .rate = .vertex },
            ShaderModel.Buffer{ .element_type = .mat4, .rate = .instance },
        },
        .inputs = &.{
            ShaderModel.Input{ .binding = 0, .type = .vec3 },
            ShaderModel.Input{ .binding = 1, .type = .vec2 },
            ShaderModel.Input{ .binding = 2, .type = .mat4 },
        },
        .descriptors = &.{
            ShaderModel.Descriptor{ .type = .combined_image_sampler, .binding = 0, .stage = .fragment },
        },
        .push_constants = &.{
            ShaderModel.PushConstant{ .type = .{ .buffer = &.{.mat4} }, .stage = .vertex },
        },
    });
    defer shader_model.deinit();

    const pipeline = try allocator.create(GraphicsPipeline);
    pipeline.* = try GraphicsPipeline.create(allocator, shader_model);

    const image = try Image.createFromFile(allocator, "assets/textures/None.png");
    const material = try Material.init(image, pipeline);

    const width = 16;
    const height = 256;
    const depth = 16;

    var instances: [width * height * depth]zm.Mat = undefined;

    for (0..width) |x| {
        for (0..height) |y| {
            for (0..depth) |z| {
                instances[z * width * height + y * width + x] = zm.translation(@floatFromInt(x), @floatFromInt(y), -@as(f32, @floatFromInt(z)));
            }
        }
    }

    var instance_buffer = try Buffer.create(@sizeOf(zm.Mat) * instances.len, .{ .vertex_buffer_bit = true, .transfer_dst_bit = true }, .gpu_only);
    try instance_buffer.update(zm.Mat, &instances);

    // var last_time: i64 = 0;

    var camera_pos: zm.Vec = .{ 0.0, 0.0, 2.0, 1.0 };
    const camera_rot: zm.Vec = .{ 0.0, 0.0, 0.0, 1.0 };

    const speed: f32 = 0.1;

    while (running) {
        var event: sdl.SDL_Event = undefined;

        while (sdl.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => running = false,
                sdl.SDL_EVENT_WINDOW_RESIZED => try Renderer.singleton.resize(),
                sdl.SDL_EVENT_KEY_DOWN => {
                    switch (event.key.key) {
                        sdl.SDLK_F => {
                            _ = sdl.SDL_SetWindowFullscreen(window, !fullscreen);
                            fullscreen = !fullscreen;
                            try Renderer.singleton.resize();
                        },

                        sdl.SDLK_W => {
                            camera_pos[2] -= speed;
                        },
                        sdl.SDLK_S => {
                            camera_pos[2] += speed;
                        },
                        sdl.SDLK_A => {
                            camera_pos[0] -= speed;
                        },
                        sdl.SDLK_D => {
                            camera_pos[0] += speed;
                        },

                        sdl.SDLK_SPACE => {
                            camera_pos[1] += speed;
                        },
                        sdl.SDLK_LSHIFT => {
                            camera_pos[1] -= speed;
                        },

                        else => {},
                    }
                },
                else => {},
            }
        }

        try Renderer.singleton.draw(mesh, material, camera_pos, camera_rot, instance_buffer, instances.len);

        // if (std.time.milliTimestamp() - last_time >= 500) {
        //     console.clear();
        //     console.moveToStart();

        //     Renderer.singleton.printDebugStats();

        //     last_time = std.time.milliTimestamp();
        // }
    }

    // if (@import("builtin").mode == .Debug) _ = debug_allocator.detectLeaks();
}

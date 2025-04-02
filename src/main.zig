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
const Camera = @import("Camera.zig");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub const allocator: std.mem.Allocator = if (builtin.mode == .Debug)
    debug_allocator.allocator()
else
    std.heap.smp_allocator;

// export VK_LAYER_MESSAGE_ID_FILTER=UNASSIGNED-CoreValidation-DrawState-QueryNotReset

var camera = Camera{};
const speed: f32 = 0.1;

const Movement = enum { forward, left, right, backward };
var movementStates: std.EnumArray(Movement, bool) = .initFill(false);

pub fn keyPressed(key: u32) void {
    switch (key) {
        sdl.SDLK_W => movementStates.set(.forward, true),
        sdl.SDLK_A => movementStates.set(.left, true),
        sdl.SDLK_S => movementStates.set(.backward, true),
        sdl.SDLK_D => movementStates.set(.right, true),
        else => {},
    }
}

pub fn keyReleased(key: u32) void {
    switch (key) {
        sdl.SDLK_W => movementStates.set(.forward, false),
        sdl.SDLK_A => movementStates.set(.left, false),
        sdl.SDLK_S => movementStates.set(.backward, false),
        sdl.SDLK_D => movementStates.set(.right, false),
        else => {},
    }
}

pub fn updateCameraPosition() void {
    const yaw = std.math.degreesToRadians(camera.rotation[1]);
    const pitch = std.math.degreesToRadians(camera.rotation[0]);

    // This is where the camera "looks".
    const forward: zm.Vec = .{
        std.math.cos(pitch) * std.math.sin(yaw),
        -std.math.sin(pitch),
        -std.math.cos(pitch) * std.math.cos(yaw),
        0.0,
    };

    // And this is a perpendicular to where it looks.
    const right: zm.Vec = .{
        std.math.cos(yaw),
        0.0,
        -std.math.sin(yaw),
        0.0,
    };

    if (movementStates.get(.forward)) {
        camera.position[0] += forward[0] * speed;
        camera.position[1] += forward[1] * speed;
        camera.position[2] += forward[2] * speed;
    }
    if (movementStates.get(.backward)) {
        camera.position[0] -= forward[0] * speed;
        camera.position[1] -= forward[1] * speed;
        camera.position[2] -= forward[2] * speed;
    }
    if (movementStates.get(.left)) {
        camera.position[0] -= right[0] * speed;
        camera.position[1] -= right[1] * speed;
        camera.position[2] -= right[2] * speed;
    }
    if (movementStates.get(.right)) {
        camera.position[0] += right[0] * speed;
        camera.position[1] += right[1] * speed;
        camera.position[2] += right[2] * speed;
    }
}

pub fn handleMouseMotion(xrel: f32, yrel: f32) void {
    const sensitivity: f32 = 0.1;

    camera.rotation[1] += xrel * sensitivity;

    camera.rotation[0] += yrel * sensitivity;


// Ensure you cant do a 360 deg from looking top/bottom.
    if (camera.rotation[0] >= 90.0) {
        camera.rotation[0] = 90.0;
    } else if (camera.rotation[0] <= -90.0) {
        camera.rotation[0] = -90.0;
    }
}

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

    _ = sdl.SDL_SetWindowRelativeMouseMode(window, true);
    var mouse_grab = true;

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
                        sdl.SDLK_ESCAPE => {
                            _ = sdl.SDL_SetWindowRelativeMouseMode(window, false);
                            mouse_grab = false;
                        },
                        else => {
                            keyPressed(event.key.key);
                        },
                    }
                },
                sdl.SDL_EVENT_KEY_UP => {
                    keyReleased(event.key.key);
                },
                sdl.SDL_EVENT_MOUSE_MOTION => {
                    handleMouseMotion(event.motion.xrel, event.motion.yrel);
                },
                else => {},
            }
        }

        updateCameraPosition();

        try Renderer.singleton.draw(mesh, material, camera.position, camera.rotation, instance_buffer, instances.len);

        // if (std.time.milliTimestamp() - last_time >= 500) {
        //     console.clear();
        //     console.moveToStart();

        //     Renderer.singleton.printDebugStats();

        //     last_time = std.time.milliTimestamp();
        // }
    }

    // if (@import("builtin").mode == .Debug) _ = debug_allocator.detectLeaks();
}

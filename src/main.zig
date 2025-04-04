const std = @import("std");
const vk = @import("vulkan");
const sdl = @import("sdl");
const builtin = @import("builtin");
const console = @import("console.zig");
const zm = @import("zmath");
const input = @import("input.zig");
const world = @import("world.zig");
const world_gen = @import("world_gen.zig");

const Renderer = @import("render/Renderer.zig");
const Buffer = @import("render/Buffer.zig");
const Mesh = @import("Mesh.zig");
const Image = @import("render/Image.zig");
const Material = @import("Material.zig");
const GraphicsPipeline = @import("render/GraphicsPipeline.zig");
const ShaderModel = @import("render/ShaderModel.zig");
const Camera = @import("Camera.zig");
const RenderFrame = @import("render/RenderFrame.zig");
const World = world.World;
const Chunk = world.Chunk;
const TrackingAllocator = @import("TrackingAllocator.zig");

const rdr = Renderer.rdr;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub var tracking_allocator = if (builtin.mode == .Debug)
    TrackingAllocator{ .backing_allocator = debug_allocator.allocator() }
else
    TrackingAllocator{ .backing_allocator = std.heap.smp_allocator };

pub const allocator: std.mem.Allocator = tracking_allocator.allocator();

// export VK_LAYER_MESSAGE_ID_FILTER=UNASSIGNED-CoreValidation-DrawState-QueryNotReset

var camera = Camera{
    .position = .{ 64.0, 20.0, -10.0, 0.0 },
    .rotation = .{ 0.0, std.math.pi, 0.0, 0.0 },
};

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
        // front
        .{ 0.0, 0.0, 1.0 },
        .{ 0.0, 0.0, 1.0 },
        .{ 0.0, 0.0, 1.0 },
        .{ 0.0, 0.0, 1.0 },
        // top
        .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        // back
        .{ 0.0, 0.0, -1.0 },
        .{ 0.0, 0.0, -1.0 },
        .{ 0.0, 0.0, -1.0 },
        .{ 0.0, 0.0, -1.0 },
        // bottom
        .{ 0.0, -1.0, 0.0 },
        .{ 0.0, -1.0, 0.0 },
        .{ 0.0, -1.0, 0.0 },
        .{ 0.0, -1.0, 0.0 },
        // left
        .{ 1.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        // right
        .{ -1.0, 0.0, 0.0 },
        .{ -1.0, 0.0, 0.0 },
        .{ -1.0, 0.0, 0.0 },
        .{ -1.0, 0.0, 0.0 },
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
        .shaders = &.{},
        .buffers = &.{
            ShaderModel.Buffer{ .element_type = .vec3, .rate = .vertex },
            ShaderModel.Buffer{ .element_type = .vec3, .rate = .vertex },
            ShaderModel.Buffer{ .element_type = .vec2, .rate = .vertex },
            ShaderModel.Buffer{ .element_type = .vec3, .rate = .instance },
        },
        .inputs = &.{
            ShaderModel.Input{ .binding = 0, .type = .vec3 },
            ShaderModel.Input{ .binding = 1, .type = .vec3 },
            ShaderModel.Input{ .binding = 2, .type = .vec2 },
            ShaderModel.Input{ .binding = 3, .type = .vec3 },
        },
        .descriptors = &.{
            ShaderModel.Descriptor{ .type = .combined_image_sampler, .binding = 0, .stage = .fragment }, // albedo texture
            ShaderModel.Descriptor{ .type = .uniform_buffer, .binding = 1, .stage = .fragment }, // lighting data
        },
        .push_constants = &.{
            ShaderModel.PushConstant{ .type = .{ .buffer = &.{.mat4} }, .stage = .vertex },
        },
    });
    defer shader_model.deinit();

    const pipeline = try allocator.create(GraphicsPipeline);
    pipeline.* = try GraphicsPipeline.create(allocator, shader_model);

    const image = try Image.createFromFile(allocator, "assets/textures/Grass_Top.png");
    const material = try Material.init(image, pipeline);

    var render_frame: RenderFrame = try .create(allocator, mesh, material);
    var the_world = try world_gen.generateWorld(allocator, .{
        .seed = 0,
    });
    defer the_world.deinit();

    input.init(window);

    var last_time: i64 = 0;

    const time_between_update: i64 = 1000000 / 60;
    var last_update_time: i64 = 0;

    while (running) {
        if (std.time.microTimestamp() - last_update_time < time_between_update) {
            continue;
        }
        last_update_time = std.time.microTimestamp();

        const time_before = std.time.microTimestamp();

        var event: sdl.SDL_Event = undefined;

        while (sdl.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => running = false,
                sdl.SDL_EVENT_WINDOW_RESIZED => try Renderer.singleton.resize(),
                else => try input.handleSDLEvent(event, &camera),
            }
        }

        camera.updateCamera();

        try rdr().draw(&camera, &the_world, &render_frame);

        const time_after = std.time.microTimestamp();
        const elapsed = time_after - time_before;

        rdr().statistics.prv_cpu_time = @as(f32, @floatFromInt(elapsed)) / 1000.0;

        if (std.time.milliTimestamp() - last_time >= 500) {
            // console.clear();
            // console.moveToStart();

            // rdr().printDebugStats();

            last_time = std.time.milliTimestamp();
        }
    }

    // if (@import("builtin").mode == .Debug) _ = debug_allocator.detectLeaks();
}

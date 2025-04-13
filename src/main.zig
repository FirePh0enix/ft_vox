const std = @import("std");
const vk = @import("vulkan");
const sdl = @import("sdl");
const builtin = @import("builtin");
const console = @import("console.zig");
const zm = @import("zmath");
const input = @import("input.zig");
const world_gen = @import("world_gen.zig");
const dcimgui = @import("dcimgui");

const Renderer = @import("render/Renderer.zig");
const Buffer = @import("render/Buffer.zig");
const Mesh = @import("Mesh.zig");
const Image = @import("render/Image.zig");
const Material = @import("render/Material.zig");
const GraphicsPipeline = @import("render/GraphicsPipeline.zig");
const ShaderModel = @import("render/ShaderModel.zig");
const Window = @import("render/Window.zig");
const Graph = @import("render/Graph.zig");
const Camera = @import("Camera.zig");
const RenderFrame = @import("voxel/RenderFrame.zig");
const World = @import("voxel/World.zig");
const Chunk = @import("voxel/Chunk.zig");
const TrackingAllocator = @import("TrackingAllocator.zig");
const Block = @import("voxel/Block.zig");
const Registry = @import("voxel/Registry.zig");

const rdr = Renderer.rdr;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub var tracking_allocator = if (builtin.mode == .Debug)
    TrackingAllocator{ .backing_allocator = debug_allocator.allocator() }
else
    TrackingAllocator{ .backing_allocator = std.heap.smp_allocator };

pub const allocator: std.mem.Allocator = tracking_allocator.allocator();

// export VK_LAYER_MESSAGE_ID_FILTER=UNASSIGNED-CoreValidation-DrawState-QueryNotReset

var camera = Camera{
    .position = .{ 10.0, 100.0, -10.0, 0.0 },
    .rotation = .{ 0.0, std.math.pi, 0.0, 0.0 },
    .speed = 0.5,
};

var running = false;
var last_update_time: i64 = 0;
var time_between_update: i64 = 1000000 / 60;

var mesh: Mesh = undefined;
var material: Material = undefined;

var graph: Graph = undefined;
var render_pass: Graph.RenderPass = undefined;

pub fn mainDesktop() !void {
    var window = try Window.create(.{
        .title = "ft_vox",
        .width = 1280,
        .height = 720,
        .driver = .vulkan,
        .resizable = true,
    });

    try Renderer.create(allocator, .vulkan);
    try rdr().createDevice(&window, null);
    try rdr().createSwapchain(&window, .{ .vsync = .performance });

    render_pass = try Graph.RenderPass.create(allocator, rdr().asVk().render_pass, .{
        .attachments = .{ .color = true, .depth = true },
        .max_draw_calls = 32 * 32,
    });

    graph = Graph.init(allocator);
    graph.main_render_pass = &render_pass;

    mesh = try Mesh.createCube();

    const shader_model = try ShaderModel.init(allocator, .{
        .shaders = &.{},
        .buffers = &.{
            ShaderModel.Buffer{ .element_type = .vec3, .rate = .vertex },
            ShaderModel.Buffer{ .element_type = .vec3, .rate = .vertex },
            ShaderModel.Buffer{ .element_type = .vec2, .rate = .vertex },
            ShaderModel.Buffer{ .element_type = .{ .buffer = &.{ .vec3, .vec3, .vec3, .uint } }, .rate = .instance },
        },
        .inputs = &.{
            ShaderModel.Input{ .binding = 0, .type = .vec3 }, // position
            ShaderModel.Input{ .binding = 1, .type = .vec3 }, // normal
            ShaderModel.Input{ .binding = 2, .type = .vec2 }, // texture coordinates
            ShaderModel.Input{ .binding = 3, .type = .vec3, .offset = 0 }, // instance position
            ShaderModel.Input{ .binding = 3, .type = .vec3, .offset = 3 * @sizeOf(f32) }, // instance texture indices 0
            ShaderModel.Input{ .binding = 3, .type = .vec3, .offset = 6 * @sizeOf(f32) }, // instance texture indices 1
            ShaderModel.Input{ .binding = 3, .type = .uint, .offset = 9 * @sizeOf(f32) }, // instance visibility
        },
        .descriptors = &.{
            ShaderModel.Descriptor{ .type = .combined_image_sampler, .binding = 0, .stage = .fragment },
            ShaderModel.Descriptor{ .type = .uniform_buffer, .binding = 1, .stage = .fragment }, // lighting data
        },
        .push_constants = &.{
            ShaderModel.PushConstant{ .type = .{ .buffer = &.{.mat4} }, .stage = .vertex },
        },
    });
    defer shader_model.deinit();

    const pipeline = try allocator.create(GraphicsPipeline);
    pipeline.* = try GraphicsPipeline.create(allocator, shader_model);

    var registry = Registry.init(allocator);

    try registry.registerBlock(.{
        .name = "dirt",
        .visual = .{ .cube = .{ .textures = .{
            "assets/textures/Dirt.png",
            "assets/textures/Dirt.png",
            "assets/textures/Dirt.png",
            "assets/textures/Dirt.png",
            "assets/textures/Dirt.png",
            "assets/textures/Dirt.png",
        } } },
    }, .{});

    try registry.registerBlock(.{
        .name = "grass",
        .visual = .{ .cube = .{ .textures = .{
            "assets/textures/Grass_Side.png",
            "assets/textures/Grass_Side.png",
            "assets/textures/Grass_Side.png",
            "assets/textures/Grass_Side.png",
            "assets/textures/Grass_Top.png",
            "assets/textures/Dirt.png",
        } } },
    }, .{});

    try registry.registerBlock(.{
        .name = "water",
        .visual = .{ .cube = .{ .textures = .{
            "assets/textures/Water.png",
            "assets/textures/Water.png",
            "assets/textures/Water.png",
            "assets/textures/Water.png",
            "assets/textures/Water.png",
            "assets/textures/Water.png",
        } } },
    }, .{});

    try registry.lock();

    material = try Material.init(registry.image_array.?, pipeline);

    // var render_frame: RenderFrame = try .create(allocator, mesh, material);
    var world = try world_gen.generateWorld(allocator, &registry, .{
        .seed = 0,
    });
    try world.startWorkers(&registry);
    // try world.save("new-world");

    defer world.deinit();

    input.init(&window);

    while (running) {
        update(&window, &world);
    }
}

fn update(window: *Window, world: *World) void {
    if (std.time.microTimestamp() - last_update_time < time_between_update) {
        return;
    }
    last_update_time = std.time.microTimestamp();

    // const time_before = std.time.microTimestamp();

    var event: sdl.SDL_Event = undefined;

    while (sdl.SDL_PollEvent(&event)) {
        _ = dcimgui.cImGui_ImplSDL3_ProcessEvent(@ptrCast(&event));

        switch (event.type) {
            sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => running = false,
            sdl.SDL_EVENT_WINDOW_RESIZED => try rdr().createSwapchain(window, .{ .vsync = .performance }),
            else => try input.handleSDLEvent(event, &camera),
        }
    }

    camera.updateCamera(&world);

    // Rebuild the render pass
    const aspect_ratio = @as(f32, @floatFromInt(rdr().asVk().swapchain_extent.width)) / @as(f32, @floatFromInt(rdr().asVk().swapchain_extent.height));
    var projection_matrix = zm.perspectiveFovRh(std.math.degreesToRadians(60.0), aspect_ratio, 0.01, 1000.0);
    projection_matrix[1][1] *= -1;
    const view_matrix = zm.mul(camera.getViewMatrix(), projection_matrix);

    // Record draw calls into the render pass
    render_pass.reset();
    render_pass.view_matrix = view_matrix;

    var chunk_iter = world.chunks.valueIterator();

    while (chunk_iter.next()) |chunk| render_pass.drawInstanced(&mesh, &material, &chunk.instance_buffer, 0, mesh.count, 0, chunk.instance_count);

    try rdr().processGraph(&graph);

    // const time_after = std.time.microTimestamp();
    // const elapsed = time_after - time_before;

    // rdr().asVk().statistics.prv_cpu_time = @as(f32, @floatFromInt(elapsed)) / 1000.0;
}

const wgpu = @import("webgpu");

pub fn mainWasi() !void {
    std.debug.print("Hello world!\n", .{});

    const instance = wgpu.createInstance(null);

    std.debug.print("{*}\n", .{instance});
}

pub const main = if (builtin.cpu.arch.isWasm())
    mainWasi
else
    mainDesktop;

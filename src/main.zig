const std = @import("std");
const vk = @import("vulkan");
const sdl = @import("sdl");
const builtin = @import("builtin");
const zm = @import("zmath");
const input = @import("input.zig");
const world_gen = @import("world_gen.zig");
const dcimgui = @import("dcimgui");
const argzon = @import("argzon");

const Renderer = @import("render/Renderer.zig");
const Mesh = @import("Mesh.zig");
const Material = @import("render/Material.zig");
const ShaderModel = @import("render/ShaderModel.zig");
const Window = @import("render/Window.zig");
const Graph = @import("render/Graph.zig");
const ShadowPass = @import("render/ShadowPass.zig");
const Camera = @import("Camera.zig");
const World = @import("voxel/World.zig");
const Chunk = @import("voxel/Chunk.zig");
const TrackingAllocator = @import("TrackingAllocator.zig");
const Block = @import("voxel/Block.zig");
const Registry = @import("voxel/Registry.zig");
const RID = Renderer.RID;

const rdr = Renderer.rdr;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub var tracking_allocator = if (builtin.mode == .Debug)
    TrackingAllocator{ .backing_allocator = debug_allocator.allocator() }
else
    TrackingAllocator{ .backing_allocator = std.heap.smp_allocator };

pub const allocator: std.mem.Allocator = tracking_allocator.allocator();

// export VK_LAYER_MESSAGE_ID_FILTER=UNASSIGNED-CoreValidation-DrawState-QueryNotReset

const cli = .{
    .name = .ft_vox,
    .description = "",
    .options = .{
        .{
            .long = "seed",
            .description = "The seed used by world generation",
            .type = "u64",
        },
        .{
            .long = "save-name",
            .description = "The name of the save to load",
            .type = "s",
        },
    },
    .flags = .{
        .{
            .long = "disable-save",
            .descripton = "Disable world save",
        },
    },
};
const Args = argzon.Args(cli, .{});

var camera = Camera{
    .position = .{ 10.0, 100.0, -10.0, 0.0 },
    .rotation = .{ 0.0, std.math.pi, 0.0, 0.0 },
    .speed = 0.5,
};

var running = true;
var last_update_time: i64 = 0;
var time_between_update: i64 = 1000000 / 60;

var mesh: Mesh = undefined;
var material: Material = undefined;

pub var the_world: World = undefined;

var graph: Graph = undefined;
pub var render_graph_pass: Graph.RenderPass = undefined;
pub var shadow_graph_pass: Graph.RenderPass = undefined;

var shadow_pass: ShadowPass = undefined;

pub fn mainDesktop() !void {
    const args = try Args.parse(allocator, std.io.getStdErr().writer(), .{ .is_gpa = false });

    var window = try Window.create(.{
        .title = "ft_vox",
        .width = 1280,
        .height = 720,
        .driver = .vulkan,
        .resizable = true,
    });

    try Renderer.create(allocator, .vulkan);
    try rdr().createDevice(&window, null);
    try rdr().imguiInit(&window, rdr().getOutputRenderPass());

    const size = window.size();

    try rdr().configure(.{ .width = size.width, .height = size.height, .vsync = .performance });

    render_graph_pass = try Graph.RenderPass.create(allocator, rdr().getOutputRenderPass(), .{
        .attachments = .{ .color = true, .depth = true },
        .max_draw_calls = 32 * 32,
    });

    shadow_pass = try ShadowPass.init(.{});
    shadow_graph_pass = try shadow_pass.createRenderPass(allocator);

    render_graph_pass.dependsOn(&shadow_graph_pass);

    graph = Graph.init(allocator);
    graph.main_render_pass = &render_graph_pass;

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

    const pipeline = try rdr().pipelineCreateGraphics(.{ .shader_model = shader_model, .render_pass = rdr().getOutputRenderPass() });

    var registry = Registry.init(allocator);

    try registry.registerBlockFromFile("dirt", .{});
    try registry.registerBlockFromFile("grass", .{});
    try registry.registerBlockFromFile("water", .{});
    try registry.registerBlockFromFile("stone", .{});
    try registry.registerBlockFromFile("sand", .{});

    try registry.lock();

    material = try Material.init(registry.image_array.?, pipeline);

    the_world = try world_gen.generateWorld(allocator, &registry, .{
        .seed = args.options.seed,
    });
    try the_world.startWorkers(&registry);

    defer the_world.deinit();

    input.init(&window);

    while (running) {
        try update(&window, &the_world);
    }
}

fn update(window: *Window, world: *World) !void {
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
            sdl.SDL_EVENT_WINDOW_RESIZED => {
                const size = window.size();
                try rdr().configure(.{ .width = size.width, .height = size.height, .vsync = .performance });
            },
            else => try input.handleSDLEvent(event, &camera),
        }
    }

    camera.updateCamera(world);

    // Rebuild the render pass
    const surface_size = rdr().getSize();
    const aspect_ratio = @as(f32, @floatFromInt(surface_size.width)) / @as(f32, @floatFromInt(surface_size.height));
    var projection_matrix = zm.perspectiveFovRh(std.math.degreesToRadians(60.0), aspect_ratio, 0.01, 1000.0);
    projection_matrix[1][1] *= -1;
    const view_matrix = zm.mul(camera.getViewMatrix(), projection_matrix);

    // Record draw calls into the render pass
    render_graph_pass.reset();
    render_graph_pass.view_matrix = view_matrix;

    {
        world.chunks_lock.lock();
        defer world.chunks_lock.unlock();

        var chunk_iter = world.chunks.valueIterator();

        while (chunk_iter.next()) |chunk| render_graph_pass.drawInstanced(&mesh, &material, chunk.instance_buffer, 0, mesh.count, 0, chunk.instance_count);

        try rdr().processGraph(&graph);
    }

    // const time_after = std.time.microTimestamp();
    // const elapsed = time_after - time_before;

    // rdr().asVk().statistics.prv_cpu_time = @as(f32, @floatFromInt(elapsed)) / 1000.0;
}

const wgpu = @import("webgpu");

pub fn mainEmscripten() !void {
    std.debug.print("Hello world!\n", .{});
}

pub const main = if (builtin.cpu.arch.isWasm())
    mainEmscripten
else
    mainDesktop;

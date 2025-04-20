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

pub const BlockZon = Registry.BlockZon;

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

var cube_mesh: RID = undefined;
var material: RID = undefined;

pub var the_world: World = undefined;

var graph: Graph = undefined;
pub var render_graph_pass: Graph.RenderPass = undefined;
pub var shadow_graph_pass: Graph.RenderPass = undefined;

var shadow_pass: ShadowPass = undefined;

fn n(v: [3]f32) [3]f32 {
    const inv_length = 1.0 / std.math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return .{ v[0] * inv_length, v[1] * inv_length, v[2] * inv_length };
}

pub fn createCube() !RID {
    return try rdr().meshCreate(.{
        .indices = std.mem.sliceAsBytes(@as([]const u16, &.{
            0, 1, 2, 2, 3, 0, // front
            20, 21, 22, 22, 23, 20, // back
            4, 5, 6, 6, 7, 4, // right
            12, 13, 14, 14, 15, 12, // left
            8, 9, 10, 10, 11, 8, // top
            16, 17, 18, 18, 19, 16, // bottom
        })),
        .vertices = std.mem.sliceAsBytes(@as([]const [3]f32, &.{
            // front
            .{ 0.0, 0.0, 1.0 },
            .{ 1.0, 0.0, 1.0 },
            .{ 1.0, 1.0, 1.0 },
            .{ 0.0, 1.0, 1.0 },
            // back
            .{ 1.0, 0.0, 0.0 },
            .{ 0.0, 0.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            .{ 1.0, 1.0, 0.0 },
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
            // top
            .{ 0.0, 1.0, 1.0 },
            .{ 1.0, 1.0, 1.0 },
            .{ 1.0, 1.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            // bottom
            .{ 0.0, 0.0, 0.0 },
            .{ 1.0, 0.0, 0.0 },
            .{ 1.0, 0.0, 1.0 },
            .{ 0.0, 0.0, 1.0 },
        })),
        .normals = std.mem.sliceAsBytes(@as([]const [3]f32, &.{
            // front
            n(.{ -0.5, -0.5, 0.5 }),
            n(.{ 0.5, -0.5, 0.5 }),
            n(.{ 0.5, 0.5, 0.5 }),
            n(.{ -0.5, 0.5, 0.5 }),
            // back
            n(.{ 0.5, -0.5, -0.5 }),
            n(.{ -0.5, -0.5, -0.5 }),
            n(.{ -0.5, 0.5, -0.5 }),
            n(.{ 0.5, 0.5, -0.5 }),
            // left
            n(.{ -0.5, -0.5, -0.5 }),
            n(.{ -0.5, -0.5, 0.5 }),
            n(.{ -0.5, 0.5, 0.5 }),
            n(.{ -0.5, 0.5, -0.5 }),
            // right
            n(.{ 0.5, -0.5, 0.5 }),
            n(.{ 0.5, -0.5, -0.5 }),
            n(.{ 0.5, 0.5, -0.5 }),
            n(.{ 0.5, 0.5, 0.5 }),
            // top
            n(.{ -0.5, 0.5, 0.5 }),
            n(.{ 0.5, 0.5, 0.5 }),
            n(.{ 0.5, 0.5, -0.5 }),
            n(.{ -0.5, 0.5, -0.5 }),
            // bottom
            n(.{ -0.5, -0.5, -0.5 }),
            n(.{ 0.5, -0.5, -0.5 }),
            n(.{ 0.5, -0.5, 0.5 }),
            n(.{ -0.5, -0.5, 0.5 }),
        })),
        .texture_coords = std.mem.sliceAsBytes(@as([]const [2]f32, &.{
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
        })),
    });
}

pub fn mainDesktop() !void {
    const args = try Args.parse(allocator, std.io.getStdErr().writer(), .{ .is_gpa = false });

    var window = try Window.create(.{
        .title = "ft_vox",
        .width = 1280,
        .height = 720,
        .driver = .vulkan,
        .resizable = true,
    });
    defer window.deinit();

    try Renderer.create(allocator, .vulkan);
    try rdr().createDevice(&window, null);
    defer rdr().destroy();

    try rdr().imguiInit(&window, rdr().getOutputRenderPass());

    const size = window.size();

    try rdr().configure(.{ .width = size.width, .height = size.height, .vsync = .performance });

    const shader_model = try ShaderModel.init(allocator, .{
        .shaders = &.{
            .{ .path = "basic_cube.vert.spv", .stage = .vertex },
            .{ .path = "basic_cube.frag.spv", .stage = .fragment },
        },
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
            ShaderModel.Descriptor{ .type = .combined_image_sampler, .binding = 0, .stage = .fragment }, // texture array
            ShaderModel.Descriptor{ .type = .combined_image_sampler, .binding = 1, .stage = .fragment }, // shadow texture
        },
        .push_constants = &.{
            ShaderModel.PushConstant{ .type = .{ .buffer = &.{.mat4} }, .stage = .vertex },
        },
    });
    defer shader_model.deinit();

    render_graph_pass = try Graph.RenderPass.create(allocator, rdr().getOutputRenderPass(), .{
        .max_draw_calls = 32 * 32,
    });
    defer render_graph_pass.deinit();

    shadow_pass = try ShadowPass.init(.{ .allocator = allocator });
    defer shadow_pass.deinit();

    shadow_graph_pass = try shadow_pass.createRenderPass(allocator);

    // render_graph_pass.dependsOn(&shadow_graph_pass);

    graph = Graph.init(allocator);
    graph.main_render_pass = &render_graph_pass;

    cube_mesh = try createCube();
    defer rdr().freeRid(cube_mesh);

    var registry = Registry.init(allocator);

    try registry.registerBlockFromFile("water.zon", .{});
    try registry.registerBlockFromFile("deep_water.zon", .{});
    try registry.registerBlockFromFile("stone.zon", .{});
    try registry.registerBlockFromFile("dirt.zon", .{});
    try registry.registerBlockFromFile("grass.zon", .{});
    try registry.registerBlockFromFile("savanna_dirt.zon", .{});
    try registry.registerBlockFromFile("snow_dirt.zon", .{});
    try registry.registerBlockFromFile("sand.zon", .{});

    try registry.lock();

    material = try rdr().materialCreate(.{
        .shader_model = shader_model,
        .params = &.{
            .{ .name = "textures", .type = .image },
        },
    });
    try rdr().materialSetParam(material, "textures", .{
        .image = .{
            .rid = registry.image_array orelse unreachable,
            .sampler = .{
                .mag_filter = .nearest, // Nearest is best for pixel art and voxels.
                .min_filter = .nearest,
                .address_mode = .{ .u = .clamp_to_edge, .v = .clamp_to_edge, .w = .clamp_to_edge },
            },
        },
    });

    the_world = try world_gen.generateWorld(allocator, &registry, .{
        .seed = args.options.seed,
    });
    try the_world.createBuffers(10);
    try the_world.startWorkers(&registry);
    defer the_world.deinit();

    render_graph_pass.addImguiHook(&statsDebugHook);

    input.init(&window);

    while (running) {
        try update(&window, &the_world);
    }

    world_gen.deinit();
    rdr().freeRid(registry.image_array orelse unreachable);
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

    try the_world.encodeDrawCalls(cube_mesh, &shadow_graph_pass, shadow_pass.material, &render_graph_pass, material);
    try rdr().processGraph(&graph);

    // const time_after = std.time.microTimestamp();
    // const elapsed = time_after - time_before;

    // rdr().asVk().statistics.prv_cpu_time = @as(f32, @floatFromInt(elapsed)) / 1000.0;
}

fn statsDebugHook(render_pass: *Graph.RenderPass) void {
    _ = render_pass;

    if (dcimgui.ImGui_Begin("Statistics", null, 0)) {
        const stats = rdr().getStatistics();

        var buf: [128]u8 = undefined;

        dcimgui.ImGui_Text("Primitves  : %zu", stats.primitives_drawn);
        dcimgui.ImGui_Text("GPU Time   : %.2f", stats.gpu_time);
        dcimgui.ImGui_Text("GPU Memory : %s", (std.fmt.bufPrintZ(&buf, "{:.2}", .{std.fmt.fmtIntSizeBin(@intCast(stats.vram_used))}) catch unreachable).ptr);
    }
    dcimgui.ImGui_End();
}

const wgpu = @import("webgpu");

pub fn mainEmscripten() !void {
    std.debug.print("Hello world!\n", .{});
}

pub const main = if (builtin.cpu.arch.isWasm())
    mainEmscripten
else
    mainDesktop;

const std = @import("std");
const vk = @import("vulkan");
const c = @import("c");
const builtin = @import("builtin");
const zm = @import("zmath");
const input = @import("input.zig");
const argzon = @import("argzon");
const zemscripten = @import("zemscripten");
const tracy = @import("tracy");

const Renderer = @import("render/Renderer.zig");
const Window = @import("Window.zig");
const Graph = @import("render/Graph.zig");
const Buffer = @import("render/Buffer.zig");
const Camera = @import("Camera.zig");
const World = @import("voxel/World.zig");
const Chunk = @import("voxel/Chunk.zig");
const Block = @import("voxel/Block.zig");
const Registry = @import("voxel/Registry.zig");
const RID = Renderer.RID;
const Font = @import("Font.zig");
const Text = @import("Text.zig");
const Skybox = @import("Skybox.zig");

const rdr = Renderer.rdr;

pub const BlockZon = Registry.BlockZon;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub const allocator: std.mem.Allocator = if (builtin.cpu.arch.isWasm())
    std.heap.c_allocator
else if (builtin.mode == .Debug)
    debug_allocator.allocator()
else
    std.heap.smp_allocator;

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
            .long = "fov",
            .description = "Field of view in degrees",
            .type = "?f32",
        },
    },
    .flags = .{},
};
const Args = argzon.Args(cli, .{});

pub var camera = Camera.init(.{
    .aspect_ratio = 16.0 / 9.0,
    .fov = std.math.degreesToRadians(60.0),
    .position = .{ 0.0, 100.0, 0.0, 0.0 },
    .rotation = .{ 0.0, 0.0, 0.0, 0.0 },
    .speed = 0.5,
});

var last_update_time: i64 = 0;
var time_between_update: i64 = 1000000 / 60;

var cube_mesh: RID = undefined;
var material: RID = undefined;

pub var the_world: World = undefined;
pub var registry: Registry = undefined;

var graph: Graph = undefined;
pub var render_graph_pass: Graph.RenderPass = undefined;

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
            .{ 0.0, 0.0, 1.0 },
            .{ 0.0, 0.0, 1.0 },
            .{ 0.0, 0.0, 1.0 },
            .{ 0.0, 0.0, 1.0 },
            // back
            .{ 0.0, 0.0, -1.0 },
            .{ 0.0, 0.0, -1.0 },
            .{ 0.0, 0.0, -1.0 },
            .{ 0.0, 0.0, -1.0 },
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
            // top
            .{ 0.0, 1.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            // bottom
            .{ 0.0, -1.0, 0.0 },
            .{ 0.0, -1.0, 0.0 },
            .{ 0.0, -1.0, 0.0 },
            .{ 0.0, -1.0, 0.0 },
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

// TODO: Redo instance/batch rendering

const LightData = struct {
    matrix: [16]f32,
    position: [3]f32,
};

var light_matrix: zm.Mat = undefined;
var light_buffer: Buffer = undefined;

var font: Font = undefined;
var text: Text = undefined;
var skybox: Skybox = undefined;

pub fn mainDesktop() !void {
    defer {
        if (builtin.mode == .Debug) _ = debug_allocator.detectLeaks();
    }
    tracy.setThreadName("Main");

    const mainZone = tracy.beginZone(@src(), .{ .name = "main" });
    defer mainZone.end();

    const args = try Args.parse(allocator, std.io.getStdErr().writer(), .{ .is_gpa = false });

    if (args.options.fov) |fov| {
        camera.setFov(std.math.degreesToRadians(fov));
    }

    var window = try Window.create(.{
        .title = "ft_vox",
        .width = 1280,
        .height = 720,
        .driver = .vulkan,
        .resizable = true,
        .allocator = allocator,
    });
    defer window.deinit();

    try Renderer.create(allocator, .vulkan);
    defer Renderer.deinit();

    try rdr().createDevice(&window, null);
    defer rdr().destroy();

    try rdr().imguiInit(&window, rdr().getOutputRenderPass());
    defer rdr().imguiDestroy();

    const size = window.size();

    try rdr().configure(.{ .width = size.width, .height = size.height, .vsync = .performance });

    render_graph_pass = try Graph.RenderPass.create(allocator, rdr().getOutputRenderPass(), .{
        .max_draw_calls = 32 * 32,
    });
    defer render_graph_pass.deinit();

    graph = Graph.init(allocator);
    graph.main_render_pass = &render_graph_pass;

    cube_mesh = try createCube();
    defer rdr().freeRid(cube_mesh);

    try Font.initLib();
    defer Font.deinitLib();

    font = Font.init("assets/fonts/Anonymous.ttf", 16, allocator) catch {
        std.log.err("Cannot load font", .{});
        return;
    };
    defer font.deinit();

    text = try Text.initCapacity(&font, 5);
    defer text.deinit();

    skybox = try Skybox.init(allocator);
    defer skybox.deinit();

    registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.registerBlockFromFile("water.zon", .{});
    try registry.registerBlockFromFile("stone.zon", .{});
    try registry.registerBlockFromFile("dirt.zon", .{});
    try registry.registerBlockFromFile("grass.zon", .{});
    try registry.registerBlockFromFile("sand.zon", .{});

    try registry.lock();

    light_buffer = try Buffer.create(.{
        .size = @sizeOf(LightData),
        .usage = .{ .uniform_buffer = true, .transfer_dst = true },
    });
    defer light_buffer.destroy();

    material = try rdr().materialCreate(.{
        .shaders = &.{
            .{ .path = "voxel.vert.spv", .stage = .{ .vertex = true } },
            .{ .path = "voxel.frag.spv", .stage = .{ .fragment = true } },
        },
        .instance_layout = .{
            .inputs = &.{
                .{ .type = .vec3, .offset = 0 }, // instance position
                .{ .type = .vec3, .offset = 3 * @sizeOf(f32) }, // instance texture indices 0
                .{ .type = .vec3, .offset = 6 * @sizeOf(f32) }, // instance texture indices 1
                .{ .type = .uint, .offset = 9 * @sizeOf(f32) }, // instance visibility
            },
            .stride = @sizeOf(World.BlockInstanceData),
        },
        .params = &.{
            .{ .name = "textures", .type = .image, .stage = .{ .fragment = true } },
            .{ .name = "shadowMap", .type = .image, .stage = .{ .fragment = true } },
            .{ .name = "light", .type = .buffer, .stage = .{ .vertex = true } },
        },
        .transparency = true,
    });
    defer rdr().freeRid(material);

    try rdr().materialSetParam(material, "textures", .{
        .image = .{
            .rid = registry.image_array orelse unreachable,
            .sampler = .{
                .mag_filter = .nearest, // Nearest is best for pixel art and voxels.
                .min_filter = .nearest,
            },
        },
    });
    try rdr().materialSetParam(material, "light", .{ .buffer = light_buffer });

    the_world = World.initEmpty(allocator, .{ .seed = args.options.seed });
    defer the_world.deinit();

    try the_world.createBuffers(15);
    try the_world.startWorkers(&registry);

    render_graph_pass.addImguiHook(&statsDebugHook);

    input.init(&window, &camera);

    while (window.running()) {
        if (std.time.microTimestamp() - last_update_time < time_between_update) {
            std.Thread.yield() catch {};
            continue;
        }
        last_update_time = std.time.microTimestamp();

        try tick(&the_world);
    }
}

fn tick(world: *World) !void {
    tracy.frameMark();

    const zone = tracy.beginZone(@src(), .{});
    defer zone.end();

    input.pollEvents();

    camera.updateCamera(world);

    // Rebuild the render pass
    const projection_matrix = camera.projection_matrix;

    // TODO: Move projection calculation in Camera.zig

    camera.projection_matrix = projection_matrix;

    // Record draw calls into the render pass
    render_graph_pass.reset();

    const light_proj_bound: f32 = 100.0;

    const light_proj = zm.orthographicOffCenterRh(-light_proj_bound, light_proj_bound, -light_proj_bound, light_proj_bound, 0.01, 1000.0);
    const light_pos = -(camera.position + zm.Vec{ 0.0, 0.0, -100.0, 0.0 });
    const light_translation = zm.translationV(light_pos);

    const light_rotation: zm.Vec = .{ std.math.pi / 2.0, 0.0, 0.0, 0.0 };
    const light_rot_matrix = zm.mul(zm.rotationY(light_rotation[1]), zm.rotationX(light_rotation[0]));

    light_matrix = zm.mul(zm.mul(light_translation, light_rot_matrix), light_proj);

    const light_data: LightData = .{
        .matrix = zm.matToArr(light_matrix),
        .position = zm.vecToArr3(light_pos),
    };
    try light_buffer.update(std.mem.sliceAsBytes(@as([*]const LightData, @ptrCast(&light_data))[0..1]), 0);

    try the_world.encodeDrawCalls(&camera, cube_mesh, &render_graph_pass, material, camera.getViewProjMatrix(), light_matrix);

    skybox.encodeDraw(&render_graph_pass);

    const stats = rdr().getStatistics();

    var buf: [64]u8 = undefined;
    try text.set(std.fmt.bufPrint(&buf, "{d:.2} ms", .{stats.gpu_time}) catch &.{}, .{ 0.0, 0.0, 0.0 }, 0.1);

    text.draw(&render_graph_pass);

    try rdr().processGraph(&graph);
}

fn statsDebugHook(render_pass: *Graph.RenderPass) void {
    _ = render_pass;

    if (c.ImGui_Begin("Statistics", null, 0)) {
        const stats = rdr().getStatistics();

        var buf: [128]u8 = undefined;

        c.ImGui_Text("Primitves  : %zu", stats.primitives_drawn);
        c.ImGui_Text("GPU Time   : %.2f", stats.gpu_time);
        c.ImGui_Text("GPU Memory : %s", (std.fmt.bufPrintZ(&buf, "{:.2}", .{std.fmt.fmtIntSizeBin(@intCast(stats.vram_used))}) catch unreachable).ptr);
    }
    c.ImGui_End();
}

// TODO: Ultimately web/desktop should share there main function!

pub fn mainEmscripten() !void {
    var window = try Window.create(.{
        .title = "ft_vox",
        .width = 1280,
        .height = 720,
        .driver = .gles,
        .resizable = true,
        .allocator = allocator,
    });
    defer window.deinit();

    try Renderer.create(allocator, .gles);
    try rdr().createDevice(&window, null);

    cube_mesh = try createCube();

    material = try rdr().materialCreate(.{
        .shaders = &.{
            .{ .path = "basic_cube.vert.spv", .stage = .{ .vertex = true } },
            .{ .path = "basic_cube.frag.spv", .stage = .{ .fragment = true } },
        },
    });

    render_graph_pass = try .create(allocator, rdr().getOutputRenderPass(), .{
        .max_draw_calls = 10,
    });
    graph = .init(allocator);
    graph.main_render_pass = &render_graph_pass;

    c.emscripten_request_animation_frame_loop(&tickEmscripten, null);
}

fn tickEmscripten(delta: f64, _: ?*anyopaque) callconv(.c) bool {
    _ = delta;

    render_graph_pass.reset();

    const mat = zm.identity();
    render_graph_pass.draw(cube_mesh, material, 0, rdr().meshGetIndicesCount(cube_mesh), mat);

    rdr().processGraph(&graph) catch {};

    return true;
}

pub const main = if (builtin.cpu.arch.isWasm())
    mainEmscripten
else
    mainDesktop;

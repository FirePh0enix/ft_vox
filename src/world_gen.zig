const std = @import("std");
const zm = @import("zmath");
const math = @import("math.zig");
const dcimgui = @import("dcimgui");

const Allocator = std.mem.Allocator;
const World = @import("voxel/World.zig");
const Chunk = @import("voxel/Chunk.zig");
const Registry = @import("voxel/Registry.zig");
const Renderer = @import("render/Renderer.zig");
const RID = Renderer.RID;
const Graph = @import("render/Graph.zig");
const Biome = @import("Biome.zig");

const rdr = Renderer.rdr;

var temp_image_rid: RID = undefined;
var hum_image_rid: RID = undefined;
var c_image_rid: RID = undefined;
var e_image_rid: RID = undefined;
var w_image_rid: RID = undefined;
var pv_image_rid: RID = undefined;
var h_image_rid: RID = undefined;
var biome_image_rid: RID = undefined;

var temp_imgui_id: c_ulonglong = undefined;
var hum_imgui_id: c_ulonglong = undefined;
var c_imgui_id: c_ulonglong = undefined;
var e_imgui_id: c_ulonglong = undefined;
var w_imgui_id: c_ulonglong = undefined;
var pv_imgui_id: c_ulonglong = undefined;
var h_imgui_id: c_ulonglong = undefined;
var biome_imgui_id: c_ulonglong = undefined;

const air = 0;
const water = 1;
const deep_water = 2;
const stone = 3;
const dirt = 4;
const grass = 5;
const savanna_dirt = 6;
const snow_dirt = 7;
const sand = 8;
const snow = 9;

pub fn generateWorld(allocator: Allocator, registry: *const Registry, settings: World.GenerationSettings) !World {
    const world = World.initEmpty(allocator, settings);

    const width = 22;
    const depth = 22;

    // math.noise.seed(seed);

    _ = registry;

    var temp_pixels: [width * 16 * depth * 16]u32 = undefined;
    var hum_pixels: [width * 16 * depth * 16]u8 = undefined;
    var c_pixels: [width * 16 * depth * 16]u8 = undefined;
    var e_pixels: [width * 16 * depth * 16]u8 = undefined;
    var w_pixels: [width * 16 * depth * 16]u8 = undefined;
    var pv_pixels: [width * 16 * depth * 16]u8 = undefined;
    var h_pixels: [width * 16 * depth * 16]u8 = undefined;
    var biome_pixels: [width * 16 * depth * 16]u32 = undefined;

    for (0..width * 16) |z| {
        for (0..depth * 16) |x| {
            const fx: f32 = @floatFromInt(x);
            const fz: f32 = @floatFromInt(z);

            const noise = Biome.getNoise(&world, fx, fz);

            const temp_level = Biome.getTemperatureLevel(noise.temperature);
            temp_pixels[x + z * (width * 16)] = temp_level.getColor();

            const hum_level: f32 = @as(f32, @floatFromInt(Biome.getHumidityLevel(noise.humidity))) / 5.0;
            hum_pixels[x + z * (width * 16)] = @intFromFloat(hum_level * 255);

            // const c_level = @as(f32, @floatFromInt(@intFromEnum(getContinentalnessLevel(noise.continentalness)))) / 6.0;
            // c_pixels[x + z * (width * 16)] = @intFromFloat(c_level * 255);

            const c_level = (noise.continentalness + 1) / 2;
            c_pixels[x + z * (width * 16)] = @intFromFloat(c_level * 255);

            const erosion_level: f32 = @as(f32, @floatFromInt(Biome.getErosionLevel(noise.erosion))) / 6.0;
            e_pixels[x + z * (width * 16)] = @intFromFloat(erosion_level * 255);

            w_pixels[x + z * (width * 16)] = @intFromFloat((noise.weirdness + 1) / 2 * 255);
            pv_pixels[x + z * (width * 16)] = @intFromFloat((noise.peaks_and_valleys + 1) / 2 * 255);

            // h_pixels[x + z * (width * 16)] = @intCast(generateHeight(@floatFromInt(x), @floatFromInt(z), @floatFromInt(settings.sea_level)));

            const biome = Biome.getBiome(noise);
            biome_pixels[x + z * (width * 16)] = biome.getColor();
        }
    }

    const w = 16 * 22;

    temp_image_rid = try rdr().imageCreate(.{ .width = w, .height = w, .format = .b8g8r8a8_srgb });
    temp_imgui_id = try rdr().imguiAddTexture(temp_image_rid, .shader_read_only_optimal);
    try rdr().imageSetLayout(temp_image_rid, .transfer_dst_optimal);
    try rdr().imageUpdate(temp_image_rid, std.mem.sliceAsBytes(&temp_pixels), 0, 0);
    try rdr().imageSetLayout(temp_image_rid, .shader_read_only_optimal);

    hum_image_rid = try rdr().imageCreate(.{ .width = w, .height = w, .format = .r8_srgb, .pixel_mapping = .grayscale });
    hum_imgui_id = try rdr().imguiAddTexture(hum_image_rid, .shader_read_only_optimal);
    try rdr().imageSetLayout(hum_image_rid, .transfer_dst_optimal);
    try rdr().imageUpdate(hum_image_rid, std.mem.sliceAsBytes(&hum_pixels), 0, 0);
    try rdr().imageSetLayout(hum_image_rid, .shader_read_only_optimal);

    c_image_rid = try rdr().imageCreate(.{ .width = w, .height = w, .format = .r8_srgb, .pixel_mapping = .grayscale });
    c_imgui_id = try rdr().imguiAddTexture(c_image_rid, .shader_read_only_optimal);
    try rdr().imageSetLayout(c_image_rid, .transfer_dst_optimal);
    try rdr().imageUpdate(c_image_rid, std.mem.sliceAsBytes(&c_pixels), 0, 0);
    try rdr().imageSetLayout(c_image_rid, .shader_read_only_optimal);

    e_image_rid = try rdr().imageCreate(.{ .width = w, .height = w, .format = .r8_srgb, .pixel_mapping = .grayscale });
    e_imgui_id = try rdr().imguiAddTexture(e_image_rid, .shader_read_only_optimal);
    try rdr().imageSetLayout(e_image_rid, .transfer_dst_optimal);
    try rdr().imageUpdate(e_image_rid, std.mem.sliceAsBytes(&e_pixels), 0, 0);
    try rdr().imageSetLayout(e_image_rid, .shader_read_only_optimal);

    w_image_rid = try rdr().imageCreate(.{ .width = w, .height = w, .format = .r8_srgb, .pixel_mapping = .grayscale });
    w_imgui_id = try rdr().imguiAddTexture(w_image_rid, .shader_read_only_optimal);
    try rdr().imageSetLayout(w_image_rid, .transfer_dst_optimal);
    try rdr().imageUpdate(w_image_rid, std.mem.sliceAsBytes(&w_pixels), 0, 0);
    try rdr().imageSetLayout(w_image_rid, .shader_read_only_optimal);

    pv_image_rid = try rdr().imageCreate(.{ .width = w, .height = w, .format = .r8_srgb, .pixel_mapping = .grayscale });
    pv_imgui_id = try rdr().imguiAddTexture(pv_image_rid, .shader_read_only_optimal);
    try rdr().imageSetLayout(pv_image_rid, .transfer_dst_optimal);
    try rdr().imageUpdate(pv_image_rid, std.mem.sliceAsBytes(&pv_pixels), 0, 0);
    try rdr().imageSetLayout(pv_image_rid, .shader_read_only_optimal);

    biome_image_rid = try rdr().imageCreate(.{ .width = w, .height = w, .format = .b8g8r8a8_srgb });
    biome_imgui_id = try rdr().imguiAddTexture(biome_image_rid, .shader_read_only_optimal);
    try rdr().imageSetLayout(biome_image_rid, .transfer_dst_optimal);
    try rdr().imageUpdate(biome_image_rid, std.mem.sliceAsBytes(&biome_pixels), 0, 0);
    try rdr().imageSetLayout(biome_image_rid, .shader_read_only_optimal);

    h_image_rid = try rdr().imageCreate(.{ .width = w, .height = w, .format = .r8_srgb, .pixel_mapping = .grayscale });
    h_imgui_id = try rdr().imguiAddTexture(h_image_rid, .shader_read_only_optimal);
    try rdr().imageSetLayout(h_image_rid, .transfer_dst_optimal);
    try rdr().imageUpdate(h_image_rid, std.mem.sliceAsBytes(&h_pixels), 0, 0);
    try rdr().imageSetLayout(h_image_rid, .shader_read_only_optimal);

    @import("root").render_graph_pass.addImguiHook(&debugHook);

    return world;
}

pub fn deinit() void {
    rdr().imguiRemoveTexture(temp_imgui_id);
    rdr().freeRid(temp_image_rid);

    rdr().imguiRemoveTexture(hum_imgui_id);
    rdr().freeRid(hum_image_rid);

    rdr().imguiRemoveTexture(c_imgui_id);
    rdr().freeRid(c_image_rid);

    rdr().imguiRemoveTexture(e_imgui_id);
    rdr().freeRid(e_image_rid);

    rdr().imguiRemoveTexture(w_imgui_id);
    rdr().freeRid(w_image_rid);

    rdr().imguiRemoveTexture(pv_imgui_id);
    rdr().freeRid(pv_image_rid);

    rdr().imguiRemoveTexture(biome_imgui_id);
    rdr().freeRid(biome_image_rid);

    rdr().imguiRemoveTexture(h_imgui_id);
    rdr().freeRid(h_image_rid);
}

fn debugHook(render_pass: *Graph.RenderPass) void {
    const x = -render_pass.view_matrix[0][3];
    const z = -render_pass.view_matrix[2][3];

    const noise = Biome.getNoise(&@import("root").the_world, x, z);

    if (dcimgui.ImGui_Begin("WorldGen", null, 0)) {
        dcimgui.ImGui_Text("t = %.2f | h = %.2f | c = %.2f | e = %.2f | d = ???\n", noise.temperature, noise.humidity, noise.continentalness, noise.erosion);
        dcimgui.ImGui_Text("w = %.2f | pv = %.2f | as = ??? | n = ???\n", noise.weirdness, noise.peaks_and_valleys);

        dcimgui.ImGui_Text("el = %d\n", Biome.getErosionLevel(noise.erosion));

        dcimgui.ImGui_Text("Temperature | Humidity\n");
        dcimgui.ImGui_Image(temp_imgui_id, .{ .x = 100, .y = 100 });
        dcimgui.ImGui_SameLine();
        dcimgui.ImGui_Image(hum_imgui_id, .{ .x = 100, .y = 100 });

        dcimgui.ImGui_Text("Continentalness | Erosion | Weirdness | Peaks & Valleys\n");
        dcimgui.ImGui_Image(c_imgui_id, .{ .x = 100, .y = 100 });
        dcimgui.ImGui_SameLine();
        dcimgui.ImGui_Image(e_imgui_id, .{ .x = 100, .y = 100 });
        dcimgui.ImGui_SameLine();
        dcimgui.ImGui_Image(w_imgui_id, .{ .x = 100, .y = 100 });
        dcimgui.ImGui_SameLine();
        dcimgui.ImGui_Image(pv_imgui_id, .{ .x = 100, .y = 100 });

        dcimgui.ImGui_Text("Biome | Final heightmap\n");
        dcimgui.ImGui_Image(biome_imgui_id, .{ .x = 100, .y = 100 });
        dcimgui.ImGui_SameLine();
        dcimgui.ImGui_Image(h_imgui_id, .{ .x = 100, .y = 100 });
    }
    dcimgui.ImGui_End();
}

// https://www.youtube.com/watch?v=CSa5O6knuwI
// https://minecraft.wiki/w/World_generation
// https://www.alanzucconi.com/2022/06/05/minecraft-world-generation/
// https://www.reddit.com/r/VoxelGameDev/comments/zedp39/how_does_minecraft_use_2d_and_3d_noise_to/

pub fn generateChunk(world: *const World, chunk_x: isize, chunk_z: isize) Chunk {
    var chunk: Chunk = .{ .position = .{ .x = chunk_x, .z = chunk_z } };

    for (0..16) |x| {
        for (0..16) |z| {
            const fx: f32 = @floatFromInt(chunk_x * 16 + @as(isize, @intCast(x)));
            const fz: f32 = @floatFromInt(chunk_z * 16 + @as(isize, @intCast(z)));

            const noise = Biome.getNoise(world, fx, fz);
            const biome = Biome.getBiome(noise);

            const blended = Biome.blendSplineAttributes(world, fx, fz);
            const baseLevel = blended.base_height;
            const squishFactor = blended.squish;

            for (0..256) |y| {
                const ny = @as(f32, @floatFromInt(y));
                const densityMod = (baseLevel - ny) * squishFactor;
                const density = world.noise.sample3D(fx / 200.0, ny / 80.0, fz / 200.0);

                // Place Block that fits to biome.
                // TODO: Place correctly top block and bottom block by detecting If there is something above.
                var block_id: u8 = switch (biome) {
                    .mushroom_fields => grass,
                    .stony_shore => stone,

                    .snowy_beach => snow,
                    .beach => sand,
                    .desert => sand,

                    .snowy_plains => snow,
                    .plains, .forest, .jungle => dirt,
                    .savanna => savanna_dirt,
                    .stony_peaks => stone,
                    .frozen_peaks => snow,
                    else => stone,
                };

                if (density + densityMod > 0.0) {
                    chunk.setBlockState(x, y, z, .{ .id = block_id });
                } else {
                    chunk.setBlockState(x, y, z, .{ .id = air });
                    // Choose top texture if it's the last block at top.
                    if (chunk.getBlockState(x, y - 1, z) != null and chunk.getBlockState(x, y - 1, z).?.id != air and chunk.getBlockState(x, y - 1, z).?.id != water) {
                        block_id = switch (biome) {
                            .mushroom_fields => grass,
                            .stony_shore => stone,

                            .snowy_beach => snow_dirt,
                            .beach => sand,
                            .desert => sand,

                            .snowy_plains => snow_dirt,
                            .plains, .forest, .jungle => grass,
                            .savanna => savanna_dirt,
                            .stony_peaks => stone,
                            .frozen_peaks => snow,
                            else => stone,
                        };
                        chunk.setBlockState(x, y - 1, z, .{ .id = block_id });
                    }
                }

                if (y < world.generation_settings.sea_level) {
                    for (y..world.generation_settings.sea_level) |s| {
                        chunk.setBlockState(x, s, z, .{ .id = water });
                    }
                }
            }
        }
    }

    return chunk;
}

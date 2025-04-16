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

pub fn generateWorld(allocator: Allocator, registry: *const Registry, settings: World.GenerationSettings) !World {
    const seed = settings.seed orelse @as(u64, @bitCast(std.time.timestamp()));
    const world = World.initEmpty(allocator, seed, settings);

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

            const noise = getNoise(&world, fx, fz);

            const temp_level = getTemperatureLevel(noise.temperature);
            temp_pixels[x + z * (width * 16)] = temp_level.getColor();

            const hum_level: f32 = @as(f32, @floatFromInt(getHumidityLevel(noise.humidity))) / 5.0;
            hum_pixels[x + z * (width * 16)] = @intFromFloat(hum_level * 255);

            // const c_level = @as(f32, @floatFromInt(@intFromEnum(getContinentalnessLevel(noise.continentalness)))) / 6.0;
            // c_pixels[x + z * (width * 16)] = @intFromFloat(c_level * 255);

            const c_level = (noise.continentalness + 1) / 2;
            c_pixels[x + z * (width * 16)] = @intFromFloat(c_level * 255);

            const erosion_level: f32 = @as(f32, @floatFromInt(getErosionLevel(noise.erosion))) / 6.0;
            e_pixels[x + z * (width * 16)] = @intFromFloat(erosion_level * 255);

            w_pixels[x + z * (width * 16)] = @intFromFloat((noise.weirdness + 1) / 2 * 255);
            pv_pixels[x + z * (width * 16)] = @intFromFloat((noise.peaks_and_valleys + 1) / 2 * 255);

            // h_pixels[x + z * (width * 16)] = @intCast(generateHeight(@floatFromInt(x), @floatFromInt(z), @floatFromInt(settings.sea_level)));

            const biome = getBiome(noise);
            biome_pixels[x + z * (width * 16)] = biome.getColor();
        }
    }

    const w = 16 * 22;

    temp_image_rid = try rdr().imageCreate(.{ .width = w, .height = w, .format = .b8g8r8a8_srgb });
    temp_imgui_id = try rdr().imguiAddTexture(temp_image_rid);
    try rdr().imageSetLayout(temp_image_rid, .transfer_dst_optimal);
    try rdr().imageUpdate(temp_image_rid, std.mem.sliceAsBytes(&temp_pixels), 0, 0);
    try rdr().imageSetLayout(temp_image_rid, .shader_read_only_optimal);

    hum_image_rid = try rdr().imageCreate(.{ .width = w, .height = w, .format = .r8_srgb, .pixel_mapping = .grayscale });
    hum_imgui_id = try rdr().imguiAddTexture(hum_image_rid);
    try rdr().imageSetLayout(hum_image_rid, .transfer_dst_optimal);
    try rdr().imageUpdate(hum_image_rid, std.mem.sliceAsBytes(&hum_pixels), 0, 0);
    try rdr().imageSetLayout(hum_image_rid, .shader_read_only_optimal);

    c_image_rid = try rdr().imageCreate(.{ .width = w, .height = w, .format = .r8_srgb, .pixel_mapping = .grayscale });
    c_imgui_id = try rdr().imguiAddTexture(c_image_rid);
    try rdr().imageSetLayout(c_image_rid, .transfer_dst_optimal);
    try rdr().imageUpdate(c_image_rid, std.mem.sliceAsBytes(&c_pixels), 0, 0);
    try rdr().imageSetLayout(c_image_rid, .shader_read_only_optimal);

    e_image_rid = try rdr().imageCreate(.{ .width = w, .height = w, .format = .r8_srgb, .pixel_mapping = .grayscale });
    e_imgui_id = try rdr().imguiAddTexture(e_image_rid);
    try rdr().imageSetLayout(e_image_rid, .transfer_dst_optimal);
    try rdr().imageUpdate(e_image_rid, std.mem.sliceAsBytes(&e_pixels), 0, 0);
    try rdr().imageSetLayout(e_image_rid, .shader_read_only_optimal);

    w_image_rid = try rdr().imageCreate(.{ .width = w, .height = w, .format = .r8_srgb, .pixel_mapping = .grayscale });
    w_imgui_id = try rdr().imguiAddTexture(w_image_rid);
    try rdr().imageSetLayout(w_image_rid, .transfer_dst_optimal);
    try rdr().imageUpdate(w_image_rid, std.mem.sliceAsBytes(&w_pixels), 0, 0);
    try rdr().imageSetLayout(w_image_rid, .shader_read_only_optimal);

    pv_image_rid = try rdr().imageCreate(.{ .width = w, .height = w, .format = .r8_srgb, .pixel_mapping = .grayscale });
    pv_imgui_id = try rdr().imguiAddTexture(pv_image_rid);
    try rdr().imageSetLayout(pv_image_rid, .transfer_dst_optimal);
    try rdr().imageUpdate(pv_image_rid, std.mem.sliceAsBytes(&pv_pixels), 0, 0);
    try rdr().imageSetLayout(pv_image_rid, .shader_read_only_optimal);

    biome_image_rid = try rdr().imageCreate(.{ .width = w, .height = w, .format = .b8g8r8a8_srgb });
    biome_imgui_id = try rdr().imguiAddTexture(biome_image_rid);
    try rdr().imageSetLayout(biome_image_rid, .transfer_dst_optimal);
    try rdr().imageUpdate(biome_image_rid, std.mem.sliceAsBytes(&biome_pixels), 0, 0);
    try rdr().imageSetLayout(biome_image_rid, .shader_read_only_optimal);

    h_image_rid = try rdr().imageCreate(.{ .width = w, .height = w, .format = .r8_srgb, .pixel_mapping = .grayscale });
    h_imgui_id = try rdr().imguiAddTexture(h_image_rid);
    try rdr().imageSetLayout(h_image_rid, .transfer_dst_optimal);
    try rdr().imageUpdate(h_image_rid, std.mem.sliceAsBytes(&h_pixels), 0, 0);
    try rdr().imageSetLayout(h_image_rid, .shader_read_only_optimal);

    @import("root").render_graph_pass.addImguiHook(&debugHook);

    return world;
}

fn debugHook(render_pass: *Graph.RenderPass) void {
    const x = -render_pass.view_matrix[0][3];
    const z = -render_pass.view_matrix[2][3];

    const noise = getNoise(&@import("root").the_world, x, z);

    dcimgui.ImGui_Text("t = %.2f | h = %.2f | c = %.2f | e = %.2f | d = ???\n", noise.temperature, noise.humidity, noise.continentalness, noise.erosion);
    dcimgui.ImGui_Text("w = %.2f | pv = %.2f | as = ??? | n = ???\n", noise.weirdness, noise.peaks_and_valleys);

    dcimgui.ImGui_Text("el = %d\n", getErosionLevel(noise.erosion));

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

const air = 0;
const dirt = 1;
const grass = 2;
const water = 3;
const stone = 4;
const sand = 5;

pub fn generateChunk(world: *const World, settings: World.GenerationSettings, chunk_x: isize, chunk_z: isize) !Chunk {
    var chunk: Chunk = .{ .position = .{ .x = chunk_x, .z = chunk_z } };

    for (0..16) |x| {
        for (0..16) |z| {
            const fx: f32 = @floatFromInt(chunk_x * 16 + @as(isize, @intCast(x)));
            const fz: f32 = @floatFromInt(chunk_z * 16 + @as(isize, @intCast(z)));

            const baseLevel: f32 = getSplineLevel(world, fx, fz);
            const squishFactor: f32 = getSplineFactor(world, fx, fz);

            _ = settings;

            for (0..64) |y| {
                const densityMod: f32 = (baseLevel - @as(f32, @floatFromInt(y))) * squishFactor;
                const density: f32 = world.noise.sample3D(fx, @floatFromInt(y), fz);

                if (density + densityMod > 0.0) {
                    chunk.setBlockState(x, y, z, .{ .id = stone });
                } else {
                    chunk.setBlockState(x, y, z, .{ .id = grass });
                }
            }

            // if (height < settings.sea_level) {
            //     for (height..settings.sea_level) |y| {
            //         chunk.setBlockState(x, y, z, .{ .id = water });
            //     }
            // }
        }
    }

    return chunk;
}

// https://www.youtube.com/watch?v=CSa5O6knuwI
// https://minecraft.wiki/w/World_generation
// https://www.alanzucconi.com/2022/06/05/minecraft-world-generation/

pub fn getSplineLevel(world: *const World, x: f32, z: f32) f32 {
    const baseLevelHeight: u32 = 25;

    const noise = getNoise(world, x, z);

    const c_height = calculateContHeight(noise.continentalness);
    const e_height = calculateEroHeight(noise.erosion);
    const pv_height = calculatePeaksValleyHeight(noise.peaks_and_valleys);

    return c_height + e_height + pv_height + baseLevelHeight;
}

fn calculateContHeight(cont: f32) f32 {
    if (cont >= -1 and cont < 0.3) {
        return 50.0;
    } else if (cont >= 0.3 and cont < 0.4) {
        const t = (cont - 0.3) / 0.1;
        return 50.0 + t * 50.0;
    } else if (cont >= 0.4 and cont <= 1.0) {
        const t = (cont - 0.4) / 0.6;

        return 100.0 + t * 50.0;
    }
    return 50.0;
}

fn calculateEroHeight(cont: f32) f32 {
    if (cont >= -1 and cont < 0.3) {
        return 25.0;
    } else if (cont >= 0.3 and cont < 0.4) {
        const t = (cont - 0.3) / 0.1;
        return 25.0 + t * 25.0;
    } else if (cont >= 0.4 and cont <= 1.0) {
        const t = (cont - 0.4) / 0.6;

        return 50.0 + t * 25.0;
    }
    return 25.0;
}

fn calculatePeaksValleyHeight(cont: f32) f32 {
    if (cont >= -1 and cont < 0.3) {
        return 12.5;
    } else if (cont >= 0.3 and cont < 0.4) {
        const t = (cont - 0.3) / 0.1;
        return 12.5 + t * 12.5;
    } else if (cont >= 0.4 and cont <= 1.0) {
        const t = (cont - 0.4) / 0.6;

        return 25.0 + t * 12.5;
    }
    return 12.5;
}

pub fn getSplineFactor(world: *const World, x: f32, z: f32) f32 {
    const factorWeight = 0.1;

    const c = getContinentalness(world, x, z);
    const e = getErosion(world, x, z);
    const pv = getWeirdness(world, x, z);

    return factorWeight + c + e + pv;
}

pub const Noise = struct {
    temperature: f32,
    humidity: f32,
    continentalness: f32,
    erosion: f32,

    weirdness: f32,
    peaks_and_valleys: f32,
};

pub fn getNoise(world: *const World, x: f32, z: f32) Noise {
    const w = getWeirdness(world, x, z);

    return .{
        .temperature = getTemperature(world, x, z),
        .humidity = getHumidity(world, x, z),
        .continentalness = getContinentalness(world, x, z),
        .erosion = getErosion(world, x, z),
        .weirdness = w,
        .peaks_and_valleys = 1.0 - @abs(3.0 * @abs(w) - 2.0),
    };
}

fn getContinentalness(world: *const World, x: f32, z: f32) f32 {
    return world.noise.fractal2D(4, x / 400.0, z / 400.0);
}

pub const Continentalness = enum(u32) {
    deep_ocean,
    ocean,
    coast,
    near_inland,
    mid_inland,
    far_inland,
};

pub fn getContinentalnessLevel(c: f32) Continentalness {
    if (c >= -1.0 and c < -0.455) {
        return .deep_ocean;
    } else if (c >= -0.455 and c < -0.19) {
        return .ocean;
    } else if (c >= -0.19 and c < -0.11) {
        return .coast;
    } else if (c >= -0.11 and c < 0.03) {
        return .near_inland;
    } else if (c >= 0.03 and c < 0.3) {
        return .mid_inland;
    } else {
        return .far_inland;
    }
}

fn getErosion(world: *const World, x: f32, z: f32) f32 {
    return world.noise.fractal2D(2, x / 600.0, z / 600.0);
}

pub fn getErosionLevel(e: f32) u32 {
    std.debug.assert(e >= -1.0 and e <= 1.0);

    if (e >= -1.0 and e < -0.78) {
        return 0;
    } else if (e >= -0.78 and e < -0.375) {
        return 1;
    } else if (e >= -0.375 and e < -0.2225) {
        return 2;
    } else if (e >= -0.2225 and e < 0.05) {
        return 3;
    } else if (e >= 0.05 and e < 0.45) {
        return 4;
    } else if (e >= 0.45 and e < 0.55) {
        return 5;
    } else {
        return 6;
    }
}

fn getWeirdness(world: *const World, x: f32, z: f32) f32 {
    return world.noise.fractal2D(3, x / 200.0, z / 200.0);
}

pub const PeakValleys = enum(u32) {
    valleys,
    low,
    mid,
    high,
    peaks,
};

pub fn getPeaksValleysLevel(pv: f32) PeakValleys {
    if (pv >= -1.0 and pv < -0.85) {
        return .valleys;
    } else if (pv >= -0.85 and pv < -0.6) {
        return .low;
    } else if (pv >= -0.6 and pv < 0.2) {
        return .mid;
    } else if (pv >= 0.2 and pv < -0.7) {
        return .high;
    } else {
        return .peaks;
    }
}

fn getHumidity(world: *const World, x: f32, z: f32) f32 {
    return world.noise.fractal2D(2, x / 350.0, z / 350.0);
}

pub fn getHumidityLevel(hum: f32) u32 {
    std.debug.assert(hum >= -1.0 and hum <= 1.0);

    if (hum >= -1.0 and hum < -0.35) {
        return 0;
    } else if (hum >= -0.35 and hum < -0.1) {
        return 1;
    } else if (hum >= -0.1 and hum < 0.1) {
        return 2;
    } else if (hum >= 0.1 and hum < 0.3) {
        return 3;
    } else {
        return 4;
    }
}

fn getTemperature(world: *const World, x: f32, z: f32) f32 {
    return world.noise.fractal2D(1, x / 300.0, z / 300.0);
}

pub fn getTemperatureLevel(temp: f32) Temperature {
    std.debug.assert(temp >= -1.0 and temp <= 1.0);

    if (temp >= -1.0 and temp < -0.8) {
        return .coldest;
    } else if (temp >= -0.8 and temp < -0.15) {
        return .cold;
    } else if (temp >= -0.15 and temp < 0.2) {
        return .mid;
    } else if (temp >= 0.2 and temp < 0.55) {
        return .hot;
    } else {
        return .hottest;
    }
}

pub const Temperature = enum(u32) {
    coldest = 0,
    cold = 1,
    mid = 2,
    hot = 3,
    hottest = 4,

    pub fn getColor(self: Temperature) u32 {
        return switch (self) {
            .coldest => 0xffa5e2fa,
            .cold => 0xff1673c9,
            .mid => 0xff7f868f,
            .hot => 0xffeb7457,
            .hottest => 0xffd92118,
        };
    }
};

pub const Biome = enum {
    deep_ocean,
    ocean,
    cold_ocean,

    river,
    plains,

    mountains,
    cold_mountains,

    pub fn getColor(self: Biome) u32 {
        return switch (self) {
            .deep_ocean => 0xff212138,
            .ocean => 0xff030364,
            .cold_ocean => 0xff0e5682,

            .river => 0xff1313d2,
            .plains => 0xff87aa5e,

            .mountains => 0xff5e4232,
            .cold_mountains => 0xff63564f,
        };
    }
};

pub fn getBiome(noise: Noise) Biome {
    const cont_level = getContinentalnessLevel(noise.continentalness);
    const pv_level = getPeaksValleysLevel(noise.peaks_and_valleys);
    const temp_level = getTemperatureLevel(noise.temperature);
    const ero_level = getErosionLevel(noise.erosion);

    return switch (cont_level) {
        .deep_ocean => .deep_ocean,
        .ocean => switch (temp_level) {
            .coldest => .cold_ocean,
            .cold, .mid, .hot, .hottest => .ocean,
        },
        .coast => switch (pv_level) {
            .valleys => .river,
            .low, .mid => .plains,
            .high, .peaks => switch (temp_level) {
                .coldest => .cold_mountains,
                .cold, .mid, .hot, .hottest => .mountains,
            },
        },
        .near_inland => switch (pv_level) {
            .valleys => .river,
            .low => .plains,
            .mid, .high, .peaks => switch (temp_level) {
                .coldest => .cold_mountains,
                .cold, .mid, .hot, .hottest => .mountains,
            },
        },
        .mid_inland => switch (pv_level) {
            .valleys => if (ero_level >= 2) .river else .plains,
            .low, .mid => .plains,
            .high, .peaks => switch (temp_level) {
                .coldest => .cold_mountains,
                .cold, .mid, .hot, .hottest => .mountains,
            },
        },
        .far_inland => switch (pv_level) {
            .valleys => if (ero_level >= 2) .river else .plains,
            .low, .mid => .plains,
            .high, .peaks => switch (temp_level) {
                .coldest => .cold_mountains,
                .cold, .mid, .hot, .hottest => .mountains,
            },
        },
    };
}

const std = @import("std");
const zm = @import("zmath");
const math = @import("math.zig");

const Allocator = std.mem.Allocator;
const World = @import("voxel/World.zig");
const Chunk = @import("voxel/Chunk.zig");
const Registry = @import("voxel/Registry.zig");
const Renderer = @import("render/Renderer.zig");

const rdr = Renderer.rdr;

pub fn generateWorld(allocator: Allocator, registry: *const Registry, settings: World.GenerationSettings) !World {
    const seed = settings.seed orelse @as(u64, @bitCast(std.time.timestamp()));
    var world = World.initEmpty(allocator, seed, settings);

    const width = 22;
    const depth = 22;

    // math.noise.seed(seed);

    _ = registry;

    for (0..depth) |z| {
        for (0..width) |x| {
            try world.loadChunk(.{ .x = @intCast(x), .z = @intCast(z) });
        }
    }

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

            const noise = getNoise(fx, fz);

            const temp_level = getTemperatureLevel(noise.temperature);
            temp_pixels[x + z * (width * 16)] = temp_level.getColor();

            const hum_level: f32 = @as(f32, @floatFromInt(getHumidityLevel(noise.humidity))) / 5.0;
            hum_pixels[x + z * (width * 16)] = @intFromFloat(hum_level * 255);

            const c_level = @as(f32, @floatFromInt(@intFromEnum(getContinentalnessLevel(noise.continentalness)))) / 6.0;
            c_pixels[x + z * (width * 16)] = @intFromFloat(c_level * 255);

            const erosion_level: f32 = @as(f32, @floatFromInt(getErosionLevel(noise.erosion))) / 6.0;
            e_pixels[x + z * (width * 16)] = @intFromFloat(erosion_level * 255);

            w_pixels[x + z * (width * 16)] = @intFromFloat((noise.weirdness + 1) / 2 * 255);
            pv_pixels[x + z * (width * 16)] = @intFromFloat((noise.peaks_and_valleys + 1) / 2 * 255);

            h_pixels[x + z * (width * 16)] = @intCast(generateHeight(@intCast(x), @intCast(z)));

            const biome = getBiome(noise);
            biome_pixels[x + z * (width * 16)] = biome.getColor();
        }
    }

    try rdr().asVk().temp_noise_image.asVk().transferLayout(.undefined, .transfer_dst_optimal, .{ .color_bit = true });
    try rdr().asVk().temp_noise_image.update(0, std.mem.sliceAsBytes(&temp_pixels));
    try rdr().asVk().temp_noise_image.asVk().transferLayout(.transfer_dst_optimal, .shader_read_only_optimal, .{ .color_bit = true });

    try rdr().asVk().hum_noise_image.asVk().transferLayout(.undefined, .transfer_dst_optimal, .{ .color_bit = true });
    try rdr().asVk().hum_noise_image.update(0, &hum_pixels);
    try rdr().asVk().hum_noise_image.asVk().transferLayout(.transfer_dst_optimal, .shader_read_only_optimal, .{ .color_bit = true });

    try rdr().asVk().c_noise_image.asVk().transferLayout(.undefined, .transfer_dst_optimal, .{ .color_bit = true });
    try rdr().asVk().c_noise_image.update(0, &c_pixels);
    try rdr().asVk().c_noise_image.asVk().transferLayout(.transfer_dst_optimal, .shader_read_only_optimal, .{ .color_bit = true });

    try rdr().asVk().e_noise_image.asVk().transferLayout(.undefined, .transfer_dst_optimal, .{ .color_bit = true });
    try rdr().asVk().e_noise_image.update(0, &e_pixels);
    try rdr().asVk().e_noise_image.asVk().transferLayout(.transfer_dst_optimal, .shader_read_only_optimal, .{ .color_bit = true });

    try rdr().asVk().w_noise_image.asVk().transferLayout(.undefined, .transfer_dst_optimal, .{ .color_bit = true });
    try rdr().asVk().w_noise_image.update(0, &w_pixels);
    try rdr().asVk().w_noise_image.asVk().transferLayout(.transfer_dst_optimal, .shader_read_only_optimal, .{ .color_bit = true });

    try rdr().asVk().pv_noise_image.asVk().transferLayout(.undefined, .transfer_dst_optimal, .{ .color_bit = true });
    try rdr().asVk().pv_noise_image.update(0, &pv_pixels);
    try rdr().asVk().pv_noise_image.asVk().transferLayout(.transfer_dst_optimal, .shader_read_only_optimal, .{ .color_bit = true });

    try rdr().asVk().h_noise_image.asVk().transferLayout(.undefined, .transfer_dst_optimal, .{ .color_bit = true });
    try rdr().asVk().h_noise_image.update(0, &h_pixels);
    try rdr().asVk().h_noise_image.asVk().transferLayout(.transfer_dst_optimal, .shader_read_only_optimal, .{ .color_bit = true });

    try rdr().asVk().biome_noise_image.asVk().transferLayout(.undefined, .transfer_dst_optimal, .{ .color_bit = true });
    try rdr().asVk().biome_noise_image.update(0, std.mem.sliceAsBytes(&biome_pixels));
    try rdr().asVk().biome_noise_image.asVk().transferLayout(.transfer_dst_optimal, .shader_read_only_optimal, .{ .color_bit = true });

    return world;
}

// fn processChunk(settings: World.GenerationSettings, x: isize, z: isize, world: *World, world_mutex: *std.Thread.Mutex) void {
//     var chunk = try generateChunk(settings, x, z);
//     chunk.computeVisibility(null, null, null, null);

//     world_mutex.lock();
//     defer world_mutex.unlock();

//     world.chunks.put(world.allocator, .{ .x = @intCast(x), .z = @intCast(z) }, chunk) catch unreachable;
// }

pub fn generateChunk(settings: World.GenerationSettings, chunk_x: isize, chunk_z: isize) !Chunk {
    var chunk: Chunk = .{ .position = .{ .x = chunk_x, .z = chunk_z } };

    for (0..16) |x| {
        for (0..16) |z| {
            const height = generateHeight(chunk_x * 16 + @as(isize, @intCast(x)), chunk_z * 16 + @as(isize, @intCast(z)));

            for (0..height) |y| {
                chunk.setBlockState(x, y, z, .{ .id = 1 });

                if (y == height - 1) {
                    chunk.setBlockState(x, y, z, .{ .id = 2 });
                }
            }

            if (height < settings.sea_level) {
                for (height..settings.sea_level) |y| {
                    chunk.setBlockState(x, y, z, .{ .id = 3 });
                }
            }
        }
    }

    return chunk;
}

// https://www.youtube.com/watch?v=CSa5O6knuwI
// https://minecraft.wiki/w/World_generation
// https://www.alanzucconi.com/2022/06/05/minecraft-world-generation/

pub fn generateHeight(x: isize, z: isize) usize {
    const fx: f32 = @floatFromInt(x);
    const fz: f32 = @floatFromInt(z);

    const noise = getNoise(fx, fz);
    const biome = getBiome(noise);
    const continentalness = noise.continentalness;

    // Base height for each biome.
    const depth: f32 = switch (biome) {
        .deep_ocean => 52.0,
        .cold_ocean, .ocean => 62.0,
        .river => 62.0,
        .plains => 72.0,
        .mountains => 92.0,
        .cold_mountains => 112.0,
    };

    // Base scale for each biome.
    const scale: f32 = switch (biome) {
        .deep_ocean => 2.0,
        .cold_ocean, .ocean => 3.0,
        .river => 4.0,
        .plains => 6.0,
        .mountains => 40.0,
        .cold_mountains => 70.0,
    };

    // Continentalness * continentalness smooth the curve, so the mountain top are curved and not sharpy.
    const height = depth + (continentalness * continentalness) * scale;

    return @intFromFloat(@max(1.0, height));
}

pub const Noise = struct {
    temperature: f32,
    humidity: f32,
    continentalness: f32,
    erosion: f32,

    weirdness: f32,
    peaks_and_valleys: f32,
};

pub fn getNoise(x: f32, z: f32) Noise {
    const w = getWeirdness(x, z);

    return .{
        .temperature = getTemperature(x, z),
        .humidity = getHumidity(x, z),
        .continentalness = getContinentalness(x, z),
        .erosion = getErosion(x, z),
        .weirdness = w,
        .peaks_and_valleys = 1.0 - @abs(3.0 * @abs(w) - 2.0),
    };
}

fn getContinentalness(x: f32, z: f32) f32 {
    return math.noise.fractalNoise(4, x / 400.0, z / 400.0);
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

fn getErosion(x: f32, z: f32) f32 {
    return math.noise.fractalNoise(2, x / 600.0, z / 600.0);
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

fn getWeirdness(x: f32, z: f32) f32 {
    return math.noise.fractalNoise(3, x / 200.0, z / 200.0);
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

fn getHumidity(x: f32, z: f32) f32 {
    return math.noise.fractalNoise(2, x / 350.0, z / 350.0);
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

fn getTemperature(x: f32, z: f32) f32 {
    return math.noise.fractalNoise(1, x / 300.0, z / 300.0);
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

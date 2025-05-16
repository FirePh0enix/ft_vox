const std = @import("std");
const zigimg = @import("zigimg");
const dcimgui = @import("dcimgui");
const tracy = @import("tracy");

const World = @import("World.zig");
const Chunk = @import("Chunk.zig");
const Rgb24 = zigimg.color.Rgb24;
const SimplexNoise = @import("../math/noise.zig").SimplexNoiseWithOptions(f32);
const Graph = @import("../render/Graph.zig");

const air = 0;
const water = 1;
const stone = 2;
const dirt = 3;
const grass = 4;
const sand = 5;

pub fn generateChunk(world: *const World, x: i64, z: i64) Chunk {
    const zone = tracy.beginZone(@src(), .{});
    defer zone.end();

    var chunk: Chunk = .{ .position = .{ .x = x, .z = z } };

    const sea_level = world.generation_settings.sea_level;

    for (0..Chunk.length) |lx| {
        for (0..Chunk.length) |lz| {
            const fx: f32 = @floatFromInt(x * 16 + @as(i64, @intCast(lx)));
            const fz: f32 = @floatFromInt(z * 16 + @as(i64, @intCast(lz)));

            const noises = getNoises(&world.noise, fx, fz);
            const biome = getBiome(noises);

            const height = getHeight(sea_level, noises, fx, fz);

            const surface_block = getSurfaceBlock(biome);
            const fill_block = getFillBlock(biome);
            const fill_depth = 3;

            for (0..height - fill_depth - 1) |ly| {
                chunk.setBlockState(lx, ly, lz, .{ .id = stone });
            }

            for (height - fill_depth - 1..height - 1) |ly| {
                chunk.setBlockState(lx, ly, lz, .{ .id = fill_block });
            }

            chunk.setBlockState(lx, height - 1, lz, .{ .id = surface_block });

            // Creating caves.
            // https://www.youtube.com/watch?v=Ab8TOSFfNp4

            const cave_floor: f32 = 10.0;
            const cave_ceiling: f32 = 65.0;

            for (0..height) |y| {
                const fy: f32 = @floatFromInt(y);

                // The smaller the coefficient, the larger the cave entrance are.
                const cave_noise = world.noise.sample3D(fx * 0.03, fy * 0.03, fz * 0.03);

                // Summation raises height of the cave.
                // Multiplying scales the noise.
                const vertical_shape = world.noise.sample2D(fx * 0.1, fz * 0.1) * 5.0 + 20.0;

                if (fy > cave_floor and
                    fy < cave_ceiling and
                    cave_noise > 0.6 and // Higher Threshold means there will be less cave.
                    fy > vertical_shape)
                {
                    chunk.setBlockState(lx, y, lz, .{ .id = air });
                }
            }

            // Fill the rest with water
            if (height < sea_level) {
                for (height..sea_level) |ly| {
                    chunk.setBlockState(lx, ly, lz, .{ .id = water, .transparent = true });
                }
            }
        }
    }

    return chunk;
}

fn getSurfaceBlock(biome: Biome) u16 {
    return switch (biome) {
        .ocean, .river => sand,
        .beach => sand,
        .desert => sand,
        .plains => grass,
    };
}

fn getFillBlock(biome: Biome) u16 {
    return switch (biome) {
        .ocean, .river => sand,
        .beach => sand,
        .desert => sand,
        .plains => dirt,
    };
}

fn getHeight(sea_level: usize, noises: Noises, x: f32, z: f32) usize {
    _ = x;
    _ = z;

    const sea_levelf: f32 = @floatFromInt(sea_level);

    // Break the terrain smoothness with some noise.
    const ridge_value = remapValue(noises.ridge, -1.0, 1.0, -0.2, 1.0) * 1.0;

    const cont = noises.cont;
    const cont01 = (cont + 1.0) / 2.0;

    // Flatten land with some erosion
    const erosion = noises.erosion;
    // const erosion01 = (erosion + 1.0) / 2.0;

    // Create peaks, valleys and rivers
    const pv = remapValue(noises.peaks_and_valleys, -1.0, 1.0, -3.0, 1.0);
    // const pv01 = (pv + 1.0) / 2.0;

    const peaks_and_valleys = pv * cont01 * 20.0 * erosion * cont01 * 2.0;

    const value = sea_levelf + (cont + 0.19) * 40.0 + peaks_and_valleys + ridge_value;

    return @intFromFloat(value);
}

fn getDensity(noise: *const SimplexNoise, x: f32, y: f32, z: f32, height: f32) f32 {
    const y_damp = (1.0 - y / height) * 2.0;
    const scale = 1.0 / 100.0;
    return noise.fractal3D(4, x * scale, y * scale, z * scale) * y_damp;
}

const Biome = enum {
    ocean,
    river,
    beach,
    plains,
    desert,

    pub fn color(self: Biome) Rgb24 {
        return switch (self) {
            .ocean => .{ .r = 0, .g = 16, .b = 156 },
            .rivers => .{ .r = 0, .g = 25, .b = 247 },
            .beach => .{ .r = 247, .g = 202, .b = 0 },
            .plains => .{ .r = 2, .g = 222, .b = 17 },
            .desert => .{ .r = 212, .g = 171, .b = 6 },
        };
    }
};

const Continentalness = enum {
    deep_ocean,
    ocean,
    coast,
    near_inland,
    mid_inland,
    far_inland,

    pub fn color(self: Continentalness) Rgb24 {
        return switch (self) {
            .deep_ocean => .{ .r = 0, .g = 16, .b = 156 },
            .ocean => .{ .r = 0, .g = 25, .b = 247 },
            .coast => .{ .r = 247, .g = 202, .b = 0 },
            .near_inland => .{ .r = 2, .g = 222, .b = 17 },
            .mid_inland => .{ .r = 2, .g = 179, .b = 14 },
            .far_inland => .{ .r = 1, .g = 140, .b = 11 },
        };
    }
};

const Temperature = enum {
    freezing,
    cold,
    temperate,
    hot,
    burning,
};

fn getBiome(noises: Noises) Biome {
    return switch (noises.cont_level) {
        .deep_ocean, .ocean => .ocean,
        .coast => .beach,
        .near_inland, .mid_inland, .far_inland => switch (noises.temperature) {
            .freezing, .cold, .temperate => .plains,
            .hot, .burning => .desert,
        },
    };
}

const Noises = struct {
    cont: f32,
    cont_level: Continentalness,

    erosion: f32,
    weirdness: f32,
    peaks_and_valleys: f32,

    ridge: f32,

    // Use only by biomes
    temperature: Temperature,
};

fn getNoises(noise: *const SimplexNoise, x: f32, z: f32) Noises {
    const zone = tracy.beginZone(@src(), .{});
    defer zone.end();

    const cont = getContinentalness(noise, x, z);
    const cont_level = getContinentalnessLevel(cont);
    const erosion = getErosion(noise, x, z);
    const weirdness = getWeirdness(noise, x, z);
    const peaks_and_valleys = 1.0 - @abs(3.0 * @abs(weirdness) - 2.0);
    const ridge = getRidge(noise, x, z);
    const temperature = getTemperature(noise, x, z);

    return .{
        .cont = cont,
        .cont_level = cont_level,
        .erosion = erosion,
        .weirdness = weirdness,
        .peaks_and_valleys = peaks_and_valleys,
        .ridge = ridge,
        .temperature = temperature,
    };
}

fn getContinentalness(noise: *const SimplexNoise, x: f32, z: f32) f32 {
    return noise.fractal2D(5, x / 500.0, z / 500.0);
}

fn getContinentalnessLevel(c: f32) Continentalness {
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

fn getErosion(noise: *const SimplexNoise, x: f32, z: f32) f32 {
    return noise.fractal2D(4, x / 600.0, z / 600.0);
}

fn getWeirdness(noise: *const SimplexNoise, x: f32, z: f32) f32 {
    const scale = 1.0 / 100.0;
    return noise.fractal2D(3, x * scale, z * scale);
}

fn getRidge(noise: *const SimplexNoise, x: f32, z: f32) f32 {
    return noise.sample2D(x / 15.0, z / 15.0);
}

fn getTemperature(noise: *const SimplexNoise, x: f32, z: f32) Temperature {
    const v = noise.fractal2D(4, x / 800.0, z / 800.0);

    // -1.0          -0.8       -0.3            0.3      0.8        1.0
    //      freezing      cold      temperate       hot      burning

    if (v >= -1.0 and v < -0.8) {
        return .freezing;
    } else if (v >= -0.8 and v < -0.3) {
        return .cold;
    } else if (v >= -0.3 and v < 0.3) {
        return .temperate;
    } else if (v >= 0.3 and v < 0.8) {
        return .hot;
    } else {
        return .burning;
    }
}

inline fn remapValue(value: f32, low1: f32, high1: f32, low2: f32, high2: f32) f32 {
    return low2 + (value - low1) * (high2 - low2) / (high1 - low1);
}

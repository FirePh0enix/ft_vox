const std = @import("std");
const zigimg = @import("zigimg");

const World = @import("World.zig");
const Chunk = @import("Chunk.zig");
const Rgb24 = zigimg.color.Rgb24;
const SimplexNoise = @import("../math/noise.zig").SimplexNoiseWithOptions(f32);

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

pub fn generateChunk(world: *const World, x: i64, z: i64) !Chunk {
    var chunk: Chunk = .{ .position = .{ .x = x, .z = z } };

    const sea_level = world.generation_settings.sea_level;

    for (0..Chunk.length) |lx| {
        for (0..Chunk.length) |lz| {
            const fx: f32 = @floatFromInt(x * 16 + @as(i64, @intCast(lx)));
            const fz: f32 = @floatFromInt(z * 16 + @as(i64, @intCast(lz)));

            const noises = getNoises(&world.noise, fx, fz);
            const biome = getBiome(noises);

            const block: u16 = switch (biome) {
                .ocean => water,
                .rivers => water,
                .beach => sand,
                .plains => grass,
                .desert => sand,
            };

            for (0..sea_level) |ly| {
                chunk.setBlockState(lx, ly, lz, .{ .id = block });
            }
        }
    }

    return chunk;
}

const Biome = enum {
    ocean,
    rivers,
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

fn getBiome(noises: Noises) Biome {
    return switch (noises.cont_level) {
        .deep_ocean, .ocean => .ocean,
        .coast => .beach,
        .near_inland, .mid_inland, .far_inland => .plains,
    };
}

const Noises = struct {
    cont: f32,
    cont_level: Continentalness,
};

fn getNoises(noise: *const SimplexNoise, x: f32, z: f32) Noises {
    const cont = getContinentalness(noise, x, z);
    const cont_level = getContinentalnessLevel(cont);

    return .{
        .cont = cont,
        .cont_level = cont_level,
    };
}

fn getContinentalness(noise: *const SimplexNoise, x: f32, z: f32) f32 {
    return noise.fractal2D(5, x / 500.0, z / 500.0);
}

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

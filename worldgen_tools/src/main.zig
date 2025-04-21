const std = @import("std");
const zigimg = @import("zigimg");

const Rgb24 = zigimg.color.Rgb24;
const SimplexNoise = @import("noise.zig").SimplexNoiseWithOptions(f32);

const allocator = std.heap.smp_allocator;
const width = 1024; // 16384;
const seed = 1;

var prng: std.Random.DefaultPrng = undefined;
var rng: std.Random = undefined;

var noise: SimplexNoise = undefined;

pub fn main() !void {
    var image = try zigimg.Image.create(allocator, width, width, .rgb24);

    prng = .init(seed);
    rng = prng.random();

    noise = SimplexNoise.initWithSeed(seed);

    generateHeightmap(&image);

    const file = try std.fs.cwd().createFile("heightmap.png", .{});
    defer file.close();

    try image.writeToFile(file, .{ .png = .{} });
}

const blue: Rgb24 = .{ .r = 0, .b = 255, .g = 0 };
const green: Rgb24 = .{ .r = 0, .b = 0, .g = 255 };

fn generateHeightmap(image: *zigimg.Image) void {
    for (0..width) |x| {
        for (0..width) |z| {
            const fx: f32 = @floatFromInt(x);
            const fz: f32 = @floatFromInt(z);

            const noises = getNoises(fx, fz);
            const biome = getBiome(noises);

            image.pixels.rgb24[x + z * width] = biome.color();
        }
    }
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

fn getHeight(x: f32, z: f32) f32 {
    const scale_x = 0.01;
    const scale_z = 0.01;
    return noise.sample2D(x * scale_x, z * scale_z);
}

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

fn getNoises(x: f32, z: f32) Noises {
    const cont = getContinentalness(x, z);
    const cont_level = getContinentalnessLevel(cont);

    return .{
        .cont = cont,
        .cont_level = cont_level,
    };
}

fn getContinentalness(x: f32, z: f32) f32 {
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

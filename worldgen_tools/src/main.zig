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

            const height = getHeight(fx, fz);

            const color = if (height < 0.0)
                blue
            else
                green;

            image.pixels.rgb24[x + z * width] = color;
        }
    }
}

fn getHeight(x: f32, z: f32) f32 {
    const scale_x = 0.01;
    const scale_z = 0.01;
    return noise.sample2D(x * scale_x, z * scale_z);
}

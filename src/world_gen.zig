const std = @import("std");
const zm = @import("zmath");
const math = @import("math.zig");

const Allocator = std.mem.Allocator;
const World = @import("voxel/World.zig");
const Chunk = @import("voxel/Chunk.zig");
const Registry = @import("voxel/Registry.zig");

pub const Options = struct {
    seed: ?u64 = null,
    sea_level: u64 = 10,
};

pub fn generateWorld(allocator: Allocator, registry: *const Registry, options: Options) !World {
    const seed = options.seed orelse @as(u64, @bitCast(std.time.timestamp()));
    var world: World = .{ .allocator = allocator, .seed = seed };

    const width = 21;
    const depth = 21;

    for (0..depth) |z| {
        for (0..width) |x| {
            const chunk = try generateChunk(seed, options, @intCast(x), @intCast(z));
            try world.chunks.append(world.allocator, chunk);
        }
    }

    for (0..depth) |z| {
        for (0..width) |x| {
            const chunk = &world.chunks.items[x + z * width];
            chunk.computeVisibility(
                if (z > 0) &world.chunks.items[x + (z - 1) * width] else null,
                if (z < depth - 1) &world.chunks.items[x + (z + 1) * width] else null,
                if (x > 0) &world.chunks.items[(x - 1) + z * width] else null,
                if (x < width - 1) &world.chunks.items[(x + 1) + z * width] else null,
            );
            try chunk.rebuildInstanceBuffer(registry);
        }
    }

    return world;
}

fn generateChunk(seed: u64, options: Options, chunk_x: isize, chunk_z: isize) !Chunk {
    var chunk: Chunk = .{ .position = .{ .x = chunk_x, .z = chunk_z } };

    for (0..16) |x| {
        for (0..16) |z| {
            const height = generateHeight(seed, chunk_x * 16 + @as(isize, @intCast(x)), chunk_z * 16 + @as(isize, @intCast(z)));

            for (0..height) |y| {
                const cave_noise = math.noise.simplex3D(
                    @as(f32, chunk_x * 16 + x) / 25.0,
                    @as(f32, y) / 25.0,
                    @as(f32, chunk_z * 16 + z) / 25.0,
                );

                // 0 on video, probably need to decrease to -0.3, 0.4, 0.5...
                if (cave_noise < 0) {
                    // Air block (cave)
                    chunk.setBlockState(x, y, z, .{ .id = 0 });
                } else {
                    // Solid block
                    chunk.setBlockState(x, y, z, .{ .id = 1 });
                }
            }

            if (height < options.sea_level) {
                for (height..options.sea_level) |y| {
                    chunk.setBlockState(x, y, z, .{ .id = 2 });
                }
            }
        }
    }

    return chunk;
}

// https://www.youtube.com/watch?v=CSa5O6knuwI
// https://minecraft.wiki/w/World_generation
// TODO: For details and biome -> temperature and humidity.

pub fn generateHeight(seed: u64, x: isize, z: isize) usize {
    _ = seed;

    const fx: f32 = @floatFromInt(x);
    const fz: f32 = @floatFromInt(z);

    const scale: f32 = 20.0;
    const max_height: f32 = 20.0;

    const c_weight: f32 = 0.5;
    const e_weight: f32 = 0.3;
    const pv_weight: f32 = 0.1;
    const density_multiplier: f32 = 10.0;

    // used to decide between ocean/beach/land biomes. Higher values correspond to more inland biomes.
    const continentalness = math.noise.fractalNoise(fx / 150.0, fz / 150.0, 4);

    // used to decide between flat and mountainous biomes. When erosion is high the landscape is generally flat.
    const erosion = math.noise.fractalNoise(fx / 100.0, fz / 100.0, 3);

    const peaks_valleys = math.noise.fractalNoise(fx / 50.0, fz / 50.0, 2);

    // Calculate the terrain shape, allow to create some weird world with small scale variation.
    const density = math.noise.simplex3D(fx / scale, fz / scale, (continentalness * c_weight + erosion * e_weight + peaks_valleys * pv_weight) * density_multiplier);

    // Define the shape of the terrain.
    const squashing_factor = (continentalness * 0.5 + erosion * 0.3 + peaks_valleys * 0.1);

    // Increase the base height map overall.
    const height_offset = (continentalness * 0.5 - erosion * 0.3);

    // Final normalized height.
    const y = (squashing_factor + density * 0.1 + height_offset + 1.0) / 2.0 * max_height;
    const block_height: usize = @intFromFloat(y);

    // Ensure there is at least one block.
    return 1 + block_height;
}

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

            if (height < options.sea_level) {
                for (0..height) |y| {
                    chunk.setBlockState(x, y, z, .{ .id = 1 });
                }

                for (height..options.sea_level) |y| {
                    chunk.setBlockState(x, y, z, .{ .id = 2 });
                }
            } else {
                for (0..height) |y| {
                    chunk.setBlockState(x, y, z, .{ .id = 1 });
                }
            }

            // chunk.setBlockState(x, height - 1, z, .{ .id = 2 });
        }
    }

    return chunk;
}


// https://www.youtube.com/watch?v=CSa5O6knuwI
// https://minecraft.wiki/w/World_generation
// TODO: Add continentalness, erosion, peak and valleys.
// TODO: For details and biome, need 3d noise + temperature and humidity.
pub fn generateHeight(seed: u64, x: isize, z: isize) usize {
    _ = seed;

    const fx: f32 = @floatFromInt(x);
    const fz: f32 = @floatFromInt(z);

    const scale: f32 = 20.0;
    const max_height: f32 = 20.0;

    const y = (simplexOctaves(fx / scale, fz / scale, 3) + 1.0) / 2.0 * max_height;
    const block_height: usize = @intFromFloat(y);

    return 1 + block_height;
}

// TODO: Check how Octaves are actually made.
fn simplexOctaves(x: f32, z: f32, num: usize) f32 {
    var scale: f32 = 1.0;
    var res: f32 = 1.0;

    for (0..num) |index| {
        _ = index;
        res *= math.noise.simplex2D(x * scale, z * scale);
        scale /= 2;
    }

    return res;
}

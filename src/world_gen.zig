const std = @import("std");
const zm = @import("zmath");
const math = @import("math.zig");

const Allocator = std.mem.Allocator;
const World = @import("voxel/World.zig");
const Chunk = @import("voxel/Chunk.zig");
const Registry = @import("voxel/Registry.zig");

pub const Options = struct {
    seed: ?u64 = null,
};

pub fn generateWorld(allocator: Allocator, registry: *const Registry, options: Options) !World {
    const seed = options.seed orelse @as(u64, @bitCast(std.time.timestamp()));
    var world: World = .{ .allocator = allocator, .seed = seed };

    const width = 32;
    const depth = 32;

    for (0..width) |x| {
        for (0..depth) |z| {
            const chunk = try generateChunk(seed, @intCast(x), @intCast(z));
            try world.chunks.append(world.allocator, chunk);
        }
    }

    for (0..width) |x| {
        for (0..depth) |z| {
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

fn generateChunk(seed: u64, chunk_x: isize, chunk_z: isize) !Chunk {
    var chunk: Chunk = .{ .position = .{ .x = chunk_x, .z = chunk_z } };

    for (0..16) |x| {
        for (0..16) |z| {
            const height = generateHeight(seed, chunk_x * 16 + @as(isize, @intCast(x)), chunk_z * 16 + @as(isize, @intCast(z)));

            for (0..height) |y| {
                chunk.setBlockState(x, y, z, .{ .id = 2 });
            }
        }
    }

    return chunk;
}

pub fn generateHeight(seed: u64, x: isize, z: isize) usize {
    _ = seed;

    const fx: f32 = @floatFromInt(x);
    const fz: f32 = @floatFromInt(z);

    const scale: f32 = 20.0;
    const max_height: f32 = 10.0;

    const y = (math.noise.simplex2D(fx / scale, fz / scale) + 1.0) / 2.0 * max_height;
    const block_height: usize = @intFromFloat(@max(y, 8.0));

    return 1 + block_height;
}

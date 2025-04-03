const std = @import("std");
const zm = @import("zmath");
const world = @import("world.zig");
const math = @import("math.zig");

const Allocator = std.mem.Allocator;
const World = world.World;
const Chunk = world.Chunk;

pub const Options = struct {
    seed: ?u64 = null,
};

pub fn generateWorld(allocator: Allocator, options: Options) !World {
    const seed = options.seed orelse @as(u64, @bitCast(std.time.timestamp()));
    var the_world: World = .{ .allocator = allocator, .seed = seed };

    const width = 8;
    const depth = 8;

    for (0..width) |x| {
        for (0..depth) |z| {
            const chunk = try generateChunk(seed, @intCast(x), @intCast(z));
            try the_world.chunks.append(the_world.allocator, chunk);
        }
    }

    return the_world;
}

fn generateChunk(seed: u64, chunk_x: isize, chunk_z: isize) !Chunk {
    var chunk: Chunk = .{ .position = .{ .x = chunk_x, .z = chunk_z } };

    for (0..16) |x| {
        for (0..16) |z| {
            const height = generateHeight(seed, chunk_x * 16 + @as(isize, @intCast(x)), chunk_z * 16 + @as(isize, @intCast(z)));

            for (0..height) |y| {
                chunk.setBlockState(x, y, z, .{ .id = 1, .can_be_seen = true });
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

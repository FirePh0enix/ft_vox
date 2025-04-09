const std = @import("std");
const zm = @import("zmath");
const math = @import("math.zig");

const Allocator = std.mem.Allocator;
const World = @import("voxel/World.zig");
const Chunk = @import("voxel/Chunk.zig");
const Registry = @import("voxel/Registry.zig");

pub const Options = struct {
    seed: ?u64 = null,
    sea_level: u64 = 50,
};

pub fn generateWorld(allocator: Allocator, registry: *const Registry, options: Options) !World {
    const seed = options.seed orelse @as(u64, @bitCast(std.time.timestamp()));
    var world: World = .{ .allocator = allocator, .seed = seed };

    const width = 22;
    const depth = 22;

    // math.noise.seed(seed);

    var mutex: std.Thread.Mutex = .{};
    var jobs: std.ArrayList(std.Thread) = try .initCapacity(allocator, width * depth);

    for (0..depth) |z| {
        for (0..width) |x| {
            const job = try std.Thread.spawn(.{}, processChunk, .{ options, @as(isize, @intCast(x)), @as(isize, @intCast(z)), &world, &mutex });
            try jobs.append(job);
        }
    }

    for (jobs.items) |job| job.join();

    for (0..depth) |z| {
        for (0..width) |x| {
            const chunk = &world.chunks.items[x + z * width];
            try chunk.rebuildInstanceBuffer(registry);
        }
    }

    return world;
}

fn processChunk(options: Options, x: isize, z: isize, world: *World, world_mutex: *std.Thread.Mutex) void {
    var chunk = try generateChunk(options, x, z);
    chunk.computeVisibility(null, null, null, null);

    world_mutex.lock();
    defer world_mutex.unlock();

    world.chunks.append(world.allocator, chunk) catch unreachable;
}

fn generateChunk(options: Options, chunk_x: isize, chunk_z: isize) !Chunk {
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

            if (height < options.sea_level) {
                for (height..options.sea_level) |y| {
                    chunk.setBlockState(x, y, z, .{ .id = 3 });
                }
            }
        }
    }

    return chunk;
}

// https://www.youtube.com/watch?v=CSa5O6knuwI
// https://minecraft.wiki/w/World_generation
// TODO: For details and biome -> temperature and humidity.

pub fn generateHeight(x: isize, z: isize) usize {
    const fx: f32 = @floatFromInt(x);
    const fz: f32 = @floatFromInt(z);

    const max_height: f32 = 150.0;

    const continentalness: f32 = math.noise.fractalNoise(4, fx / 600.0, fz / 600.0);
    const erosion: f32 = math.noise.fractalNoise(2, fx / 300.0, fz / 300.0);
    const weirdness: f32 = math.noise.simplex3D(fx / 100.0, fz / 100.0, 0.0);

    const n_cont = (continentalness + 1) / 2;
    const n_ero = (erosion + 1) / 2;
    const n_weird = (weirdness + 1) / 2;

    const roughness = 1 - n_ero;
    const peaks_valleys = 1 - @abs(3 * @abs(n_weird) - 2.0);
    const mountain_variation = peaks_valleys * roughness * 0.5;

    const y = (n_cont + mountain_variation) * max_height;

    const final_height: usize = @intFromFloat(@max(y, 1.0));

    return final_height;
}

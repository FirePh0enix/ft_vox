const std = @import("std");
const zm = @import("zmath");
const math = @import("math.zig");

const Allocator = std.mem.Allocator;
const World = @import("voxel/World.zig");
const Chunk = @import("voxel/Chunk.zig");
const Registry = @import("voxel/Registry.zig");

pub const Options = struct {
    seed: ?u64 = null,
    sea_level: u64 = 51,
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
pub fn generateHeight(x: isize, z: isize) usize {
    const fx: f32 = @floatFromInt(x);
    const fz: f32 = @floatFromInt(z);

    // More scaling = more inlands.
    const continentalness: f32 = math.noise.fractalNoise(4, fx / 400.0, fz / 400.0);
    const base_height = calculateHeight(continentalness);

    // More scaling = more flat.
    const erosion: f32 = math.noise.fractalNoise(2, fx / 600.0, fz / 600.0);
    const n_ero = (erosion + 1) / 2;
    const roughness = 1 - n_ero;

    // More scaling = more distance between valleys.
    const peak_valley_noise: f32 = math.noise.simplex2D(fx / 200.0, fz / 200.0);
    const weirdness = (peak_valley_noise + 1) / 2;
    const peaks_valleys = 1 - (3 * (weirdness) - 2.0);

    var variation_scale: f32 = 0.1;

    // For local bumpyness, local means it will affect this mountain or this hill, not other.
    if (continentalness >= 0.4) {
        // Mountains
        variation_scale = 0.2;
    } else if (continentalness >= 0.3) {
        // Hills
        variation_scale = 0.15;
    }

    // Variation scale ensure that value is not too high and so height is not out of bounds.
    const variation = base_height * peaks_valleys * roughness * variation_scale;
    
    return @intFromFloat(@max(base_height + variation, 1.0));
}

fn calculateHeight(cont: f32) f32 {
    if (cont >= -1 and cont < 0.3) {
        return 50.0;
    } else if (cont >= 0.3 and cont < 0.4) {
        const t = (cont - 0.3) / 0.1;
        return 50.0 + t * 50.0;
    } else if (cont >= 0.4 and cont <= 1.0) {
        const t = (cont - 0.4) / 0.6;
        return 100.0 + t * 50.0;
    }
    return 50.0;
}

const std = @import("std");
const zm = @import("zmath");

const Self = @This();
const RenderFrame = @import("../voxel/RenderFrame.zig");
const Buffer = @import("../render/Buffer.zig");
const Allocator = std.mem.Allocator;
const BlockInstanceData = RenderFrame.BlockInstanceData;
const Registry = @import("Registry.zig");
const Chunk = @import("Chunk.zig");
const Ray = @import("../math.zig").Ray;

pub const Direction = enum(u3) {
    north = 0,
    south = 1,
    west = 2,
    east = 3,
    top = 4,
    down = 5,
};

pub const BlockState = packed struct(u32) {
    id: u16 = 0,

    visibility: u6 = ~@as(u6, 0),
    direction: Direction = .north,

    _padding: u7 = 0,
};

pub const BlockPos = struct {
    x: i64,
    y: i64,
    z: i64,
};

pub const RaycastResult = union(enum) {
    block: struct {
        state: BlockState,
        pos: BlockPos,
    },
};

pub const ChunkPos = struct {
    x: i64,
    z: i64,
};

allocator: Allocator,

seed: u64,

/// Chunks loaded in memory that are updated and rendered to the player.
chunks: std.AutoHashMapUnmanaged(ChunkPos, Chunk) = .empty,

pub fn deinit(self: *Self) void {
    self.chunks.deinit(self.allocator);
}

pub fn getChunk(self: *const Self, x: i64, z: i64) ?*Chunk {
    return self.chunks.getPtr(.{ .x = x, .z = z });
}

pub fn getBlockState(self: *const Self, x: i64, y: i64, z: i64) ?BlockState {
    const chunk_x = @divFloor(x, 16);
    const chunk_z = @divFloor(z, 16);

    if (self.getChunk(chunk_x, chunk_z)) |chunk| {
        const local_x: usize = @intCast(@mod(x, 16));
        const local_z: usize = @intCast(@mod(x, 16));

        return chunk.getBlockState(local_x, @intCast(y), local_z);
    }

    return null;
}

pub fn setBlockState(self: *const Self, x: i64, y: i64, z: i64, state: BlockState) void {
    const chunk_x = @divFloor(x, 16);
    const chunk_z = @divFloor(z, 16);

    if (self.getChunk(chunk_x, chunk_z)) |chunk| {
        const local_x: usize = @intCast(@mod(x, 16));
        const local_z: usize = @intCast(@mod(x, 16));

        chunk.setBlockState(local_x, @intCast(y), local_z, state);
    }
}

pub fn raycastBlock(self: *const Self, ray: Ray, precision: f32) ?RaycastResult {
    const length = ray.length();
    var t: f32 = 0.0;

    while (t < length) : (t += precision) {
        const point = ray.at(t);

        const block_x: i64 = @intFromFloat(point[0]);
        const block_y: i64 = @intFromFloat(point[1]);
        const block_z: i64 = @intFromFloat(point[2]);

        if (self.getBlockState(block_x, block_y, block_z)) |state| {
            return RaycastResult{
                .block = .{
                    .state = state,
                    .pos = .{
                        .x = block_x,
                        .y = block_y,
                        .z = block_z,
                    },
                },
            };
        }
    }

    return null;
}

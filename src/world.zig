const std = @import("std");
const zm = @import("zmath");

const RenderFrame = @import("render/RenderFrame.zig");
const Buffer = @import("render/Buffer.zig");
const Allocator = std.mem.Allocator;
const BlockInstanceData = RenderFrame.BlockInstanceData;
const BlockRegistry = @import("voxel/BlockRegistry.zig");

pub const World = struct {
    allocator: Allocator,

    seed: u64,

    /// Chunks loaded in memory and rendered to the player.
    chunks: std.ArrayListUnmanaged(Chunk) = .empty,

    pub fn deinit(self: *World) void {
        self.chunks.deinit(self.allocator);
    }
};

pub const BlockId = u16;

pub const Direction = enum(u3) {
    north = 0,
    south = 1,
    east = 2,
    west = 3,
    top = 4,
    down = 5,
};

pub const BlockState = packed struct(u32) {
    id: BlockId = 0,

    visibility: u6 = ~@as(u6, 0),
    direction: Direction = .north,

    _padding: u7 = 0,
};

pub const ChunkPos = struct {
    x: isize,
    z: isize,
};

pub const Chunk = struct {
    pub const length = 16;
    pub const height = 256;
    pub const block_count = length * height * length;

    position: ChunkPos,
    blocks: [length * height * length]BlockState = @splat(BlockState{}),

    /// GPU buffer used to store block instances.
    instance_buffer: Buffer = .{ .buffer = .null_handle, .allocation = null, .size = 0 },
    instance_count: usize = 0,

    pub fn getBlockState(self: *const Chunk, x: usize, y: usize, z: usize) ?BlockState {
        const block: BlockState = self.blocks[z * length * height + y * length + x];
        if (block.id == 0) return null;
        return block;
    }

    pub fn setBlockState(self: *Chunk, x: usize, y: usize, z: usize, state: BlockState) void {
        self.blocks[z * length * height + y * length + x] = state;
    }

    pub fn rebuildInstanceBuffer(self: *Chunk, block_registry: *const BlockRegistry) !void {
        if (self.instance_buffer.buffer == .null_handle)
            self.instance_buffer = try Buffer.create(@sizeOf(BlockInstanceData) * block_count, .{ .transfer_dst_bit = true, .vertex_buffer_bit = true }, .gpu_only);

        var index: usize = 0;
        var instances: [block_count]BlockInstanceData = @splat(BlockInstanceData{});

        for (0..length) |x| {
            for (0..height) |y| {
                for (0..length) |z| {
                    const block: BlockState = self.blocks[z * length * height + y * length + x];

                    if (block.id == 0 or block.visibility == 0) continue;

                    const textures = (block_registry.get(block.id) orelse unreachable).textures;

                    instances[index] = .{
                        .position = .{
                            @floatFromInt(self.position.x * 16 + @as(isize, @intCast(x))),
                            @floatFromInt(y),
                            @floatFromInt(self.position.z * 16 + @as(isize, @intCast(z))),
                        },
                        .textures0 = .{ @floatFromInt(textures[0]), @floatFromInt(textures[1]), @floatFromInt(textures[2]) },
                        .textures1 = .{ @floatFromInt(textures[3]), @floatFromInt(textures[4]), @floatFromInt(textures[5]) },
                    };
                    index += 1;
                }
            }
        }

        self.instance_count = index;
        try self.instance_buffer.update(BlockInstanceData, instances[0..index]);
    }
};

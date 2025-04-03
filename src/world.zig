const std = @import("std");
const zm = @import("zmath");

const RenderFrame = @import("render/RenderFrame.zig");
const Buffer = @import("render/Buffer.zig");
const Allocator = std.mem.Allocator;

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
    north,
    south,
    east,
    west,
    top,
    down,
};

pub const BlockState = packed struct(u32) {
    id: BlockId = 0,
    can_be_seen: bool = false,
    direction: Direction = .north,
    _padding: u12 = 0,
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
    instance_buffer: Buffer = std.mem.zeroes(Buffer),
    instance_count: usize = 0,

    pub const BlockInstance = extern struct {
        position: [3]f32 = .{ 0.0, 0.0, 0.0 },
    };

    pub fn getBlockState(self: *const Chunk, x: usize, y: usize, z: usize) ?BlockState {
        const block: BlockState = self.blocks[z * length * height + y * length + x];
        if (block.id == 0) return null;
        return block;
    }

    pub fn setBlockState(self: *Chunk, x: usize, y: usize, z: usize, state: BlockState) void {
        self.blocks[z * length * height + y * length + x] = state;
    }

    pub fn rebuildInstanceBuffer(self: *Chunk) !void {
        if (self.instance_buffer.buffer == .null_handle)
            self.instance_buffer = try Buffer.create(@sizeOf(BlockInstance) * block_count, .{ .transfer_dst_bit = true, .vertex_buffer_bit = true }, .gpu_only);

        var index: usize = 0;
        var instances: [block_count]BlockInstance = @splat(BlockInstance{});

        for (0..length) |x| {
            for (0..height) |y| {
                for (0..length) |z| {
                    const block: BlockState = self.blocks[z * length * height + y * length + x];

                    if (block.id == 0) continue;

                    instances[index] = .{
                        .position = .{
                            @floatFromInt(self.position.x * 16 + @as(isize, @intCast(x))),
                            @floatFromInt(y),
                            @floatFromInt(self.position.z * 16 + @as(isize, @intCast(z))),
                        },
                    };
                    index += 1;
                }
            }
        }

        self.instance_count = index;
        try self.instance_buffer.update(BlockInstance, instances[0..index]);
    }
};

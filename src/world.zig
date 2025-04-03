const std = @import("std");
const zm = @import("zmath");

const RenderFrame = @import("render/RenderFrame.zig");
const Allocator = std.mem.Allocator;

pub const World = struct {
    allocator: Allocator,

    seed: u64,

    /// Chunks loaded in memory and rendered to the player.
    chunks: std.ArrayListUnmanaged(Chunk) = .empty,

    pub fn deinit(self: *World) void {
        self.chunks.deinit(self.allocator);
    }

    pub fn draw(self: *const World, render_frame: *RenderFrame) void {
        for (self.chunks.items) |chunk| chunk.draw(render_frame);
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

    position: ChunkPos,
    blocks: [length * height * length]BlockState = @splat(BlockState{}),

    pub fn draw(self: *const Chunk, render_frame: *RenderFrame) void {
        var index: usize = 0;

        for (0..length) |x| {
            for (0..height) |y| {
                for (0..length) |z| {
                    if (self.getBlockState(x, y, z)) |block| {
                        if (!block.can_be_seen) continue;

                        const instance: RenderFrame.BlockInstanceData = .{
                            .model_matrix = zm.translation(
                                @floatFromInt(@as(isize, @intCast(x)) + self.position.x * length),
                                @floatFromInt(@as(isize, @intCast(y))),
                                @floatFromInt(@as(isize, @intCast(z)) + self.position.z * length),
                            ),
                        };

                        render_frame.addBlocks(&.{instance}) catch @panic("Cannot add more block the renderer");

                        index += 1;
                    }
                }
            }
        }
    }

    pub fn getBlockState(self: *const Chunk, x: usize, y: usize, z: usize) ?BlockState {
        const block: BlockState = self.blocks[z * length * height + y * length + x];
        if (block.id == 0) return null;
        return block;
    }

    pub fn setBlockState(self: *Chunk, x: usize, y: usize, z: usize, state: BlockState) void {
        self.blocks[z * length * height + y * length + x] = state;
    }
};

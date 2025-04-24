const std = @import("std");

const Self = @This();
const World = @import("World.zig");
const BlockState = World.BlockState;
const Registry = @import("../voxel/Registry.zig");
const Renderer = @import("../render/Renderer.zig");
const RID = Renderer.RID;

const rdr = Renderer.rdr;

pub const length = 16;
pub const height = 256;
pub const block_count = length * height * length;

pub const Pos = struct {
    x: i64,
    z: i64,
};

pub const LocalPos = packed struct(u16) {
    x: u4,
    y: u8,
    z: u4,
};

position: Pos,
blocks: [block_count]BlockState = @splat(BlockState{}),
instance_buffer_index: usize = ~@as(usize, 0),

pub fn getBlockState(self: *const Self, x: usize, y: usize, z: usize) ?BlockState {
    const block: BlockState = self.blocks[z * length * height + y * length + x];
    if (block.id == 0) return null;
    return block;
}

fn noBlockOrTransparent(self: *const Self, x: usize, y: usize, z: usize, current_id: u16) bool {
    const block: BlockState = self.blocks[z * length * height + y * length + x];
    return block.id == 0 or (block.transparent and block.id != current_id);
}

pub fn setBlockState(self: *Self, x: usize, y: usize, z: usize, state: BlockState) void {
    self.blocks[z * length * height + y * length + x] = state;
}

pub fn computeVisibilityNoLock(
    self: *Self,
    world: *const World,
) void {
    const north = world.getChunk(self.position.x, self.position.z - 1);
    const south = world.getChunk(self.position.x, self.position.z + 1);
    const west = world.getChunk(self.position.x - 1, self.position.z);
    const east = world.getChunk(self.position.x + 1, self.position.z);

    for (0..length) |x| {
        for (0..height) |y| {
            for (0..length) |z| {
                var visibility: u6 = 0;

                const current_id = (self.getBlockState(x, y, z) orelse continue).id;

                if (z == 0) {
                    if (north) |chunk| {
                        if (chunk.noBlockOrTransparent(x, y, 15, current_id)) visibility |= 1 << 0;
                    } else {
                        visibility |= 1 << 0;
                    }
                } else if (self.noBlockOrTransparent(x, y, z - 1, current_id)) {
                    visibility |= 1 << 0;
                }

                if (z == 15) {
                    if (south) |chunk| {
                        if (chunk.noBlockOrTransparent(x, y, 0, current_id)) visibility |= 1 << 1;
                    } else {
                        visibility |= 1 << 1;
                    }
                } else if (self.noBlockOrTransparent(x, y, z + 1, current_id)) {
                    visibility |= 1 << 1;
                }

                if (x == 0) {
                    if (west) |chunk| {
                        if (chunk.noBlockOrTransparent(15, y, z, current_id)) visibility |= 1 << 2;
                    } else {
                        visibility |= 1 << 2;
                    }
                } else if (self.noBlockOrTransparent(x - 1, y, z, current_id)) {
                    visibility |= 1 << 2;
                }

                if (x == 15) {
                    if (east) |chunk| {
                        if (chunk.noBlockOrTransparent(0, y, z, current_id)) visibility |= 1 << 3;
                    } else {
                        visibility |= 1 << 3;
                    }
                } else if (self.noBlockOrTransparent(x + 1, y, z, current_id)) {
                    visibility |= 1 << 3;
                }

                if (y == 255 or self.noBlockOrTransparent(x, y + 1, z, current_id)) visibility |= 1 << 4;
                if (y == 0 or self.noBlockOrTransparent(x, y - 1, z, current_id)) visibility |= 1 << 5;

                self.blocks[z * length * height + y * length + x].visibility = visibility;
            }
        }
    }
}

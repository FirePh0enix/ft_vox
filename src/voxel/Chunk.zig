const Self = @This();
const World = @import("World.zig");
const BlockState = World.BlockState;
const Buffer = @import("../render/Buffer.zig");
const Registry = @import("../voxel/Registry.zig");
const RenderFrame = @import("../voxel/RenderFrame.zig");
const BlockInstanceData = RenderFrame.BlockInstanceData;

pub const length = 16;
pub const height = 256;
pub const block_count = length * height * length;

pub const Pos = struct {
    x: i64,
    z: i64,
};

position: Pos,
blocks: [block_count]BlockState = @splat(BlockState{}),

/// GPU buffer used to store block instances.
instance_buffer: Buffer = .{ .buffer = .null_handle, .allocation = null, .size = 0 },
instance_count: usize = 0,

pub fn getBlockState(self: *const Self, x: usize, y: usize, z: usize) ?BlockState {
    const block: BlockState = self.blocks[z * length * height + y * length + x];
    if (block.id == 0) return null;
    return block;
}

pub fn setBlockState(self: *Self, x: usize, y: usize, z: usize, state: BlockState) void {
    self.blocks[z * length * height + y * length + x] = state;
}

pub fn computeVisibility(
    self: *Self,
    north: ?*const Self,
    south: ?*const Self,
    west: ?*const Self,
    east: ?*const Self,
) void {
    // _ = north;
    // _ = south;
    _ = west;
    _ = east;

    for (0..length) |x| {
        for (0..height) |y| {
            for (0..length) |z| {
                var visibility: u6 = 0;

                if (z == 0 and north != null and north.?.getBlockState(x, y, 15) == null) {
                    visibility |= 1 << 0;
                } else if (z == 0 or self.getBlockState(x, y, z - 1) == null) {
                    visibility |= 1 << 0;
                }

                if (z == 15 and south != null and south.?.getBlockState(x, y, 0) == null) {
                    visibility |= 1 << 1;
                } else if (z == 15 or self.getBlockState(x, y, z + 1) == null) {
                    visibility |= 1 << 1;
                }

                if (x == 0 or self.getBlockState(x - 1, y, z) == null) visibility |= 1 << 2;
                if (x == 15 or self.getBlockState(x + 1, y, z) == null) visibility |= 1 << 3;

                if (y == 255 or self.getBlockState(x, y + 1, z) == null) visibility |= 1 << 4;
                if (y == 0 or self.getBlockState(x, y - 1, z) == null) visibility |= 1 << 5;

                self.blocks[z * length * height + y * length + x].visibility = visibility;
            }
        }
    }
}

pub fn rebuildInstanceBuffer(self: *Self, registry: *const Registry) !void {
    if (self.instance_buffer.buffer == .null_handle)
        self.instance_buffer = try Buffer.create(@sizeOf(BlockInstanceData) * block_count, .{ .transfer_dst_bit = true, .vertex_buffer_bit = true }, .gpu_only);

    var index: usize = 0;
    var instances: [block_count]BlockInstanceData = @splat(BlockInstanceData{});

    for (0..length) |x| {
        for (0..height) |y| {
            for (0..length) |z| {
                const block: BlockState = self.blocks[z * length * height + y * length + x];

                if (block.id == 0 or block.visibility == 0) continue;

                const textures = (registry.getBlock(block.id) orelse unreachable).visual.cube.textures;

                instances[index] = .{
                    .position = .{
                        @floatFromInt(self.position.x * 16 + @as(isize, @intCast(x))),
                        @floatFromInt(y),
                        @floatFromInt(self.position.z * 16 + @as(isize, @intCast(z))),
                    },
                    .textures0 = .{ @floatFromInt(textures[0]), @floatFromInt(textures[1]), @floatFromInt(textures[2]) },
                    .textures1 = .{ @floatFromInt(textures[3]), @floatFromInt(textures[4]), @floatFromInt(textures[5]) },
                    .visibility = @intCast(block.visibility),
                };
                index += 1;
            }
        }
    }

    self.instance_count = index;
    try self.instance_buffer.update(BlockInstanceData, instances[0..index]);
}

const Self = @This();
const World = @import("World.zig");
const BlockState = World.BlockState;
const Buffer = @import("../render/Buffer.zig");
const Registry = @import("../voxel/Registry.zig");
const RenderFrame = @import("../render/RenderFrame.zig");
const BlockInstanceData = RenderFrame.BlockInstanceData;

pub const length = 16;
pub const height = 256;
pub const block_count = length * height * length;

pub const Pos = struct {
    x: isize,
    z: isize,
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
                };
                index += 1;
            }
        }
    }

    self.instance_count = index;
    try self.instance_buffer.update(BlockInstanceData, instances[0..index]);
}

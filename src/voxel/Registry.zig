const std = @import("std");
const zigimg = @import("zigimg");

const Allocator = std.mem.Allocator;
const Self = @This();
const Block = @import("Block.zig");
const Image = @import("../render/Image.zig");
const Renderer = @import("../render/Renderer.zig");

const rdr = Renderer.rdr;

pub const BlockZon = struct {
    /// An unique identifiable identifier.
    name: []const u8,

    /// Configure how the block appears in game.
    visual: union(enum) {
        cube: struct {
            textures: [6][]const u8,
        },
    },
};

allocator: Allocator,

blocks: std.ArrayListUnmanaged(Block) = .empty,
block_ids: std.StringArrayHashMapUnmanaged(u16) = .empty,

images: std.ArrayListUnmanaged(zigimg.ImageUnmanaged) = .empty,
images_ids: std.StringArrayHashMapUnmanaged(u32) = .empty,
image_array: ?Image = null,

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
    };
}

pub fn lock(self: *Self) !void {
    try self.createTexture();

    // Images are not needed on the CPU memory after this point.
    for (self.images.items) |*image| {
        image.deinit(self.allocator);
    }

    self.images.deinit(self.allocator);
}

pub fn registerBlock(
    self: *Self,
    block_config: BlockZon,
    vtable: Block.VTable,
) !void {
    const visual: Block.Visual = switch (block_config.visual) {
        .cube => |cube| .{
            .cube = .{
                .textures = .{
                    try self.getOrRegisterImage(cube.textures[0]),
                    try self.getOrRegisterImage(cube.textures[1]),
                    try self.getOrRegisterImage(cube.textures[2]),
                    try self.getOrRegisterImage(cube.textures[3]),
                    try self.getOrRegisterImage(cube.textures[4]),
                    try self.getOrRegisterImage(cube.textures[5]),
                },
            },
        },
    };

    const block: Block = .{
        .visual = visual,
        .vtable = vtable,
    };

    const id: u16 = @intCast(self.blocks.items.len);

    try self.block_ids.put(self.allocator, block_config.name, id + 1);
    try self.blocks.append(self.allocator, block);
}

pub fn getBlock(self: *const Self, id: u16) ?Block {
    if (id == 0 or id - 1 >= self.blocks.items.len)
        return null;
    return self.blocks.items[id - 1];
}

pub fn getBlockId(self: *const Self, name: []const u8) ?u16 {
    return self.block_ids.get(name);
}

pub fn getOrRegisterImage(
    self: *Self,
    path: []const u8,
) !u32 {
    if (self.images_ids.get(path)) |index| {
        return index;
    } else {
        const index = self.images.items.len + 1;
        const image = try zigimg.ImageUnmanaged.fromFilePath(self.allocator, path);

        try self.images_ids.put(self.allocator, path, @intCast(index));
        try self.images.append(self.allocator, image);

        return @intCast(index);
    }
}

fn createTexture(self: *Self) !void {
    var image_array = try rdr().createImage(16, 16, self.images.items.len + 1, .optimal, .r8g8b8a8_srgb, .{ .sampled = true, .transfer_dst = true }, .{ .color = true });

    try image_array.asVk().transferLayout(.undefined, .transfer_dst_optimal, .{ .color_bit = true });

    var missing = @import("../render/vulkan.zig").VulkanImage.getMissingPixels();
    try image_array.update(0, &missing);

    for (self.images.items, 0..self.images.items.len) |image, index| {
        try image_array.update(index + 1, image.rawBytes());
    }

    try image_array.asVk().transferLayout(.transfer_dst_optimal, .shader_read_only_optimal, .{ .color_bit = true });

    self.image_array = image_array;
}

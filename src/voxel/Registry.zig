const std = @import("std");
const zigimg = @import("zigimg");
const assets = @import("../assets.zig");

const Allocator = std.mem.Allocator;
const Self = @This();
const Block = @import("Block.zig");
const Renderer = @import("../render/Renderer.zig");
const RID = Renderer.RID;

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

    solid: bool = true,
};

allocator: Allocator,

blocks: std.ArrayListUnmanaged(Block) = .empty,
block_ids: std.StringArrayHashMapUnmanaged(u16) = .empty,

images: std.ArrayListUnmanaged(zigimg.ImageUnmanaged) = .empty,
images_ids: std.StringArrayHashMapUnmanaged(u32) = .empty,
image_array: ?RID = null,

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    for (self.blocks.items) |block| block.deinit(self.allocator);

    self.blocks.deinit(self.allocator);
    self.block_ids.deinit(self.allocator);

    self.images_ids.deinit(self.allocator);

    if (self.image_array) |rid| rdr().freeRid(rid);
}

pub fn lock(self: *Self) !void {
    try self.createTexture();

    // Images are not needed on the CPU memory after this point.
    for (self.images.items) |*image| {
        image.deinit(self.allocator);
    }

    self.images.deinit(self.allocator);
}

pub fn registerBlock(self: *Self, block_config: BlockZon, vtable: Block.VTable) !void {
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
        .name = try self.allocator.dupe(u8, block_config.name),
        .name_hash = Block.getNameHash(block_config.name),
        .visual = visual,
        .vtable = vtable,
        .solid = block_config.solid,
    };

    const id: u16 = @intCast(self.blocks.items.len);

    try self.block_ids.put(self.allocator, block.name, id + 1);
    try self.blocks.append(self.allocator, block);
}

/// Register a block from a zon file located in `assets/blocks/`.
pub fn registerBlockFromFile(self: *Self, name: []const u8, vtable: Block.VTable) !void {
    try self.registerBlock(assets.getBlockData(name) orelse return error.Failed, vtable);
}

pub fn getBlock(self: *const Self, id: u16) ?*Block {
    if (id == 0 or id - 1 >= self.blocks.items.len)
        return null;
    return &self.blocks.items[id - 1];
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
        const source = assets.getTextureData(path);

        const image = try zigimg.ImageUnmanaged.fromMemory(self.allocator, source);

        try self.images_ids.put(self.allocator, path, @intCast(index));
        try self.images.append(self.allocator, image);

        return @intCast(index);
    }
}

fn createTexture(self: *Self) !void {
    const image_array_rid = try rdr().imageCreate(.{
        .width = 16,
        .height = 16,
        .layers = self.images.items.len + 1,
        .format = .r8g8b8a8_srgb,
        .usage = .{ .sampled = true, .transfer_dst = true },
        .aspect_mask = .{ .color = true },
    });

    try rdr().imageSetLayout(image_array_rid, .transfer_dst_optimal);

    var missing = getMissingPixels();
    try rdr().imageUpdate(image_array_rid, std.mem.sliceAsBytes(&missing), 0, 0);

    for (self.images.items, 0..self.images.items.len) |image, index| {
        try rdr().imageUpdate(image_array_rid, image.rawBytes(), 0, index + 1);
    }

    try rdr().imageSetLayout(image_array_rid, .shader_read_only_optimal);

    self.image_array = image_array_rid;
}

fn getMissingPixels() [16 * 16 * 4]u8 {
    var pixels: [16 * 16 * 4]u8 = undefined;

    for (0..8) |x| {
        for (0..8) |y| {
            pixels[0 * 4 * 8 + y * 8 + x] = 0xcc;
            pixels[1 * 4 * 8 + y * 8 + x] = 0x40;
            pixels[2 * 4 * 8 + y * 8 + x] = 0xc4;
            pixels[3 * 4 * 8 + y * 8 + x] = 0xff;
        }
    }

    for (0..8) |x| {
        for (0..8) |y| {
            pixels[0 * 4 * 8 + (y + 8) * 8 + x] = 0;
            pixels[1 * 4 * 8 + (y + 8) * 8 + x] = 0;
            pixels[2 * 4 * 8 + (y + 8) * 8 + x] = 0;
            pixels[3 * 4 * 8 + (y + 8) * 8 + x] = 0xff;
        }
    }

    for (0..8) |x| {
        for (0..8) |y| {
            pixels[0 * 4 * 8 + y * 8 + (x + 8)] = 0xcc;
            pixels[1 * 4 * 8 + y * 8 + (x + 8)] = 0x40;
            pixels[2 * 4 * 8 + y * 8 + (x + 8)] = 0xc4;
            pixels[3 * 4 * 8 + y * 8 + (x + 8)] = 0xff;
        }
    }

    for (0..8) |x| {
        for (0..8) |y| {
            pixels[0 * 4 * 8 + (y + 8) * 8 + (x + 8)] = 0xcc;
            pixels[1 * 4 * 8 + (y + 8) * 8 + (x + 8)] = 0x40;
            pixels[2 * 4 * 8 + (y + 8) * 8 + (x + 8)] = 0xc4;
            pixels[3 * 4 * 8 + (y + 8) * 8 + (x + 8)] = 0xff;
        }
    }

    return pixels;
}

const std = @import("std");
const zigimg = @import("zigimg");

const Self = @This();
const Allocator = std.mem.Allocator;
const Image = @import("../render/Image.zig");

allocator: Allocator,
path_to_index: std.StringArrayHashMap(u32),
images: std.ArrayList(zigimg.Image),

image_array: ?Image = null,

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
        .path_to_index = .init(allocator),
        .images = .init(allocator),
    };
}

pub fn getOrRegisterImage(
    self: *Self,
    path: []const u8,
) !u32 {
    if (self.path_to_index.get(path)) |index| {
        return index;
    } else {
        const index = self.images.items.len;
        const image = try zigimg.Image.fromFilePath(self.allocator, path);

        try self.path_to_index.put(path, @intCast(index));
        try self.images.append(image);

        return @intCast(index);
    }
}

pub fn createTexture(self: *Self) !void {
    var image_array = try Image.create(16, 16, @intCast(self.images.items.len), .r8g8b8a8_srgb, .optimal, .{ .sampled_bit = true, .transfer_dst_bit = true }, .{ .color_bit = true });

    try image_array.transferLayout(.undefined, .transfer_dst_optimal, .{ .color_bit = true });

    for (self.images.items, 0..self.images.items.len) |image, index| {
        try image_array.store(@intCast(index), image.rawBytes());
    }

    try image_array.transferLayout(.transfer_dst_optimal, .shader_read_only_optimal, .{ .color_bit = true });

    self.image_array = image_array;
}

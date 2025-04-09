const std = @import("std");

const Self = @This();
const VulkanImage = @import("vulkan.zig").VulkanImage;

ptr: *anyopaque,
vtable: *const VTable,

pub const UpdateError = error{};

pub const VTable = struct {
    update: *const fn (self: *anyopaque, layer: usize, data: []const u8) UpdateError!void,
    destroy: *const fn (self: *anyopaque) void,
};

pub fn asVk(self: *Self) *VulkanImage {
    return @ptrCast(@alignCast(self.ptr));
}

pub fn asVkConst(self: *const Self) *const VulkanImage {
    return @ptrCast(@alignCast(self.ptr));
}

pub fn deinit(self: *const Self) void {
    self.vtable.destroy(self.ptr);
}

pub fn update(self: *Self, layer: usize, data: []const u8) UpdateError!void {
    return self.vtable.update(self.ptr, layer, data);
}

const std = @import("std");
const vk = @import("vulkan");
const vma = @import("vma");

const Self = @This();
const Renderer = @import("Renderer.zig");

const VulkanBuffer = @import("vulkan.zig").VulkanBuffer;

ptr: *anyopaque,
vtable: *const VTable,

pub const UpdateError = error{};

pub const VTable = struct {
    destroy: *const fn (self: *const anyopaque) void,
    update: *const fn (self: *anyopaque, data: []const u8) error{}!void,
};

pub fn asVk(self: *Self) *VulkanBuffer {
    return @ptrCast(@alignCast(self.ptr));
}

pub fn asVkConst(self: *const Self) *const VulkanBuffer {
    return @ptrCast(@alignCast(self.ptr));
}

pub fn deinit(self: *const Self) void {
    self.vtable.destroy(self.ptr);
}

pub fn update(self: *Self, data: []const u8) error{}!void {
    return self.vtable.update(self.ptr, data);
}

const std = @import("std");

const Self = @This();
const Renderer = @import("Renderer.zig");

const rdr = Renderer.rdr;

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*anyopaque) void,
    update: *const fn (*anyopaque, s: []const u8, offset: usize) UpdateError!void,
    map: *const fn (*anyopaque) MapError![]u8,
    unmap: *const fn (*anyopaque) void,
};

pub const Options = struct {
    size: usize,
    usage: Renderer.BufferUsageFlags,
    alloc_usage: Renderer.AllocUsage = .gpu_only,
};

pub const CreateError = error{
    OutOfMemory,
    OutOfDeviceMemory,
    Failed,
};

pub inline fn create(options: Options) CreateError!Self {
    return rdr().createBuffer(options);
}

pub inline fn destroy(self: *Self) void {
    self.vtable.destroy(self.ptr);
    self.* = undefined;
}

pub const UpdateError = error{
    OutOfBounds,
    OutOfMemory,
    OutOfDeviceMemory,
    Failed,
};

/// Update the content of the buffer with a staging buffer.
pub inline fn update(self: *Self, s: []const u8, offset: usize) UpdateError!void {
    return self.vtable.update(self.ptr, s, offset);
}

pub const MapError = error{Failed};

pub inline fn map(self: *Self) MapError![]u8 {
    return self.vtable.map(self.ptr);
}

pub inline fn unmap(self: *const Self) void {
    self.vtable.unmap(self.ptr);
}

const std = @import("std");
const vk = @import("vulkan");
const vma = @import("vma");

const Self = @This();
const Renderer = @import("Renderer.zig");

buffer: vk.Buffer,
allocation: vma.VmaAllocation,
size: usize,

pub const AllocUsage = enum {
    gpu_only,
    cpu_to_gpu,
};

pub fn create(size: usize, buffer_usage: vk.BufferUsageFlags, alloc_usage: AllocUsage) !Self {
    const alloc_info: vma.VmaAllocationCreateInfo = .{
        .usage = switch (alloc_usage) {
            .gpu_only => vma.VMA_MEMORY_USAGE_GPU_ONLY,
            .cpu_to_gpu => vma.VMA_MEMORY_USAGE_CPU_TO_GPU,
        },
    };

    const buffer_info: vk.BufferCreateInfo = .{
        .size = @intCast(size),
        .usage = buffer_usage,
        .sharing_mode = .exclusive,
    };

    var buffer: vk.Buffer = undefined;
    var allocation: vma.VmaAllocation = undefined;

    if (vma.vmaCreateBuffer(Renderer.singleton.vma_allocator, @ptrCast(&buffer_info), @ptrCast(&alloc_info), @ptrCast(&buffer), @ptrCast(&allocation), null) != vma.VK_SUCCESS) {
        return error.Internal;
    }

    return .{
        .buffer = buffer,
        .allocation = allocation,
        .size = size,
    };
}

pub fn createFromData(comptime T: type, data: []const T, buffer_usage: vk.BufferUsageFlags, alloc_usage: AllocUsage) !Self {
    var buffer = try create(@sizeOf(T) * data.len, buffer_usage, alloc_usage);
    errdefer buffer.deinit();

    try buffer.store(T, data);
    return buffer;
}

pub fn store(self: *Self, comptime T: type, data: []const T) !void {
    var staging_buffer = try create(self.size, .{ .transfer_src_bit = true }, .cpu_to_gpu);
    defer staging_buffer.deinit();

    {
        const map_data = try staging_buffer.map();
        defer staging_buffer.unmap();

        const data_bytes: []const u8 = @as([*]const u8, @ptrCast(data.ptr))[0..self.size];
        @memcpy(map_data, data_bytes);
    }

    // Record the command buffer
    const begin_info: vk.CommandBufferBeginInfo = .{
        .flags = .{ .one_time_submit_bit = true },
    };
    try Renderer.singleton.transfer_command_buffer.resetCommandBuffer(.{});
    try Renderer.singleton.transfer_command_buffer.beginCommandBuffer(&begin_info);

    const regions: []const vk.BufferCopy = &.{
        vk.BufferCopy{ .src_offset = 0, .dst_offset = 0, .size = self.size },
    };

    Renderer.singleton.transfer_command_buffer.copyBuffer(staging_buffer.buffer, self.buffer, @intCast(regions.len), regions.ptr);
    try Renderer.singleton.transfer_command_buffer.endCommandBuffer();

    const submit_info: vk.SubmitInfo = .{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&Renderer.singleton.transfer_command_buffer),
    };

    try Renderer.singleton.graphics_queue.submit(1, @ptrCast(&submit_info), .null_handle);
    try Renderer.singleton.graphics_queue.waitIdle();
}

pub fn deinit(self: *const Self) void {
    vma.vmaDestroyBuffer(Renderer.singleton.vma_allocator, @ptrFromInt(@as(usize, @intFromEnum(self.buffer))), self.allocation);
}

pub fn map(self: *const Self) ![]u8 {
    var data: ?*anyopaque = null;

    if (vma.vmaMapMemory(Renderer.singleton.vma_allocator, self.allocation, &data) != vma.VK_SUCCESS)
        return error.Internal;

    if (data) |ptr| {
        return @as([*]u8, @ptrCast(ptr))[0..self.size];
    } else {
        return error.Internal;
    }
}

pub fn unmap(self: *const Self) void {
    vma.vmaUnmapMemory(Renderer.singleton.vma_allocator, self.allocation);
}

const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Self = @This();

backing_allocator: Allocator,
total_allocated_bytes: usize = 0,

pub fn allocator(self: *Self) Allocator {
    return Allocator{
        .ptr = self,
        .vtable = &.{
            .alloc = &alloc,
            .resize = &resize,
            .remap = &remap,
            .free = &free,
        },
    };
}

fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.total_allocated_bytes += len;

    return self.backing_allocator.vtable.alloc(self.backing_allocator.ptr, len, alignment, ret_addr);
}

fn resize(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.total_allocated_bytes -= memory.len;
    self.total_allocated_bytes += new_len;

    return self.backing_allocator.vtable.resize(self.backing_allocator.ptr, memory, alignment, new_len, ret_addr);
}

fn remap(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.total_allocated_bytes -= memory.len;
    self.total_allocated_bytes += new_len;

    return self.backing_allocator.vtable.remap(self.backing_allocator.ptr, memory, alignment, new_len, ret_addr);
}

fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.total_allocated_bytes -= memory.len;

    self.backing_allocator.vtable.free(self.backing_allocator.ptr, memory, alignment, ret_addr);
}

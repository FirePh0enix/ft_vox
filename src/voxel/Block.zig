const std = @import("std");

const Self = @This();
const Allocator = std.mem.Allocator;

pub const VTable = struct {};

pub const Visual = union(enum) {
    cube: struct {
        textures: [6]u32,
    },
};

name: []const u8,
name_hash: u64,

transparent: bool = false,
solid: bool = true,

vtable: VTable,
visual: Visual,

pub fn getNameHash(name: []const u8) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    hasher.update(name);
    return hasher.final();
}

pub fn deinit(self: *const Self, allocator: Allocator) void {
    allocator.free(self.name);
}

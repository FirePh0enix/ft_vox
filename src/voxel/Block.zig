const std = @import("std");

pub const VTable = struct {};

pub const Visual = union(enum) {
    cube: struct {
        textures: [6]u32,
    },
};

name: u64,
transparent: bool = false,

vtable: VTable,
visual: Visual,

pub fn getNameHash(name: []const u8) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    hasher.update(name);
    return hasher.final();
}

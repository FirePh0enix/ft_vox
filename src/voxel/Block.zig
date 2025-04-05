const std = @import("std");

pub const VTable = struct {};

pub const Visual = union(enum) {
    cube: struct {
        textures: [6]u32,
    },
};

vtable: VTable,
visual: Visual,

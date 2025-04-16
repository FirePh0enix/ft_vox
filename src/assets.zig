const std = @import("std");

const BlockZon = @import("voxel/Registry.zig").BlockZon;

pub const Assets = struct {
    blocks: []struct {
        name: []const u8,
        data: BlockZon,
    },
    shaders: []struct {
        name: []const u8,
        data: []const u8,
    },
    textures: []struct {
        name: []const u8,
        data: []const u8,
    },
};

pub const embeded = @import("embeded_assets").embeded;

pub fn getShaderDataComptime(name: []const u8) []const u8 {
    for (embeded.shaders) |shader| {
        if (std.mem.eql(u8, name, shader.name)) return shader.data;
    }
    unreachable;
}

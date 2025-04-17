const std = @import("std");

const BlockZon = @import("voxel/Registry.zig").BlockZon;

const embeded = @import("embeded_assets").embeded;

pub fn getShaderData(name: []const u8) [:0]align(4) const u8 {
    for (embeded.shaders) |shader| {
        if (std.mem.eql(u8, name, shader.name)) return shader.data;
    }
    unreachable;
}

pub fn getTextureData(name: []const u8) []const u8 {
    for (embeded.textures) |texture| {
        if (std.mem.eql(u8, name, texture.name)) return texture.data;
    }
    unreachable;
}

pub fn getBlockData(name: []const u8) ?BlockZon {
    for (embeded.blocks) |block| {
        if (std.mem.eql(u8, name, block.name)) return block.data;
    }
    return null;
}

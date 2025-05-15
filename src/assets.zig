const std = @import("std");
const zigimg = @import("zigimg");

const BlockZon = @import("voxel/Registry.zig").BlockZon;
const Allocator = std.mem.Allocator;

const embeded = @import("embeded_assets").embeded;

pub fn getShaderData(name: []const u8) ?[:0]align(4) const u8 {
    for (embeded.shaders) |shader| {
        if (std.mem.eql(u8, name, shader.name)) return shader.data;
    }
    return null;
}

pub fn getTextureData(name: []const u8) ?[]const u8 {
    for (embeded.textures) |texture| {
        if (std.mem.eql(u8, name, texture.name)) return texture.data;
    }
    return null;
}

pub fn getBlockData(name: []const u8) ?BlockZon {
    for (embeded.blocks) |block| {
        if (std.mem.eql(u8, name, block.name)) return block.data;
    }
    return null;
}

pub fn getMissingTexture(allocator: Allocator, w: usize, h: usize) !zigimg.Image {
    const pixels = try getMissingPixels(allocator, w, h);
    defer allocator.free(pixels);
    return zigimg.Image.fromRawPixels(allocator, w, h, pixels, .rgba32);
}

fn getMissingPixels(allocator: Allocator, w: usize, h: usize) ![]u8 {
    const pixels = try allocator.alloc(u8, w * h * 4);

    const hw = w / 2;
    const hh = h / 2;

    for (0..hw) |x| {
        for (0..hh) |y| {
            pixels[0 * 4 * hw + y * hh + x] = 0xcc;
            pixels[1 * 4 * hw + y * hh + x] = 0x40;
            pixels[2 * 4 * hw + y * hh + x] = 0xc4;
            pixels[3 * 4 * hw + y * hh + x] = 0xff;
        }
    }

    for (0..hw) |x| {
        for (0..hh) |y| {
            pixels[0 * 4 * hw + (y + hh) * hh + x] = 0;
            pixels[1 * 4 * hw + (y + hh) * hh + x] = 0;
            pixels[2 * 4 * hw + (y + hh) * hh + x] = 0;
            pixels[3 * 4 * hw + (y + hh) * hh + x] = 0xff;
        }
    }

    for (0..hw) |x| {
        for (0..hh) |y| {
            pixels[0 * 4 * hw + y * hh + (x + hw)] = 0xcc;
            pixels[1 * 4 * hw + y * hh + (x + hw)] = 0x40;
            pixels[2 * 4 * hw + y * hh + (x + hw)] = 0xc4;
            pixels[3 * 4 * hw + y * hh + (x + hw)] = 0xff;
        }
    }

    for (0..hw) |x| {
        for (0..hh) |y| {
            pixels[0 * 4 * hw + (y + hh) * hh + (x + hw)] = 0xcc;
            pixels[1 * 4 * hw + (y + hh) * hh + (x + hw)] = 0x40;
            pixels[2 * 4 * hw + (y + hh) * hh + (x + hw)] = 0xc4;
            pixels[3 * 4 * hw + (y + hh) * hh + (x + hw)] = 0xff;
        }
    }

    return pixels;
}

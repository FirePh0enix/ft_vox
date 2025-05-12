const std = @import("std");

const Self = @This();
const Renderer = @import("render/Renderer.zig");
const RID = Renderer.RID;
const Graph = @import("render/Graph.zig");
const Font = @import("Font.zig");
const Allocator = std.mem.Allocator;

const CharInstance = extern struct {
    bounds: [4]f32,
    char_pos: [3]f32,
    scale: [2]f32,
};

const rdr = Renderer.rdr;

text: []const u8 = &.{},
font: *const Font,
allocator: Allocator,

instance_buffer: RID,
instances: []CharInstance = &.{},
capacity: usize,

pub fn initCapacity(font: *const Font, allocator: Allocator, capacity: usize) !Self {
    return .{
        .font = font,
        .instance_buffer = try rdr().bufferCreate(.{ .size = capacity * @sizeOf(CharInstance) }),
        .instances = try allocator.alloc(CharInstance, capacity),
        .capacity = capacity,
        .allocator = allocator,
    };
}

pub fn from(font: *const Font, allocator: Allocator, s: []const u8) !Self {
    var text = try initCapacity(font, allocator, s.len);
    try text.set(s);
    return text;
}

pub fn set(self: *Self, s: []const u8) !void {
    if (s.len != self.text.len) {
        // recreate the buffer
    }

    var offset_x: f32 = 0;

    for (s, 0..s.len) |char, index| {
        const char_data = self.characters.get(char) orelse unreachable;
        const char_datas = self.font.characters orelse unreachable;


        const offset = @as(f32, @floatFromInt(char_data.offset)) / @as(f32, @floatFromInt(self.width));
        const char_width = @as(f32, @floatFromInt(char_data.size.x)) / @as(f32, @floatFromInt(self.width));
        const char_height = @as(f32, @floatFromInt(char_data.size.y)) / @as(f32, @floatFromInt(self.height));

        // Calculate horizontal and vertical bearing offsets to align glyphs relative to the baseline.
        // For example, the letter 'g' is a descender, so its vertical offset places it below the baseline.
        const bx = @as(f32, @floatFromInt(char_data.bearing.x)) / @as(f32, @floatFromInt(self.width)) * scale;
        const by = @as(f32, @floatFromInt((char_data.size.y - char_data.bearing.y))) / @as(f32, @floatFromInt(self.height)) * scale;

        // Calculate scaling factors to maintain correct aspect ratio and avoid texture stretching.
        const scale_x = @as(f32, @floatFromInt(char_data.size.x)) / @as(f32, @floatFromInt(self.height)) * scale;
        const scale_y = @as(f32, @floatFromInt(char_data.size.y)) / @as(f32, @floatFromInt(self.height)) * scale;

        instances[index] = .{
            .bounds = .{ offset, offset + char_width, char_height, 0.0 },
            .char_pos = .{ pos[0] + bx + offset_x, pos[1] + by, pos[2] },
            .scale = .{ scale_x, scale_y },
        };

        // Convert advance from 1/64 pixels to pixels, normalize by font height, then apply scale.
        offset_x += @as(f32, @floatFromInt(char_data.advance >> 6)) / @as(f32, @floatFromInt(self.height)) * scale;
    }

    self.text = s;
}

pub fn draw(self: *const Self, render_pass: *Graph.RenderPass) void {
    render_pass.drawInstanced(Font.mesh, self.material, self.instance_buffer, 0, 6, 0, self.text.len, Font.ortho_matrix);
}

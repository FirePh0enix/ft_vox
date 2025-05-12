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

instance_buffer: RID,
capacity: usize,

pub fn initCapacity(font: *const Font, capacity: usize) !Self {
    return .{
        .font = font,
        .instance_buffer = try rdr().bufferCreate(.{
            .size = capacity * @sizeOf(CharInstance),
            .usage = .{ .vertex_buffer = true, .transfer_dst = true },
        }),
        .capacity = capacity,
    };
}

pub fn deinit(self: *const Self) void {
    rdr().freeRid(self.instance_buffer);
}

pub fn from(font: *const Font, scale: f32, pos: [3]f32, s: []const u8) !Self {
    var text = try initCapacity(font, s.len);
    try text.set(s, pos, scale);
    return text;
}

pub fn set(self: *Self, s: []const u8, pos: [3]f32, scale: f32) !void {
    var offset_x: f32 = 0;
    const width = self.font.width;
    const height = self.font.height;

    // Recreate the buffer
    if (s.len > self.text.len) {
        self.capacity = s.len;

        rdr().freeRid(self.instance_buffer);

        self.instance_buffer = try rdr().bufferCreate(.{
            .size = self.capacity * @sizeOf(CharInstance),
            .usage = .{ .vertex_buffer = true, .transfer_dst = true },
        });
    }

    const batch_size = 32;
    var instances: [batch_size]CharInstance = undefined;

    // Update buffer
    for (s, 0..s.len) |char, index| {
        const char_data = self.font.characters.get(char) orelse unreachable;

        const offset = @as(f32, @floatFromInt(char_data.offset)) / @as(f32, @floatFromInt(width));
        const char_width = @as(f32, @floatFromInt(char_data.size.x)) / @as(f32, @floatFromInt(width));
        const char_height = @as(f32, @floatFromInt(char_data.size.y)) / @as(f32, @floatFromInt(height));

        // Calculate horizontal and vertical bearing offsets to align glyphs relative to the baseline.
        // For example, the letter 'g' is a descender, so its vertical offset places it below the baseline.
        const bx = @as(f32, @floatFromInt(char_data.bearing.x)) / @as(f32, @floatFromInt(width)) * scale;
        const by = @as(f32, @floatFromInt((char_data.size.y - char_data.bearing.y))) / @as(f32, @floatFromInt(height)) * scale;

        // Calculate scaling factors to maintain correct aspect ratio and avoid texture stretching.
        const scale_x = @as(f32, @floatFromInt(char_data.size.x)) / @as(f32, @floatFromInt(height)) * scale;
        const scale_y = @as(f32, @floatFromInt(char_data.size.y)) / @as(f32, @floatFromInt(height)) * scale;

        instances[index % 32] = .{
            .bounds = .{ offset, offset + char_width, char_height, 0.0 },
            .char_pos = .{ pos[0] + bx + offset_x, pos[1] + by, pos[2] },
            .scale = .{ scale_x, scale_y },
        };

        if (index % batch_size == batch_size - 1 or index == s.len - 1) {
            const size = if (index + batch_size < s.len)
                batch_size
            else
                index - (index / batch_size) * batch_size + 1;
            try rdr().bufferUpdate(self.instance_buffer, std.mem.sliceAsBytes(instances[0..size]), batch_size * @sizeOf(CharInstance) * (index / batch_size));
        }

        // Convert advance from 1/64 pixels to pixels, normalize by font height, then apply scale.
        offset_x += @as(f32, @floatFromInt(char_data.advance >> 6)) / @as(f32, @floatFromInt(height)) * scale;
    }

    self.text = s;
}

pub fn draw(self: *const Self, render_pass: *Graph.RenderPass) void {
    render_pass.drawInstanced(Font.mesh, self.font.material, self.instance_buffer, 0, 6, 0, self.text.len, Font.ortho_matrix);
}

const std = @import("std");

const Self = @This();
const Renderer = @import("render/Renderer.zig");
const RID = Renderer.RID;
const Graph = @import("render/Graph.zig");
const Font = @import("Font.zig");

const CharData = extern struct {
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
        .instance_buffer = try rdr().bufferCreate(.{ .size = capacity * @sizeOf(CharData) }),
        .capacity = capacity,
    };
}

pub fn from(font: *const Font, s: []const u8) !Self {
    var text = try initCapacity(font, s.len);
    try text.set(s);
    return text;
}

pub fn set(self: *Self, s: []const u8) !void {
    if (s.len != self.text.len) {
        // recreate the buffer
    }

    // update the buffer

    self.text = s;
}

pub fn draw(self: *const Self, render_pass: *Graph.RenderPass) void {
    render_pass.drawInstanced(Font.mesh, self.material, self.instance_buffer, 0, 6, 0, self.text.len, Font.ortho_matrix);
}

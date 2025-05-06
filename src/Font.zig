const std = @import("std");
const c = @import("c");
const zm = @import("zmath");

const Self = @This();
const Renderer = @import("render/Renderer.zig");
const RID = Renderer.RID;
const Graph = @import("render/Graph.zig");

const rdr = Renderer.rdr;

// https://www.reddit.com/r/vulkan/comments/16ros2o/rendering_text_in_vulkan/
// https://github.com/baeng72/Programming-an-RTS/blob/main/common/Platform/Vulkan/VulkanFont.h
// https://github.com/baeng72/Programming-an-RTS/blob/main/common/Platform/Vulkan/VulkanFont.cpp

pub const Vec2i = struct {
    x: i32,
    y: i32,
};

pub const Vec2 = struct {
    x: f32,
    y: f32,
};

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

const Character = struct {
    size: Vec2i,
    bearing: Vec2i,
    offset: u32,
    advance: u32,
};

const FontUniform = extern struct {
    color: [4]f32,
};

const FontInstance = extern struct {
    bounds: [4]f32,
    char_pos: [3]f32,
    scale: [2]f32,
};

bitmap: RID,
material: RID,
uniform_buffer: RID,

characters: std.AutoHashMap(u8, Character),

width: usize,
height: usize,

var library: c.FT_Library = undefined;
pub var ortho_matrix: zm.Mat = undefined;
pub var mesh: RID = undefined;

var instance_buffer: RID = undefined;

pub fn orthographicRh(left: f32, right: f32, top: f32, bottom: f32, near: f32, far: f32) zm.Mat {
    const w = right - left;
    const h = bottom - top;

    return .{
        zm.f32x4(2 / w, 0.0, 0.0, 0.0),
        zm.f32x4(0.0, -2 / (top - bottom), 0.0, 0.0),
        zm.f32x4(0.0, 0.0, -1 / (far - near), 0.0),
        zm.f32x4(-(right + left) / w, -(top + bottom) / h, -near / (far - near), 1.0),
    };
}

pub fn initLib() !void {
    const res: c.FT_Error = c.FT_Init_FreeType(&library);

    if (res != 0) {
        std.log.err("Cannot initialize FreeType", .{});
        return error.CannotInitFreeType;
    }

    mesh = try rdr().meshCreate(.{
        .indices = std.mem.sliceAsBytes(@as([]const u16, &.{
            0, 1, 2,
            0, 2, 3,
        })),
        .vertices = std.mem.sliceAsBytes(@as([]const [3]f32, &.{

            // .{ -0.5, 0.5, -1.0 },
            // .{ 0.5, 0.5, -1.0 },
            // .{ 0.5, -0.5, -1.0 },
            // .{ -0.5, -0.5, -1.0 },

            // .{ -0.5, 1.0, -1.0 },
            // .{ 0.5, 1.0, -1.0 },
            // .{ 0.5, 0.0, -1.0 },
            // .{ -0.5, 0.0, -1.0 },

            .{ -0.5, 0.0, -1.0 },
            .{ 0.5, 0.0, -1.0 },
            .{ 0.5, -1.0, -1.0 },
            .{ -0.5, -1.0, -1.0 },
        })),
        .normals = std.mem.sliceAsBytes(@as([]const [3]f32, &.{
            .{ 0.0, 0.0, 0.0 },
            .{ 0.0, 0.0, 0.0 },
            .{ 0.0, 0.0, 0.0 },
            .{ 0.0, 0.0, 0.0 },
        })),
        .texture_coords = std.mem.sliceAsBytes(@as([]const [2]f32, &.{
            .{ 0.0, 0.0 },
            .{ 1.0, 0.0 },
            .{ 1.0, 1.0 },
            .{ 0.0, 1.0 },
        })),
    });

    instance_buffer = try rdr().bufferCreate(.{
        .size = @sizeOf(FontInstance) * 16,
        .usage = .{ .vertex_buffer = true, .transfer_dst = true },
    });

    const size = rdr().getSize();
    const aspect_ratio = @as(f32, @floatFromInt(size.width)) / @as(f32, @floatFromInt(size.height));

    ortho_matrix = orthographicRh(-1.0 * aspect_ratio, 1.0 * aspect_ratio, -1.0, 1.0, 0.01, 10.0);
}

pub fn init(font_name: [:0]const u8, font_size_: u32, allocator: std.mem.Allocator) !Self {
    var bmp_height: usize = 0;

    var characters = std.AutoHashMap(u8, Character).init(allocator);
    var data = std.AutoHashMap(u8, []const u8).init(allocator);
    defer data.deinit();

    const font_size = font_size_;

    var face: c.FT_Face = undefined;

    if (c.FT_New_Face(library, font_name.ptr, 0, &face) != 0) return error.CouldNotLoadFont;
    defer _ = c.FT_Done_Face(face);

    _ = c.FT_Set_Pixel_Sizes(face, 0, font_size);
    var bmp_width: u32 = 0;

    for (0..128) |char| {
        if (c.FT_Load_Char(face, @intCast(char), c.FT_LOAD_RENDER) != 0) {
            return error.CouldNotLoadChar;
        }

        bmp_height = @max(bmp_height, face.*.glyph.*.bitmap.rows);

        const character: Character = .{
            .size = .{ .x = @intCast(face.*.glyph.*.bitmap.width), .y = @intCast(face.*.glyph.*.bitmap.rows) },
            .bearing = .{ .x = @intCast(face.*.glyph.*.bitmap_left), .y = @intCast(face.*.glyph.*.bitmap_top) },
            .offset = bmp_width,
            .advance = @intCast(face.*.glyph.*.advance.x),
        };

        try characters.put(@intCast(char), character);

        if (face.*.glyph.*.bitmap.width > 0) {
            const char_data = try allocator.alloc(u8, face.*.glyph.*.bitmap.width * face.*.glyph.*.bitmap.rows);
            const glyph_buffer = face.*.glyph.*.bitmap.buffer;

            @memcpy(char_data, glyph_buffer[0 .. face.*.glyph.*.bitmap.width * face.*.glyph.*.bitmap.rows]);
            try data.put(@intCast(char), char_data);
        }
        bmp_width += face.*.glyph.*.bitmap.width;
    }

    const buffer = try allocator.alloc(u8, bmp_height * bmp_width);
    defer allocator.free(buffer);

    @memset(buffer, 0);

    var xpos: usize = 0;

    for (0..128) |char| {
        const character = characters.get(@intCast(char)) orelse continue;
        const char_data = data.get(@intCast(char)) orelse continue;

        const width: usize = @intCast(character.size.x);
        const height: usize = @intCast(character.size.y);

        for (0..width) |i| {
            for (0..height) |j| {
                const byte: u8 = char_data[i + j * width];
                buffer[(i + xpos) + j * bmp_width] = byte;
            }
        }
        xpos += width;
    }

    const texture_rid = try rdr().imageCreate(.{
        .width = @intCast(bmp_width),
        .height = @intCast(bmp_height),
        .format = .r8_unorm,
    });
    try rdr().imageSetLayout(texture_rid, .transfer_dst_optimal);
    try rdr().imageUpdate(texture_rid, buffer, 0, 0);
    try rdr().imageSetLayout(texture_rid, .shader_read_only_optimal);

    const font_uniform: FontUniform = .{
        .color = .{ 1.0, 1.0, 1.0, 1.0 },
    };

    const uniform_buffer_rid = try rdr().bufferCreate(.{
        .size = @sizeOf(FontUniform),
        .usage = .{ .uniform_buffer = true, .transfer_dst = true },
    });
    try rdr().bufferUpdate(uniform_buffer_rid, std.mem.asBytes(&font_uniform), 0);

    const material_rid = try rdr().materialCreate(.{
        .shaders = &.{
            .{ .path = "font.vert.spv", .stage = .{ .vertex = true } },
            .{ .path = "font.frag.spv", .stage = .{ .fragment = true } },
        },
        .transparency = false,
        .params = &.{
            .{ .name = "text", .type = .image, .stage = .{ .fragment = true } },
            .{ .name = "font", .type = .buffer, .stage = .{ .fragment = true } },
        },
        .instance_layout = .{
            .inputs = &.{
                .{ .type = .vec4, .offset = 0 },
                .{ .type = .vec3, .offset = 4 * @sizeOf(f32) },
                .{ .type = .vec2, .offset = 7 * @sizeOf(f32) },
            },
            .stride = @sizeOf(FontInstance),
        },
    });
    try rdr().materialSetParam(material_rid, "text", .{ .image = .{
        .rid = texture_rid,
        .sampler = .{ .mag_filter = .nearest, .min_filter = .nearest },
    } });
    try rdr().materialSetParam(material_rid, "font", .{ .buffer = uniform_buffer_rid });

    return Self{
        .bitmap = texture_rid,
        .material = material_rid,
        .uniform_buffer = uniform_buffer_rid,
        .width = @intCast(bmp_width),
        .height = @intCast(bmp_height),
        .characters = characters,
    };
}

pub fn deinit(self: *const Self) void {
    _ = self;

    // container -> self.data.deinit()
    // char_data -> allocator.free(char_data)
}

pub fn draw(self: *const Self, render_pass: *Graph.RenderPass, s: []const u8, pos: [3]f32, scale: f32) !void {
    var instances: [16]FontInstance = undefined;

    var offset_x: f32 = 0;

    for (s, 0..s.len) |char, index| {
        const char_data = self.characters.get(char) orelse unreachable;

        const offset = @as(f32, @floatFromInt(char_data.offset)) / @as(f32, @floatFromInt(self.width));
        const char_width = @as(f32, @floatFromInt(char_data.size.x)) / @as(f32, @floatFromInt(self.width));
        const char_height = @as(f32, @floatFromInt(char_data.size.y)) / @as(f32, @floatFromInt(self.height));

        const bx = @as(f32, @floatFromInt(char_data.bearing.x)) / @as(f32, @floatFromInt(self.width));
        const by = @as(f32, @floatFromInt(char_data.bearing.y)) / @as(f32, @floatFromInt(self.width));

        const scale_y = @as(f32, @floatFromInt(char_data.size.y)) / @as(f32, @floatFromInt(char_data.size.x));

        instances[index] = .{
            .bounds = .{ offset, offset + char_width, char_height, 0.0 },
            .char_pos = .{ pos[0] + bx + offset_x, pos[1] - by, pos[2] },
            .scale = .{ scale, scale * scale_y },
        };

        offset_x += 0.21;
    }

    try rdr().bufferUpdate(instance_buffer, std.mem.sliceAsBytes(&instances), 0);

    render_pass.drawInstanced(mesh, self.material, instance_buffer, 0, 6, 0, s.len, ortho_matrix);
}

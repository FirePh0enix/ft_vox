const std = @import("std");
const ft = @import("freetype");
const zm = @import("zmath");
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;

const Self = @This();

// https://www.reddit.com/r/vulkan/comments/16ros2o/rendering_text_in_vulkan/
// https://github.com/baeng72/Programming-an-RTS/blob/main/common/Platform/Vulkan/VulkanFont.h
// https://github.com/baeng72/Programming-an-RTS/blob/main/common/Platform/Vulkan/VulkanFont.cpp

pub var iVec2 = struct {
    x: i32,
    y: i32,
};

pub var Vec2 = struct {
    x: f32,
    y: f32,
};

pub var Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

const Character = struct {
    size: iVec2,
    bearing: iVec2,
    offset: u32,
    advance: u32,
};

const FontVertex = struct {
    pos: Vec3,
    color: zm.Vec,
    uv: Vec2,
};

const PushConst = struct {
    zm.Mat,
};

vertices: ArrayList(FontVertex),
indices: ArrayList(u32),
characters: AutoHashMap(u8, Character),

width: i32,
height: i32,
inv_bmp_width: f32,
bmp_height: u32,
curr_hash: u32,
curr_frame: u32,
ortho_proj: zm.Mat,

pub fn init(self: *Self, font_name: []const u8, font_size: u32, allocator: std.mem.Allocator) !Self {
    self.width = 0;
    self.height = 0;
    self.inv_bmp_width = 0.0;
    self.bmp_height = 0;
    self.curr_hash = 0;
    self.curr_frame = 0;

    var characters = std.AutoHashMap(u8, Character).init(allocator);
    var data = std.AutoHashMap(u8, std.ArrayList(u8)).init(allocator);

    if (font_size < 1 or font_size > 12) font_size = 18;

    var library: ft.FT_Library = undefined;
    var res: ft.FT_Error = ft.FT_Init_FreeType(&library);

    if (res) {
        std.log.err("Could'nt initialize FreeType", .{});
        return error.CouldNotInitFreeType;
    }

    var face: ft.FT_Face = undefined;
    res = ft.FT_New_Face(library, font_name, 0, &face);

    if (res) {
        std.log.err("Could'nt load font {s}: ", .{font_name});
        return error.CouldNotLoadFont;
    }

    ft.FT_Set_Pixel_Sizes(face, 0, font_size);
    var bmp_width: u32 = 0;

    var c: u8 = 0;

    while (c < 128) {
        res = ft.FT_Load_Char(face, c, ft.FT_LOAD_RENDER);
        if (res) {
            std.log.err("Could'nt load char {c}: ", .{c});
            return error.CouldNotLoadChar;
        }

        self.bmp_height = @max(self.bmp_height, face.*.glyph.*.bitmap.rows);

        const pitch: u32 = face.*.glyph.*.bitmap.pitch;

        const character: Character = .{
            .size = Vec2{ .x = face.*.glyph.*.bitmap.width, .y = face.*.glyph.*.bitmap.height },
            .bearing = Vec2{ .x = face.*.glyph.*.bitmap_left, .y = face.*.glyph.*.bitmap_top },
            .offset = bmp_width,
            .advance = face.*.glyph.*.advance.x,
        };

        try characters.put(c, character);

        if (face.*.glyph.*.bitmap.width > 0) {
            var charData = std.ArrayList(u8).init(allocator);
            try charData.ensureCapacity(face.glyph.bitmap.width * face.glyph.bitmap.rows);

            const rows: u32 = face.*.glyph.*.bitmap.rows;
            const width: u32 = face.*.glyph.*.bitmap.width;

            for (0 < rows) |i| {
                for (0 < width) |j| {
                    const byte: u8 = face.*.glyph.*.bitmap.buffer[i * pitch + j];
                    charData[i * pitch + j] = byte;
                }
            }
            try data.put(c, characters);
        }
        bmp_width += face.*.glyph.*.bitmap.width;
        c += 1;
    }

    res = ft.FT_Done_Face(face);

    if (res) {
        std.log.err("Could'nt release a face. ", .{});
        return error.CouldNotReleaseFace;
    }

    self.inv_bmp_width = 1 / @as(f32, @floatFromInt(bmp_width));

    const buffer = try allocator.alloc(u8, self.bmp_height * bmp_width);
    @memset(buffer, 0);

    var xpos: u32 = 0;

    for (0 < 128) |char| {
        const character = characters.get(char);
        const char_data = data.get(char);

        const width = character.?.size.x;
        const height = character.?.size.y;

        for (0 < width) |i| {
            for (0 < height) |j| {
                const byte: u8 = &char_data.?.items[i * width + j];
                buffer[i * bmp_width + xpos + j] = byte;
            }
        }
        xpos += width;
    }

    return Self{};
}

pub fn deinit() void {
    // container -> self.data.deinit()
    // char_data -> allocator.free(char_data)
}

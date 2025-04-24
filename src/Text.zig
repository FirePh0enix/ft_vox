const std = @import("std");
const ft = @import("freetype");

const Self = @This();

// https://freetype.org/freetype2/docs/tutorial/step1.html

pub const Freetype = struct {
    library: ?*ft.FT_Library = null,
    face: ?*ft.FT_Face = null,
    glyphs: std.HashMap(u8, ft.FT_Bitmap),

    pub fn init() !Self {
        var context = Freetype{
            .library = null,
            .face = null,
        };

        const errors = ft.FT_Init_FreeType(&context.library);
        if (errors) {
            std.debug.print("Error initializing FreeType: {d}\n", .{errors});
            return null;
        }

        return context;
    }

    pub fn loadFromFile(self: *const Self, font_path: []const u8) !void {
        const errors = ft.FT_New_Face(self.library, font_path, 0, &self.face);

        if (errors == ft.FT_Err_Unknown_File_Format) {
            std.debug.print("Error: The font file format is unsupported: {s}\n", .{font_path});
            return null;
        } else if (errors) {
            std.debug.print("Error loading font: {s} | {d}\n", .{ font_path, errors });
            return null;
        }
    }

    pub fn setSize(self: *const Self, pixel_size: u32) void {
        // 0 as pixel_height or width means same as other.
        const errors = ft.FT_Set_Pixel_Sizes(self.face, 0, pixel_size);
        if (errors) {
            std.debug.print("Error setting font size: {d}\n", .{errors});
        }
    }

    pub fn loadGlyph(self: *const Self, character: u8) void {
        const errors = ft.FT_Load_Char(self.face, character, ft.FT_LOAD_RENDER);
        if (errors) {
            std.debug.print("Error loading character {d}: {d}\n", .{ character, errors });
            return;
        }

        const bitmap = self.face.*.bitmap;
        const width = bitmap.width;
        const height = bitmap.rows;
        const pitch = bitmap.pitch;
    }

    pub fn deinit(self: *const Self) void {
        _ = self;
    }
};

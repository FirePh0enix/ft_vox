const std = @import("std");
const Self = @This();

const Renderer = @import("render/Renderer.zig");
const RID = Renderer.RID;
const Graph = @import("render/Graph.zig");
const Buffer = @import("render/Buffer.zig");
const Allocator = std.mem.Allocator;

const rdr = Renderer.rdr;
const root = @import("root");
const zigimg = @import("zigimg");
const assets = @import("assets.zig");
const zm = @import("zmath");

mesh: RID,
material_rid: RID,
image: RID,

pub fn createCube() !RID {
    return try rdr().meshCreate(.{
        .indices = std.mem.sliceAsBytes(@as([]const u16, &.{
            0, 1, 2, 2, 3, 0, // front
            20, 21, 22, 22, 23, 20, // back
            4, 5, 6, 6, 7, 4, // right
            12, 13, 14, 14, 15, 12, // left
            8, 9, 10, 10, 11, 8, // top
            16, 17, 18, 18, 19, 16, // bottom
        })),
        .vertices = std.mem.sliceAsBytes(@as([]const [3]f32, &.{
            // front
            .{ -0.5, -0.5, 0.5 },
            .{ 0.5, -0.5, 0.5 },
            .{ 0.5, 0.5, 0.5 },
            .{ -0.5, 0.5, 0.5 },
            // back
            .{ 0.5, -0.5, -0.5 },
            .{ -0.5, -0.5, -0.5 },
            .{ -0.5, 0.5, -0.5 },
            .{ 0.5, 0.5, -0.5 },
            // left
            .{ -0.5, -0.5, -0.5 },
            .{ -0.5, -0.5, 0.5 },
            .{ -0.5, 0.5, 0.5 },
            .{ -0.5, 0.5, -0.5 },
            // right
            .{ 0.5, -0.5, 0.5 },
            .{ 0.5, -0.5, -0.5 },
            .{ 0.5, 0.5, -0.5 },
            .{ 0.5, 0.5, 0.5 },
            // top
            .{ -0.5, 0.5, 0.5 },
            .{ 0.5, 0.5, 0.5 },
            .{ 0.5, 0.5, -0.5 },
            .{ -0.5, 0.5, -0.5 },
            // bottom
            .{ -0.5, -0.5, -0.5 },
            .{ 0.5, -0.5, -0.5 },
            .{ 0.5, -0.5, 0.5 },
            .{ -0.5, -0.5, 0.5 },
        })),
        .normals = std.mem.sliceAsBytes(@as([]const [3]f32, &.{
            // front
            .{ 0.0, 0.0, 1.0 },
            .{ 0.0, 0.0, 1.0 },
            .{ 0.0, 0.0, 1.0 },
            .{ 0.0, 0.0, 1.0 },
            // back
            .{ 0.0, 0.0, -1.0 },
            .{ 0.0, 0.0, -1.0 },
            .{ 0.0, 0.0, -1.0 },
            .{ 0.0, 0.0, -1.0 },
            // left
            .{ 1.0, 0.0, 0.0 },
            .{ 1.0, 0.0, 0.0 },
            .{ 1.0, 0.0, 0.0 },
            .{ 1.0, 0.0, 0.0 },
            // right
            .{ -1.0, 0.0, 0.0 },
            .{ -1.0, 0.0, 0.0 },
            .{ -1.0, 0.0, 0.0 },
            .{ -1.0, 0.0, 0.0 },
            // top
            .{ 0.0, 1.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            // bottom
            .{ 0.0, -1.0, 0.0 },
            .{ 0.0, -1.0, 0.0 },
            .{ 0.0, -1.0, 0.0 },
            .{ 0.0, -1.0, 0.0 },
        })),
        .texture_coords = std.mem.sliceAsBytes(@as([]const [2]f32, &.{
            .{ 0.0, 0.0 },
            .{ 1.0, 0.0 },
            .{ 1.0, 1.0 },
            .{ 0.0, 1.0 },

            .{ 0.0, 0.0 },
            .{ 1.0, 0.0 },
            .{ 1.0, 1.0 },
            .{ 0.0, 1.0 },

            .{ 0.0, 0.0 },
            .{ 1.0, 0.0 },
            .{ 1.0, 1.0 },
            .{ 0.0, 1.0 },

            .{ 0.0, 0.0 },
            .{ 1.0, 0.0 },
            .{ 1.0, 1.0 },
            .{ 0.0, 1.0 },

            .{ 0.0, 0.0 },
            .{ 1.0, 0.0 },
            .{ 1.0, 1.0 },
            .{ 0.0, 1.0 },

            .{ 0.0, 0.0 },
            .{ 1.0, 0.0 },
            .{ 1.0, 1.0 },
            .{ 0.0, 1.0 },
        })),
    });
}

pub fn init(allocator: Allocator) !Self {
    const box = try createCube();

    const image = try rdr().imageCreate(.{
        .width = 1024,
        .height = 1024,
        .layers = 6,
        .format = .r8g8b8a8_srgb,
    });

    const faces: []const []const u8 = &.{ "bk", "lf", "ft", "rt", "up", "dn" };

    try rdr().imageSetLayout(image, .transfer_dst_optimal);

    for (faces, 0..faces.len) |face, index| {
        var buf: [64]u8 = undefined;
        const filename = try std.fmt.bufPrint(&buf, "bluecloud_{s}.png", .{face});
        var pixel_buffer = try zigimg.Image.fromMemory(allocator, assets.getTextureData(filename));
        defer pixel_buffer.deinit();

        try rdr().imageUpdate(image, pixel_buffer.rawBytes(), 0, index);
    }

    try rdr().imageSetLayout(image, .shader_read_only_optimal);

    const material_rid = try rdr().materialCreate(.{
        .shaders = &.{
            .{ .path = "skybox.vert.spv", .stage = .{ .vertex = true } },
            .{ .path = "skybox.frag.spv", .stage = .{ .fragment = true } },
        },
        .params = &.{
            .{ .name = "cubemap", .type = .image, .stage = .{ .fragment = true } },
        },
        .cull_mode = .none,
    });

    try rdr().materialSetParam(material_rid, "cubemap", .{ .image = .{ .rid = image } });

    return .{
        .mesh = box,
        .material_rid = material_rid,
        .image = image,
    };
}

pub fn deinit(self: *Self) void {
    rdr().freeRid(self.mesh);
    rdr().freeRid(self.material_rid);
    rdr().freeRid(self.image);
}

pub fn encodeDraw(self: *const Self, render_pass: *Graph.RenderPass) void {
    const scale = zm.scaling(10.0, 10.0, 10.0);

    render_pass.draw(self.mesh, self.material_rid, 0, rdr().meshGetIndicesCount(self.mesh), zm.mul(root.camera.getViewProjMatrix(), scale));
}

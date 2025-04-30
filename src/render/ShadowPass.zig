const std = @import("std");
const c = @import("c");

const Self = @This();
const World = @import("../voxel/World.zig");
const Graph = @import("Graph.zig");
const Renderer = @import("Renderer.zig");
const RID = Renderer.RID;

const rdr = Renderer.rdr;

depth_image_rid: RID,
framebuffer_rid: RID,
render_pass_rid: RID,

width: usize,
height: usize,

material: RID,

pass: Graph.RenderPass,

var global_depth_image_rid: RID = undefined;
var global_depth_imgui_id: c_ulonglong = undefined;

pub const Options = struct {
    width: usize = 1024,
    height: usize = 1024,
    allocator: std.mem.Allocator,
};

pub fn init(options: Options) !Self {
    const res_w = options.width;
    const res_h = options.height;

    const depth_image_rid = try rdr().imageCreate(.{
        .width = res_w,
        .height = res_h,
        .format = .d32_sfloat,
        .usage = .{ .depth_stencil_attachment = true, .sampled = true },
        .aspect_mask = .{ .depth = true },
    });
    const render_pass_rid = try rdr().renderPassCreate(.{
        .attachments = &.{
            .{
                .type = .depth,
                .format = .d32_sfloat,
                .layout = .depth_stencil_attachment_optimal,
                .load_op = .clear,
                .store_op = .store,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .final_layout = .depth_stencil_read_only_optimal,
            },
        },
        .transition_depth_layout = true,
    });
    const framebuffer_rid = try rdr().framebufferCreate(.{
        .attachments = &.{depth_image_rid},
        .render_pass = render_pass_rid,
        .width = res_w,
        .height = res_h,
    });

    const material = try rdr().materialCreate(.{
        .shaders = &.{
            .{ .path = "cube_shadow.vert.spv", .stage = .{ .vertex = true } },
            .{ .path = "cube_shadow.frag.spv", .stage = .{ .fragment = true } },
        },
        .instance_layout = .{
            .inputs = &.{
                .{ .type = .vec3, .offset = 0 }, // position
                .{ .type = .vec3, .offset = 3 * @sizeOf(f32) }, // texture indices 0
                .{ .type = .vec3, .offset = 6 * @sizeOf(f32) }, // texture indices 1
                .{ .type = .uint, .offset = 9 * @sizeOf(f32) }, // visibility
            },
            .stride = @sizeOf(World.BlockInstanceData),
        },
    });

    const render_pass = try Graph.RenderPass.create(options.allocator, render_pass_rid, .{
        .max_draw_calls = 32 * 32,
        .target = .{
            .framebuffer = .{ .custom = framebuffer_rid },
            .scissor = .{ .custom = .{ .x = 0, .y = 0, .width = res_w, .height = res_h } },
            .viewport = .{ .custom = .{ .x = 0, .y = 0, .width = res_w, .height = res_h } },
        },
    });

    global_depth_image_rid = depth_image_rid;
    global_depth_imgui_id = try rdr().imguiAddTexture(global_depth_image_rid, .depth_stencil_read_only_optimal);

    return .{
        .depth_image_rid = depth_image_rid,
        .render_pass_rid = render_pass_rid,
        .framebuffer_rid = framebuffer_rid,
        .width = res_w,
        .height = res_h,
        .material = material,
        .pass = render_pass,
    };
}

pub fn debugHook(render_pass: *Graph.RenderPass) void {
    _ = render_pass;

    if (c.ImGui_Begin("Shadow", null, 0)) {
        c.ImGui_Image(global_depth_imgui_id, .{ .x = 200, .y = 200 });
    }
    c.ImGui_End();
}

pub fn deinit(self: *Self) void {
    self.pass.deinit();

    rdr().imguiRemoveTexture(global_depth_imgui_id);

    rdr().freeRid(self.material);
    rdr().freeRid(self.framebuffer_rid);
    rdr().freeRid(self.render_pass_rid);
    rdr().freeRid(self.depth_image_rid);
}

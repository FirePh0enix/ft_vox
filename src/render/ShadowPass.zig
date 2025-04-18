const std = @import("std");

const Self = @This();
const Renderer = @import("Renderer.zig");
const Graph = @import("Graph.zig");
const RID = Renderer.RID;

const rdr = Renderer.rdr;

depth_image_rid: RID,
framebuffer_rid: RID,
render_pass_rid: RID,

width: usize,
height: usize,

pub const Resolution = enum(u32) {
    full = 1,
    half = 2,
};

pub const Options = struct {
    resolution: Resolution = .full,
};

pub fn init(options: Options) !Self {
    const size = rdr().getSize();

    const res_w = size.width / @intFromEnum(options.resolution);
    const res_h = size.height / @intFromEnum(options.resolution);

    const depth_image_rid = try rdr().imageCreate(.{
        .width = res_w,
        .height = res_h,
        .format = .d32_sfloat,
        .usage = .{ .depth_stencil_attachment = true },
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
                .final_layout = .depth_stencil_attachment_optimal,
            },
        },
    });
    const framebuffer_rid = try rdr().framebufferCreate(.{
        .attachments = &.{depth_image_rid},
        .render_pass = render_pass_rid,
        .width = res_w,
        .height = res_h,
    });

    return .{
        .depth_image_rid = depth_image_rid,
        .render_pass_rid = render_pass_rid,
        .framebuffer_rid = framebuffer_rid,
        .width = res_w,
        .height = res_h,
    };
}

pub fn createRenderPass(self: *const Self, allocator: std.mem.Allocator) !Graph.RenderPass {
    return try Graph.RenderPass.create(allocator, self.render_pass_rid, .{
        .max_draw_calls = 32 * 32,
        .attachments = .{ .depth = true },
        .target = .{
            .framebuffer = .{ .custom = self.framebuffer_rid },
            .scissor = .{ .custom = .{ .x = 0, .y = 0, .width = self.width, .height = self.height } },
            .viewport = .{ .custom = .{ .x = 0, .y = 0, .width = self.width, .height = self.height } },
        },
    });
}

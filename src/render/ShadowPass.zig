const std = @import("std");

const Self = @This();
const Graph = @import("Graph.zig");
const ShaderModel = @import("ShaderModel.zig");
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

    const shader_model = try ShaderModel.init(options.allocator, .{
        .shaders = &.{
            .{ .path = "cube_shadow.vert.spv", .stage = .vertex },
        },
        .buffers = &.{
            ShaderModel.Buffer{ .element_type = .vec3, .rate = .vertex },
            ShaderModel.Buffer{ .element_type = .vec3, .rate = .vertex },
            ShaderModel.Buffer{ .element_type = .vec2, .rate = .vertex },
            ShaderModel.Buffer{ .element_type = .{ .buffer = &.{ .vec3, .vec3, .vec3, .uint } }, .rate = .instance },
        },
        .inputs = &.{
            ShaderModel.Input{ .binding = 0, .type = .vec3 }, // position
            ShaderModel.Input{ .binding = 1, .type = .vec3 }, // normal
            ShaderModel.Input{ .binding = 2, .type = .vec2 }, // texture coordinates
            ShaderModel.Input{ .binding = 3, .type = .vec3, .offset = 0 }, // instance position
            ShaderModel.Input{ .binding = 3, .type = .vec3, .offset = 3 * @sizeOf(f32) }, // instance texture indices 0
            ShaderModel.Input{ .binding = 3, .type = .vec3, .offset = 6 * @sizeOf(f32) }, // instance texture indices 1
            ShaderModel.Input{ .binding = 3, .type = .uint, .offset = 9 * @sizeOf(f32) }, // instance visibility
        },
        .descriptors = &.{},
        .push_constants = &.{
            ShaderModel.PushConstant{ .type = .{ .buffer = &.{.mat4} }, .stage = .vertex },
        },
    });

    const material = try rdr().materialCreate(.{
        .shader_model = shader_model,
    });

    const render_pass = try Graph.RenderPass.create(options.allocator, render_pass_rid, .{
        .max_draw_calls = 32 * 32,
        .target = .{
            .framebuffer = .{ .custom = framebuffer_rid },
            .scissor = .{ .custom = .{ .x = 0, .y = 0, .width = res_w, .height = res_h } },
            .viewport = .{ .custom = .{ .x = 0, .y = 0, .width = res_w, .height = res_h } },
        },
    });

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

pub fn deinit(self: *Self) void {
    self.pass.deinit();

    rdr().freeRid(self.material);
    rdr().freeRid(self.framebuffer_rid);
    rdr().freeRid(self.render_pass_rid);
    rdr().freeRid(self.depth_image_rid);
}

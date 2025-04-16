const std = @import("std");
const vk = @import("vulkan");
const zm = @import("zmath");

const Self = @This();
const Allocator = std.mem.Allocator;
const Material = @import("Material.zig");
const Mesh = @import("../Mesh.zig");
const Renderer = @import("Renderer.zig");
const RID = Renderer.RID;
const Rect = Renderer.Rect;

allocator: Allocator,
main_render_pass: ?*RenderPass = null,

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
    };
}

pub const Viewport = union(enum) {
    /// Use the swapchain extent as viewport.
    native: void,
    custom: Rect,
};

pub const Scissor = union(enum) {
    /// Use the swapchain extent as scissor.
    native: void,
    custom: Rect,
};

pub const Framebuffer = union(enum) {
    /// Use the swapchain framebuffer.
    native: void,
    custom: RID,
};

pub const RenderTarget = struct {
    viewport: Viewport = .native,
    scissor: Scissor = .native,
    framebuffer: Framebuffer = .native,
};

pub const PushConstants = extern struct {
    view_matrix: zm.Mat,
};

pub const RenderPassAttachments = packed struct {
    color: bool = false,
    depth: bool = false,
};

pub const RenderPassOptions = struct {
    attachments: RenderPassAttachments = .{},
    target: RenderTarget = .{},
    max_draw_calls: usize = 0,
};

pub const RenderPass = struct {
    allocator: Allocator,

    dependencies: std.ArrayListUnmanaged(*RenderPass) = .empty,

    render_pass: RID,

    target: RenderTarget,
    attachments: RenderPassAttachments,

    view_matrix: zm.Mat = zm.identity(),

    // TODO: Use a tree here to manage multiple meshes and materials to minimize pipeline, descriptor and buffer bindings.
    draw_calls: std.ArrayListUnmanaged(DrawCall),

    hooks: std.ArrayListUnmanaged(Hook) = .empty,
    imgui_hooks: std.ArrayListUnmanaged(Hook) = .empty,

    pub const Hook = *const fn (self: *RenderPass) void;

    pub fn create(allocator: Allocator, render_pass: RID, options: RenderPassOptions) !RenderPass {
        const draw_calls: std.ArrayListUnmanaged(DrawCall) = if (options.max_draw_calls > 0) try .initCapacity(allocator, options.max_draw_calls) else .empty;

        return .{
            .allocator = allocator,
            .target = options.target,
            .attachments = options.attachments,
            .draw_calls = draw_calls,
            .render_pass = render_pass,
        };
    }

    pub fn dependsOn(self: *RenderPass, dep: *RenderPass) void {
        self.dependencies.append(self.allocator, dep) catch unreachable;
    }

    pub fn addHook(self: *RenderPass, hook: Hook) void {
        self.hooks.append(self.allocator, hook) catch unreachable;
    }

    pub fn addImguiHook(self: *RenderPass, hook: Hook) void {
        self.imgui_hooks.append(self.allocator, hook) catch unreachable;
    }

    pub fn reset(self: *RenderPass) void {
        self.draw_calls.clearRetainingCapacity();
    }

    pub fn draw(
        self: *RenderPass,
        mesh: *const Mesh,
        material: *const Material,
        first_vertex: usize,
        vertex_count: usize,
    ) void {
        const draw_call: DrawCall = .{
            .mesh = mesh,
            .material = material,
            .first_vertex = first_vertex,
            .vertex_count = vertex_count,
        };

        self.draw_calls.append(self.allocator, draw_call) catch unreachable;
    }

    pub fn drawInstanced(
        self: *RenderPass,
        mesh: *const Mesh,
        material: *const Material,
        instance_buffer: RID,
        first_vertex: usize,
        vertex_count: usize,
        first_instance: usize,
        instance_count: usize,
    ) void {
        const draw_call: DrawCall = .{
            .mesh = mesh,
            .material = material,
            .instance_buffer = instance_buffer,
            .first_vertex = first_vertex,
            .vertex_count = vertex_count,
            .first_instance = first_instance,
            .instance_count = instance_count,
        };

        self.draw_calls.append(self.allocator, draw_call) catch unreachable;
    }
};

pub const DrawCall = struct {
    material: *const Material,
    mesh: *const Mesh,
    instance_buffer: ?RID = null,

    first_vertex: usize,
    vertex_count: usize,

    first_instance: usize = 0,
    instance_count: usize = 1,
};

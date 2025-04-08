const std = @import("std");
const vk = @import("vulkan");
const zm = @import("zmath");

const Self = @This();
const Allocator = std.mem.Allocator;
const Material = @import("Material.zig");
const Mesh = @import("../Mesh.zig");
const Buffer = @import("Buffer.zig");
const Image = @import("Image.zig");

allocator: Allocator,
main_render_pass: ?*RenderPass = null,

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
    };
}

pub const Rect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

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
    custom: vk.Framebuffer,
};

pub const RenderTarget = struct {
    framebuffer: Framebuffer = .native,
    viewport: Viewport = .native,
    scissor: Scissor = .native,
};

pub const PushConstants = struct {
    view_matrix: zm.Mat,
};

pub const RenderPassAttachments = packed struct {
    color: bool = false,
    depth: bool = false,
};

pub const RenderPassOptions = struct {
    attachments: RenderPassAttachments = .{},
    target: RenderTarget = .{},
};

pub const RenderPass = struct {
    allocator: Allocator,

    dependencies: std.ArrayListUnmanaged(*RenderPass) = .empty,

    vk_pass: vk.RenderPass, // TODO: Should be API agnostic

    target: RenderTarget,
    attachments: RenderPassAttachments,

    framebuffer_info: struct {
        image: Image,
        framebuffer: vk.Framebuffer,
    },

    view_matrix: zm.Mat = zm.identity(),

    // TODO: Use a tree here to manage multiple meshes and materials to minimize pipeline, descriptor and buffer bindings.
    draw_calls: std.ArrayListUnmanaged(DrawCall) = .empty,

    pub fn create(allocator: Allocator, options: RenderPassOptions) !RenderPass {
        return .{
            .allocator = allocator,
            .target = options.target,
            .attachments = options.attachments,
        };
    }

    pub fn dependsOn(self: *RenderPass, dep: *RenderPass) void {
        self.dependencies.append(self.allocator, dep) catch unreachable;
    }

    pub fn draw(
        self: *RenderPass,
        mesh: *Mesh,
        material: *Material,
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
        mesh: *Mesh,
        material: *Material,
        instance_buffer: *Buffer,
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
    material: *Material,
    mesh: *Mesh,
    instance_buffer: ?*Buffer = null,

    first_vertex: usize,
    vertex_count: usize,

    first_instance: usize = 0,
    instance_count: usize = 1,
};

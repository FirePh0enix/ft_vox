const std = @import("std");
const vk = @import("vulkan");

const Allocator = std.mem.Allocator;
const Material = @import("Material.zig");
const Mesh = @import("../Mesh.zig");
const Buffer = @import("Buffer.zig");
const Self = @This();

allocator: Allocator,
root_render_pass: ?*RenderPass = null,

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
    };
}

pub fn addRenderPass(
    self: *Self,
    target: RenderTarget,
) *RenderPass {
    const render_pass: *RenderPass = self.allocator.create(RenderPass);
    render_pass.* = .{
        .allocator = self.allocator,
        .target = target,
    };

    self.root_render_pass = render_pass;
    return render_pass;
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
    viewport: Rect = .native,
    scissor: Rect = .native,
};

pub const RenderPass = struct {
    allocator: Allocator,

    next: ?*RenderPass = null,

    target: RenderTarget,

    // TODO: Use a tree here to manage multiple meshes and materials.
    draw_calls: std.ArrayListUnmanaged(DrawCall) = .empty,

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

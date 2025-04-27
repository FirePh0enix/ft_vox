const std = @import("std");
const builtin = @import("builtin");
const wgpu = @import("webgpu");

const Allocator = std.mem.Allocator;
const Window = @import("Window.zig");
const Renderer = @import("Renderer.zig");
const RID = Renderer.RID;

const rdr = Renderer.rdr;

// https://developer.chrome.com/docs/web-platform/webgpu/build-app

pub const WebGPURenderer = struct {
    allocator: Allocator,

    instance: wgpu.Instance,
    adapter: wgpu.Adapter,
    device: wgpu.Device,
    surface: wgpu.Surface,

    pub const vtable: Renderer.VTable = .{
        .create_device = @ptrCast(&createDevice),
        .process_graph = undefined,
        .get_size = undefined,
        .get_statistics = undefined,

        .destroy = undefined,
        .configure = undefined,
        .get_output_render_pass = undefined,
        .wait_idle = undefined,

        .imgui_init = undefined,
        .imgui_destroy = undefined,
        .imgui_add_texture = undefined,
        .imgui_remove_texture = undefined,

        .free_rid = undefined,

        .buffer_create = undefined,
        .buffer_update = undefined,
        .buffer_map = undefined,
        .buffer_unmap = undefined,

        .image_create = undefined,
        .image_update = undefined,
        .image_set_layout = undefined,

        .material_create = undefined,
        .material_set_param = undefined,

        .mesh_create = undefined,
        .mesh_get_indices_count = undefined,

        .renderpass_create = undefined,

        .framebuffer_create = undefined,
    };

    pub fn createDevice(self: *WebGPURenderer, window: *const Window, index: ?usize) Renderer.CreateDeviceError!void {
        _ = window;
        _ = index;

        self.instance = wgpu.createInstance(null);

        const surface_canvas: wgpu.SurfaceSourceCanvasHTMLSelector = .{
            .chain = .{ .type = @enumFromInt(4) },
            .selector = "#canvas",
        };

        self.surface = self.instance.createSurface(&wgpu.SurfaceDescriptor{
            .next = @ptrCast(&surface_canvas.chain),
            .label = "",
        });

        self.adapter = self.instance.requestAdapterSync(&wgpu.RequestAdapterOptions{
            .compatible_surface = self.surface,
        });
    }
};

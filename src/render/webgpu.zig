const std = @import("std");
const builtin = @import("builtin");
const em = @import("em");

const Allocator = std.mem.Allocator;
const Window = @import("Window.zig");
const Renderer = @import("Renderer.zig");
const RID = Renderer.RID;

const rdr = Renderer.rdr;
const createWithInit = Renderer.createWithInit;

const wgpu = struct {
    pub const Instance = em.WGPUInstance;
    pub const Adapter = em.WGPUAdapter;
    pub const Device = em.WGPUDevice;
    pub const Surface = em.WGPUSurface;

    pub const RequestAdapterStatus = em.WGPURequestAdapterStatus;
    pub const RequestDeviceStatus = em.WGPURequestDeviceStatus;

    pub const RequestAdapterOptions = em.WGPURequestAdapterOptions;
    pub const SurfaceConfiguration = em.WGPUSurfaceConfiguration;

    pub const DeviceDescriptor = em.WGPUDeviceDescriptor;
    pub const SurfaceDescriptor = em.WGPUSurfaceDescriptor;
    pub const SurfaceDescriptorFromCanvasHTMLSelector = em.WGPUSurfaceDescriptorFromCanvasHTMLSelector;
    pub const BufferDescriptor = em.WGPUBufferDescriptor;

    pub const createInstance = em.wgpuCreateInstance;
    pub const instanceRequestAdapter = em.wgpuInstanceRequestAdapter;
    pub const adapterRequestDevice = em.wgpuAdapterRequestDevice;
};

// https://developer.chrome.com/docs/web-platform/webgpu/build-app

pub const WebGPURenderer = struct {
    allocator: Allocator,

    instance: wgpu.Instance,
    adapter: wgpu.Adapter,
    device: wgpu.Device,
    surface: wgpu.Surface,

    size: Renderer.Size,
    statistics: Renderer.Statistics = .{},

    pub const vtable: Renderer.VTable = .{
        .create_device = @ptrCast(&createDevice),
        .destroy = @ptrCast(&destroy),

        .process_graph = undefined,

        .get_size = @ptrCast(&getSize),
        .get_statistics = @ptrCast(&getStatistics),

        .configure = @ptrCast(&configure),
        .get_output_render_pass = undefined,
        .wait_idle = @ptrCast(&waitIdle),

        .imgui_init = undefined,
        .imgui_destroy = undefined,
        .imgui_add_texture = undefined,
        .imgui_remove_texture = undefined,

        .free_rid = @ptrCast(&freeRid),

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
        self.adapter = self.requestAdapter();
        self.device = self.requestDevice();

        const surface_from_canvas: wgpu.SurfaceDescriptorFromCanvasHTMLSelector = .{
            .chain = .{ .sType = em.WGPUSType_SurfaceDescriptorFromCanvasHTMLSelector },
            .selector = "#canvas",
        };

        const surface_descriptor: wgpu.SurfaceDescriptor = .{
            .nextInChain = &surface_from_canvas.chain,
        };

        self.surface = em.wgpuInstanceCreateSurface(self.instance, &surface_descriptor) orelse unreachable;
    }

    fn requestAdapter(self: *const WebGPURenderer) wgpu.Adapter {
        const RequestAdapterCallbackData = struct {
            found: std.atomic.Value(u8),
            adapter: wgpu.Adapter,
        };

        const request_adapter_callback = struct {
            fn callback(status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: ?[*:0]const u8, user_data: *RequestAdapterCallbackData) callconv(.c) void {
                _ = message;

                user_data.adapter = adapter;
                user_data.found.store(if (status == em.WGPURequestAdapterStatus_Success) 1 else 2, .release);
            }
        }.callback;

        var request_adapter_callback_data: RequestAdapterCallbackData = .{
            .found = .init(0),
            .adapter = undefined,
        };

        wgpu.instanceRequestAdapter(self.instance, &wgpu.RequestAdapterOptions{}, @ptrCast(&request_adapter_callback), @ptrCast(&request_adapter_callback_data));

        while (request_adapter_callback_data.found.load(.acquire) == 0) {
            em.emscripten_sleep(10);
        }
        return request_adapter_callback_data.adapter;
    }

    fn requestDevice(self: *const WebGPURenderer) wgpu.Device {
        const RequestDeviceCallbackData = struct {
            found: std.atomic.Value(u8),
            device: wgpu.Device,
        };

        const request_device_callback = struct {
            fn callback(status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: ?[*:0]const u8, user_data: *RequestDeviceCallbackData) callconv(.c) void {
                _ = message;

                user_data.device = device;
                user_data.found.store(if (status == em.WGPURequestAdapterStatus_Success) 1 else 2, .release);
            }
        }.callback;

        var request_device_callback_data: RequestDeviceCallbackData = .{
            .found = .init(0),
            .device = undefined,
        };

        wgpu.adapterRequestDevice(self.adapter, &wgpu.DeviceDescriptor{}, @ptrCast(&request_device_callback), @ptrCast(&request_device_callback_data));

        while (request_device_callback_data.found.load(.acquire) == 0) {
            em.emscripten_sleep(10);
        }
        return request_device_callback_data.device;
    }

    pub fn destroy(self: *WebGPURenderer) void {
        em.wgpuSurfaceRelease(self.surface);
        em.wgpuDeviceRelease(self.device);
        em.wgpuAdapterRelease(self.adapter);
        em.wgpuInstanceRelease(self.instance);
    }

    pub fn getSize(self: *WebGPURenderer) Renderer.Size {
        return self.size;
    }

    pub fn getStatistics(self: *WebGPURenderer) Renderer.Statistics {
        return self.statistics;
    }

    pub fn configure(self: *WebGPURenderer, options: Renderer.ConfigureOptions) void {
        em.wgpuSurfaceConfigure(self.surface, &wgpu.SurfaceConfiguration{
            .device = self.device,
            .presentMode = switch (options.vsync) {
                .off => em.WGPUPresentMode_Immediate,
                .performance, .smooth, .efficient => em.WGPUPresentMode_Fifo,
            },
            .format = em.WGPUTextureFormat_BGRA8UnormSrgb,
            .width = @intCast(options.width),
            .height = @intCast(options.height),
        });

        self.size = .{ .width = options.width, .height = options.height };
    }

    pub fn waitIdle(self: *WebGPURenderer) void {
        _ = self; // no-op ?
    }

    // --------------------------------------------- //
    // Resources

    //
    // Common
    //

    pub fn freeRid(self: *WebGPURenderer, rid: RID) void {
        _ = self;
        _ = rid;
        // TODO
    }

    //
    // Buffer
    //

    pub fn bufferCreate(self: *WebGPURenderer, options: Renderer.BufferOptions) Renderer.BufferUpdateError!RID {
        em.WGPUBufferUsage_CopyDst;

        const buffer = em.wgpuDeviceCreateBuffer(self.device, &wgpu.BufferDescriptor{
            .mappedAtCreation = 0,
            .size = @intCast(options.size),
            .usage = options.usage.asWGPU(),
        }) orelse return error.Failed;

        return .{ .inner = @intFromPtr(createWithInit(WebGPUBuffer, self.allocator, .{
            .size = options.size,
            .buffer = buffer,
        })) };
    }
};

pub const WebGPUBuffer = struct {
    pub const resource_signature: usize = @truncate(0x5f2b6d2738900ef9);

    signature: usize = resource_signature,
    size: usize,
    buffer: em.WGPUBuffer,

    pub fn deinit(self: *const WebGPUBuffer) void {
        em.wgpuBufferDestroy(self.buffer);
    }
};

const std = @import("std");
const builtin = @import("builtin");
const gl = @import("zgl");
const vk = if (builtin.os.tag != .emscripten) @import("vulkan") else void;

const Self = @This();
const Allocator = std.mem.Allocator;
const Graph = @import("Graph.zig");
const Device = @import("Device.zig");
const Window = @import("../Window.zig");
const VulkanRenderer = if (builtin.os.tag != .emscripten) @import("backend/vulkan.zig").VulkanRenderer else void;
const GLESRenderer = if (builtin.os.tag == .emscripten) @import("backend/gles.zig").GLESRenderer else void;

const runtime_safety = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

ptr: *anyopaque,
vtable: *const VTable,

pub const Driver = if (builtin.os.tag == .emscripten)
    DriverWeb
else
    DriverDesktop;

pub const DriverDesktop = enum {
    vulkan,
};

pub const DriverWeb = enum {
    gles,
};

pub const VSync = enum {
    off,
    performance,
    smooth,
    efficient,
};

pub const CreateSwapchainError = error{
    Unknown,
} || Allocator.Error;

pub const SwapchainOptions = struct {
    vsync: VSync,
};

pub const ProcessGraphError = error{Failed} || Allocator.Error;

pub const AllocUsage = enum {
    gpu_only,
    cpu_to_gpu,
};

pub const UpdateImageError = error{
    Failed,
    OutOfDeviceMemory,
} || Allocator.Error;

pub const ImageTiling = enum {
    optimal,
    linear,

    pub fn asVk(self: ImageTiling) vk.ImageTiling {
        return switch (self) {
            .optimal => .optimal,
            .linear => .linear,
        };
    }
};

pub const Format = enum {
    r8_srgb,
    r8_unorm,
    r8g8b8a8_srgb,
    b8g8r8a8_srgb,
    d32_sfloat,

    pub fn asVk(self: Format) vk.Format {
        return switch (self) {
            .r8_srgb => .r8_srgb,
            .r8_unorm => .r8_unorm,
            .r8g8b8a8_srgb => .r8g8b8a8_srgb,
            .b8g8r8a8_srgb => .b8g8r8a8_srgb,
            .d32_sfloat => .d32_sfloat,
        };
    }

    pub fn asGLInternal(self: Format) gl.TextureInternalFormat {
        return switch (self) {
            .r8_srgb, .r8_unorm => .r8,
            .r8g8b8a8_srgb => .rgba,
            .b8g8r8a8_srgb => unreachable,
            .d32_sfloat => .depth_component,
        };
    }

    pub fn asGLPixelFormat(self: Format) gl.PixelFormat {
        return switch (self) {
            .r8_srgb, .r8_unorm => .red,
            .r8g8b8a8_srgb => .rgba,
            .b8g8r8a8_srgb => unreachable,
            .d32_sfloat => .depth_component,
        };
    }

    pub fn asGLPixelType(self: Format) gl.PixelType {
        return switch (self) {
            .r8_srgb, .r8_unorm, .r8g8b8a8_srgb => .unsigned_byte,
            .d32_sfloat => .float,
            .b8g8r8a8_srgb => unreachable,
        };
    }

    pub fn fromVk(self: vk.Format) Format {
        return switch (self) {
            .r8_srgb => .r8_srgb,
            .r8_unorm => .r8_unorm,
            .r8g8b8a8_srgb => .r8g8b8a8_srgb,
            .b8g8r8a8_srgb => .b8g8r8a8_srgb,
            .d32_sfloat => .d32_sfloat,
            else => unreachable,
        };
    }

    pub fn sizeBytes(self: Format) usize {
        return switch (self) {
            .r8_srgb, .r8_unorm => 1,
            .r8g8b8a8_srgb, .b8g8r8a8_srgb, .d32_sfloat => 4,
        };
    }
};

// TODO: Some things like image layouts should probably be abstracted.

pub const ImageLayout = enum {
    undefined,
    color_attachment_optimal,
    depth_stencil_attachment_optimal,
    shader_read_only_optimal,
    depth_stencil_read_only_optimal,

    transfer_dst_optimal,

    present_src,

    pub fn asVk(self: ImageLayout) vk.ImageLayout {
        return switch (self) {
            .undefined => .undefined,
            .color_attachment_optimal => .color_attachment_optimal,
            .depth_stencil_attachment_optimal => .depth_stencil_attachment_optimal,
            .depth_stencil_read_only_optimal => .depth_stencil_read_only_optimal,
            .shader_read_only_optimal => .shader_read_only_optimal,
            .transfer_dst_optimal => .transfer_dst_optimal,
            .present_src => .present_src_khr,
        };
    }
};

pub const Filter = enum {
    nearest,
    linear,

    pub fn asVk(self: Filter) vk.Filter {
        return switch (self) {
            .nearest => .nearest,
            .linear => .linear,
        };
    }
};

pub const SamplerAddressMode = enum {
    repeat,
    mirrored_repeat,
    clamp_to_edge,
    clamp_to_border,

    pub fn asVk(self: SamplerAddressMode) vk.SamplerAddressMode {
        return switch (self) {
            .repeat => .repeat,
            .mirrored_repeat => .mirrored_repeat,
            .clamp_to_edge => .clamp_to_edge,
            .clamp_to_border => .clamp_to_border,
        };
    }
};

pub const PixelMapping = enum {
    identity,
    grayscale,
};

pub const ImageUsageFlags = packed struct {
    transfer_src: bool = false,
    transfer_dst: bool = false,
    sampled: bool = false,
    color_attachment: bool = false,
    depth_stencil_attachment: bool = false,

    pub fn asVk(self: ImageUsageFlags) vk.ImageUsageFlags {
        return .{
            .transfer_src_bit = self.transfer_src,
            .transfer_dst_bit = self.transfer_dst,
            .sampled_bit = self.sampled,
            .color_attachment_bit = self.color_attachment,
            .depth_stencil_attachment_bit = self.depth_stencil_attachment,
        };
    }
};

pub const ImageAspectFlags = packed struct {
    color: bool = false,
    depth: bool = false,

    pub fn asVk(self: ImageAspectFlags) vk.ImageAspectFlags {
        return .{
            .color_bit = self.color,
            .depth_bit = self.depth,
        };
    }
};

pub const BufferUsageFlags = packed struct {
    transfer_src: bool = false,
    transfer_dst: bool = false,
    uniform_buffer: bool = false,
    index_buffer: bool = false,
    vertex_buffer: bool = false,

    pub fn asVk(self: BufferUsageFlags) vk.BufferUsageFlags {
        return .{
            .transfer_src_bit = self.transfer_src,
            .transfer_dst_bit = self.transfer_dst,
            .uniform_buffer_bit = self.uniform_buffer,
            .index_buffer_bit = self.index_buffer,
            .vertex_buffer_bit = self.vertex_buffer,
        };
    }

    pub fn asGL(self: BufferUsageFlags) gl.BufferTarget {
        if (self.uniform_buffer) return .uniform_buffer;
        if (self.index_buffer) return .element_array_buffer;
        if (self.vertex_buffer) return .array_buffer;

        unreachable;
    }
};

pub const IndexType = enum {
    u16,
    u32,

    pub fn asVk(self: IndexType) vk.IndexType {
        return switch (self) {
            .u16 => .uint16,
            .u32 => .uint32,
        };
    }

    pub fn asGL(self: IndexType) gl.ElementType {
        return switch (self) {
            .u16 => .unsigned_short,
            .u32 => .unsigned_int,
        };
    }

    pub fn bytes(self: IndexType) usize {
        return switch (self) {
            .u16 => 2,
            .u32 => 4,
        };
    }
};

pub const ShaderStage = packed struct {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,

    pub fn asVk(self: ShaderStage) vk.ShaderStageFlags {
        return .{
            .vertex_bit = self.vertex,
            .fragment_bit = self.fragment,
            .compute_bit = self.compute,
        };
    }

    pub fn asGL(self: ShaderStage) gl.ShaderType {
        if (self.vertex) return .vertex;
        if (self.fragment) return .fragment;
        if (self.compute) unreachable;

        unreachable;
    }
};

pub const ShaderType = enum {
    float,
    vec2,
    vec3,
    vec4,

    uint,

    pub fn asVkFormat(self: ShaderType) vk.Format {
        return switch (self) {
            .float => .r32_sfloat,
            .vec2 => .r32g32_sfloat,
            .vec3 => .r32g32b32_sfloat,
            .vec4 => .r32g32b32a32_sfloat,
            .uint => .r32_uint,
        };
    }
};

pub const Topology = enum {
    triangle_list,

    pub fn asVk(self: Topology) vk.PrimitiveTopology {
        return switch (self) {
            .triangle_list => .triangle_list,
        };
    }
};

pub const PolygonMode = enum {
    fill,
    line,
    point,

    pub fn asVk(self: PolygonMode) vk.PolygonMode {
        return switch (self) {
            .fill => .fill,
            .line => .line,
            .point => .point,
        };
    }
};

pub const CullMode = enum {
    back,
    front,

    pub fn asVk(self: CullMode) vk.CullModeFlags {
        return switch (self) {
            .back => .{ .back_bit = true },
            .front => .{ .front_bit = true },
        };
    }
};

pub const Size = struct {
    width: usize,
    height: usize,
};

pub const Rect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

pub const Statistics = struct {
    gpu_time: f32 = 0.0,
    primitives_drawn: usize = 0,
    vram_used: usize = 0,
};

/// An opaque value used to interact with GPU resources.
pub const RID = extern struct {
    inner: usize,

    pub inline fn as(self: RID, comptime T: type) *T {
        if (!@hasDecl(T, "resource_signature") or !@hasField(T, "signature"))
            @compileError(std.fmt.comptimePrint("{s} is not a valid conversion from a RID", .{@typeName(T)}));

        if (runtime_safety) {
            const ptr: *T = @ptrFromInt(self.inner);
            if (ptr.signature != T.resource_signature) std.debug.panic("Mismatch signature, expected {x} but got {x}", .{ T.resource_signature, ptr.signature });
            return ptr;
        } else {
            return self.asNoCheck(T);
        }
    }

    pub inline fn asNoCheck(self: RID, comptime T: type) *T {
        return @ptrFromInt(self.inner);
    }

    pub fn tryAs(self: RID, comptime T: type) ?*T {
        const ptr: *T = @ptrFromInt(self.inner);
        if (ptr.signature == T.resource_signature) {
            return ptr;
        }
        return null;
    }
};

pub const VTable = struct {
    create_device: *const fn (self: *anyopaque, window: *const Window, index: ?usize) CreateDeviceError!void,

    destroy: *const fn (self: *anyopaque) void,

    process_graph: *const fn (self: *anyopaque, graph: *const Graph) ProcessGraphError!void,

    get_size: *const fn (self: *const anyopaque) Size,
    get_statistics: *const fn (self: *const anyopaque) Statistics,

    configure: *const fn (*anyopaque, options: ConfigureOptions) void,
    get_output_render_pass: *const fn (*anyopaque) RID,
    wait_idle: *const fn (*anyopaque) void,

    //
    // Dear ImGUI integration
    //

    imgui_init: *const fn (*anyopaque, window: *const Window, render_pass_rid: RID) void,
    imgui_destroy: *const fn (*anyopaque) void,
    imgui_add_texture: *const fn (*anyopaque, image_rid: RID, layout: ImageLayout) ImGuiAddTextureError!c_ulonglong,
    imgui_remove_texture: *const fn (*anyopaque, id: c_ulonglong) void,

    // --------------------------------------------- //
    // Resources

    //
    // Common
    //

    free_rid: *const fn (*anyopaque, rid: RID) void,

    //
    // Buffer
    //

    buffer_create: *const fn (*anyopaque, options: BufferOptions) BufferCreateError!RID,
    buffer_update: *const fn (*anyopaque, buffer_rid: RID, s: []const u8, offset: usize) BufferUpdateError!void,
    buffer_map: *const fn (*anyopaque, buffer_rid: RID) BufferMapError![]u8,
    buffer_unmap: *const fn (*anyopaque, buffer_rid: RID) void,

    //
    // Image
    //

    image_create: *const fn (*anyopaque, options: ImageOptions) ImageCreateError!RID,
    image_update: *const fn (*anyopaque, image_rid: RID, s: []const u8, offset: usize, layer: usize) UpdateImageError!void,
    image_set_layout: *const fn (*anyopaque, image_rid: RID, new_layout: ImageLayout) ImageSetLayoutError!void,

    //
    // Material
    //

    material_create: *const fn (*anyopaque, options: MaterialOptions) MaterialCreateError!RID,
    material_set_param: *const fn (*anyopaque, material_rid: RID, name: []const u8, value: MaterialParameterValue) MaterialSetParamError!void,

    //
    // Mesh
    //

    mesh_create: *const fn (*anyopaque, options: MeshOptions) MeshCreateError!RID,
    mesh_get_indices_count: *const fn (*anyopaque, mesh_rid: RID) usize,

    //
    // RenderPass
    //

    renderpass_create: *const fn (*anyopaque, options: RenderPassOptions) RenderPassCreateError!RID,

    //
    // Framebuffer
    //

    framebuffer_create: *const fn (*anyopaque, options: FramebufferOptions) FramebufferCreateError!RID,
};

pub const CreateError = error{} || Allocator.Error;

var singleton: Self = undefined;

pub fn rdr() *Self {
    return &singleton;
}

pub fn create(allocator: Allocator, driver: Driver) CreateError!void {
    if (builtin.os.tag == .emscripten) {
        switch (driver) {
            .opengl => {
                const renderer = try createWithDefault(GLESRenderer, allocator);
                renderer.allocator = allocator;

                singleton = .{
                    .ptr = renderer,
                    .vtable = &GLESRenderer.vtable,
                };
            },
        }
    } else {
        switch (driver) {
            .vulkan => {
                const renderer = try createWithDefault(VulkanRenderer, allocator);
                renderer.allocator = allocator;

                singleton = .{
                    .ptr = renderer,
                    .vtable = &VulkanRenderer.vtable,
                };
            },
        }
    }
}

pub inline fn asVk(self: *const Self) *VulkanRenderer {
    return @ptrCast(@alignCast(self.ptr));
}

pub inline fn asGL(self: *const Self) *GLESRenderer {
    return @ptrCast(@alignCast(self.ptr));
}

pub const CreateDeviceError = error{
    /// No device are suitable to run the engine.
    NoSuitableDevice,
} || Allocator.Error;

/// Initialize the driver and create the rendering device. If `index` is not null then the driver will try to use it, otherwise the most
/// suitable device will be selected.
pub inline fn createDevice(self: *const Self, window: *const Window, index: ?usize) CreateDeviceError!void {
    return self.vtable.create_device(self.ptr, window, index);
}

/// Free resources directly held by the renderer. Does not free RIDs.
pub inline fn destroy(self: *const Self) void {
    return self.vtable.destroy(self.ptr);
}

pub inline fn processGraph(self: *const Self, graph: *const Graph) ProcessGraphError!void {
    return self.vtable.process_graph(self.ptr, graph);
}

/// Returns the renderer window size.
pub inline fn getSize(self: *const Self) Size {
    return self.vtable.get_size(self.ptr);
}

pub inline fn getStatistics(self: *const Self) Statistics {
    return self.vtable.get_statistics(self.ptr);
}

pub const ConfigureOptions = struct {
    width: usize,
    height: usize,
    vsync: VSync,
};

pub const ConfigureError = error{ Failed, OutOfDeviceMemory } || Allocator.Error;

/// Configure or reconfigure the swapchain.
pub inline fn configure(self: *const Self, options: ConfigureOptions) ConfigureError!void {
    return self.vtable.configure(self.ptr, options);
}

pub inline fn getOutputRenderPass(self: *const Self) RID {
    return self.vtable.get_output_render_pass(self.ptr);
}

pub inline fn waitIdle(self: *const Self) void {
    return self.vtable.wait_idle(self.ptr);
}

//
// Dear ImGui integration
//

pub const ImGuiInitError = error{Failed};

pub inline fn imguiInit(self: *const Self, window: *const Window, render_pass_rid: RID) ImGuiInitError!void {
    return self.vtable.imgui_init(self.ptr, window, render_pass_rid);
}

pub inline fn imguiDestroy(self: *const Self) void {
    return self.vtable.imgui_destroy(self.ptr);
}

pub const ImGuiAddTextureError = error{Failed};

pub inline fn imguiAddTexture(self: *const Self, image_rid: RID, layout: ImageLayout) ImGuiAddTextureError!c_ulonglong {
    return self.vtable.imgui_add_texture(self.ptr, image_rid, layout);
}

pub inline fn imguiRemoveTexture(self: *const Self, id: c_ulonglong) void {
    return self.vtable.imgui_remove_texture(self.ptr, id);
}

//
// Common resources operations
//

pub inline fn freeRid(self: *const Self, rid: RID) void {
    return self.vtable.free_rid(self.ptr, rid);
}

//
// Buffer
//

pub const BufferOptions = struct {
    size: usize,
    usage: BufferUsageFlags,
    alloc_usage: AllocUsage = .gpu_only,
};

pub const BufferCreateError = error{
    Failed,
    OutOfDeviceMemory,
} || Allocator.Error;

pub inline fn bufferCreate(self: *const Self, options: BufferOptions) BufferCreateError!RID {
    return self.vtable.buffer_create(self.ptr, options);
}

pub const BufferUpdateError = error{
    Failed,
} || BufferCreateError;

pub inline fn bufferUpdate(self: *const Self, buffer_rid: RID, s: []const u8, offset: usize) BufferUpdateError!void {
    return self.vtable.buffer_update(self.ptr, buffer_rid, s, offset);
}

pub const BufferMapError = error{
    Failed,
};

pub inline fn bufferMap(self: *const Self, buffer_rid: RID) BufferMapError![]const u8 {
    return self.vtable.buffer_map(self.ptr, buffer_rid);
}

pub inline fn bufferUnmap(self: *const Self, buffer_rid: RID) void {
    return self.vtable.buffer_unmap(self.ptr, buffer_rid);
}

//
// Image
//

pub const ImageOptions = struct {
    width: usize,
    height: usize,
    layers: usize = 1,
    tiling: ImageTiling = .optimal,
    format: Format,
    usage: ImageUsageFlags = .{ .sampled = true, .transfer_dst = true },
    aspect_mask: ImageAspectFlags = .{ .color = true },
    pixel_mapping: PixelMapping = .identity,
};

pub const ImageCreateError = error{
    Failed,
    OutOfDeviceMemory,
} || Allocator.Error;

pub inline fn imageCreate(self: *const Self, options: ImageOptions) ImageCreateError!RID {
    return self.vtable.image_create(self.ptr, options);
}

pub inline fn imageUpdate(self: *const Self, image_rid: RID, s: []const u8, offset: usize, layer: usize) UpdateImageError!void {
    return self.vtable.image_update(self.ptr, image_rid, s, offset, layer);
}

pub const ImageSetLayoutError = error{
    Failed,
};

pub inline fn imageSetLayout(self: *const Self, image_rid: RID, new_layout: ImageLayout) ImageSetLayoutError!void {
    return self.vtable.image_set_layout(self.ptr, image_rid, new_layout);
}

//
// Material
//

pub const MaterialParameter = struct {
    name: []const u8,
    type: MaterialParameterValueType,
    stage: ShaderStage,
};

pub const MaterialParameterValueType = enum {
    image,
    buffer,

    pub fn asVk(self: MaterialParameterValueType) vk.DescriptorType {
        return switch (self) {
            .image => .combined_image_sampler,
            .buffer => .uniform_buffer,
        };
    }
};

pub const SamplerOptions = struct {
    mag_filter: Filter = .linear,
    min_filter: Filter = .linear,
    address_mode: struct {
        u: SamplerAddressMode = .clamp_to_edge,
        v: SamplerAddressMode = .clamp_to_edge,
        w: SamplerAddressMode = .clamp_to_edge,
    } = .{},

    // TODO: More of `vk.SamplerCreateInfo` could be implemented
};

pub const MaterialParameterValue = union(MaterialParameterValueType) {
    image: struct {
        rid: RID,
        sampler: SamplerOptions = .{},
        layout: ImageLayout = .shader_read_only_optimal,
    },
    buffer: RID,
};

pub const MaterialInstanceLayout = struct {
    pub const Input = struct {
        type: ShaderType,
        offset: usize,
    };

    inputs: []const Input,
    stride: usize,
};

pub const ShaderRef = struct {
    path: []const u8,
    stage: ShaderStage,
};

/// Minimum input for vertex shaders are:
///
///```glsl
///layout(location = 0) in vec3 position;
///layout(location = 1) in vec3 normal;
///layout(location = 2) in vec2 uv;
///
///layout(push_constant) uniform PushConstants {
///    mat4 viewMatrix;
///};
///```
///
/// A shader can have optionally instance data, specified in `instance_layout`, which will
/// start at location 3.
pub const MaterialOptions = struct {
    shaders: []const ShaderRef,

    /// Enable transparency for this material.
    transparency: bool = false,

    params: []const MaterialParameter = &.{},

    /// Desribe the layout of the instance buffer for this material.
    instance_layout: ?MaterialInstanceLayout = null,

    topology: Topology = .triangle_list,
    polygon_mode: PolygonMode = .fill,
    cull_mode: CullMode = .back,
};

pub const MaterialCreateError = error{
    Failed,
    OutOfDeviceMemory,
} || Allocator.Error;

pub inline fn materialCreate(self: *const Self, options: MaterialOptions) MaterialCreateError!RID {
    return self.vtable.material_create(self.ptr, options);
}

pub const MaterialSetParamError = error{ Failed, InvalidParam };

pub inline fn materialSetParam(self: *const Self, material_rid: RID, name: []const u8, value: MaterialParameterValue) MaterialSetParamError!void {
    return self.vtable.material_set_param(self.ptr, material_rid, name, value);
}

//
// Mesh
//

pub const MeshOptions = struct {
    indices: []const u8,
    vertices: []const u8,
    normals: []const u8,
    texture_coords: []const u8,

    /// Type of indices. If the type is `.u16` then `indices` must stores `u16`, or `u32` if
    /// the type is `.u32`.
    ///
    /// Since `.u32` use two times more memory than `.u16`, it should only be used if
    /// more than 65336 vertices are needed.
    index_type: IndexType = .u16,
};

pub const MeshCreateError = error{
    Failed,
    OutOfDeviceMemory,
} || Allocator.Error;

pub inline fn meshCreate(self: *const Self, options: MeshOptions) MeshCreateError!RID {
    return self.vtable.mesh_create(self.ptr, options);
}

pub inline fn meshGetIndicesCount(self: *const Self, mesh_rid: RID) usize {
    return self.vtable.mesh_get_indices_count(self.ptr, mesh_rid);
}

//
// RenderPass
//

pub const AttachmentLoadOp = enum {
    load,
    clear,
    dont_care,

    pub fn asVk(self: AttachmentLoadOp) vk.AttachmentLoadOp {
        return switch (self) {
            .load => .load,
            .clear => .clear,
            .dont_care => .dont_care,
        };
    }
};

pub const AttachmentStoreOp = enum {
    store,
    dont_care,

    pub fn asVk(self: AttachmentStoreOp) vk.AttachmentStoreOp {
        return switch (self) {
            .store => .store,
            .dont_care => .dont_care,
        };
    }
};

pub const AttachmentType = enum {
    color,
    depth,
};

pub const Attachment = struct {
    type: AttachmentType,
    layout: ImageLayout,
    format: Format,

    load_op: AttachmentLoadOp = .dont_care,
    store_op: AttachmentStoreOp = .dont_care,
    stencil_load_op: AttachmentLoadOp = .dont_care,
    stencil_store_op: AttachmentStoreOp = .dont_care,
    initial_layout: ImageLayout = .undefined,
    final_layout: ImageLayout,
};

pub const RenderPassOptions = struct {
    attachments: []const Attachment,

    // TODO: Workaround to not have to expose subpass.
    transition_depth_layout: bool = false,
};

pub const RenderPassCreateError = error{
    Failed,
} || Allocator.Error;

pub inline fn renderPassCreate(self: *const Self, options: RenderPassOptions) RenderPassCreateError!RID {
    return self.vtable.renderpass_create(self.ptr, options);
}

//
// Framebuffer
//

pub const FramebufferOptions = struct {
    attachments: []const RID,
    render_pass: RID,
    width: usize,
    height: usize,
};

pub const FramebufferCreateError = error{Failed} || Allocator.Error;

pub inline fn framebufferCreate(self: *const Self, options: FramebufferOptions) FramebufferCreateError!RID {
    return self.vtable.framebuffer_create(self.ptr, options);
}

/// Create a value and initialize it right away to prevent `undefined` values from getting into `T`.
pub fn createWithInit(comptime T: type, allocator: Allocator, value: T) Allocator.Error!*T {
    const ptr = try allocator.create(T);
    ptr.* = value;
    return ptr;
}

/// Create a value and fill its field with default values if applicable.
pub fn createWithDefault(comptime T: type, allocator: Allocator) Allocator.Error!*T {
    const info = @typeInfo(T);
    const ptr = try allocator.create(T);

    switch (info) {
        .@"struct" => |s| {
            inline for (s.fields) |field| {
                if (field.defaultValue()) |value|
                    @field(ptr.*, field.name) = value;
            }
        },
        else => {},
    }

    return ptr;
}

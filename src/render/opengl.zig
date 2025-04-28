const std = @import("std");
const builtin = @import("builtin");
const em = @import("em");
const gl = @import("zgl");
const assets = @import("../assets.zig");

const Allocator = std.mem.Allocator;
const Window = @import("Window.zig");
const Renderer = @import("Renderer.zig");
const RID = Renderer.RID;

const createWithInit = Renderer.createWithInit;

pub const OpenGLRenderer = struct {
    allocator: Allocator,
    context: em.EMSCRIPTEN_WEBGL_CONTEXT_HANDLE,
    size: Renderer.Size,
    statistics: Renderer.Statistics,

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

        .buffer_create = @ptrCast(&bufferCreate),
        .buffer_update = @ptrCast(&bufferUpdate),
        .buffer_map = @ptrCast(&bufferMap),
        .buffer_unmap = @ptrCast(&bufferUnmap),

        .image_create = @ptrCast(&imageCreate),
        .image_update = @ptrCast(&imageUpdate),
        .image_set_layout = @ptrCast(&imageSetLayout),

        .material_create = undefined,
        .material_set_param = undefined,

        .mesh_create = undefined,
        .mesh_get_indices_count = undefined,

        .renderpass_create = undefined,

        .framebuffer_create = undefined,
    };

    pub fn createDevice(self: *OpenGLRenderer, window: *const Window, index: ?usize) Renderer.CreateDeviceError!void {
        _ = window;
        _ = index;

        self.context = em.emscripten_webgl_create_context("#canvas", &em.EmscriptenWebGLContextAttributes{
            .majorVersion = 2,
            .minorVersion = 0,
        });

        _ = em.emscripten_webgl_make_context_current(self.context);
    }

    pub fn destroy(self: *OpenGLRenderer) void {
        _ = self;
    }

    pub fn getSize(self: *OpenGLRenderer) Renderer.Size {
        return self.size;
    }

    pub fn getStatistics(self: *OpenGLRenderer) Renderer.Statistics {
        return self.statistics;
    }

    pub fn configure(self: *OpenGLRenderer, options: Renderer.ConfigureOptions) void {
        _ = self;

        gl.viewport(0, 0, options.width, options.height);
    }

    pub fn waitIdle(self: *OpenGLRenderer) void {
        _ = self;
    }

    // --------------------------------------------- //
    // Resources

    //
    // Common
    //

    pub fn freeRid(self: *OpenGLRenderer, rid: RID) void {
        _ = self;
        _ = rid;
        // TODO
    }

    //
    // Buffer
    //

    pub fn bufferCreate(self: *OpenGLRenderer, options: Renderer.BufferOptions) Renderer.BufferCreateError!RID {
        const buffer = gl.genBuffer();
        buffer.storage(u8, options.size, null, .{ .map_read = true, .map_write = true, .client_storage = options.alloc_usage == .cpu_to_gpu });

        return .{ .inner = @intFromPtr(try createWithInit(GLBuffer, self.allocator, .{ .size = options.size, .buffer = buffer })) };
    }

    pub fn bufferUpdate(self: *OpenGLRenderer, buffer_rid: RID, s: []const u8, offset: usize) Renderer.BufferUpdateError!void {
        const range = try self.bufferMap(buffer_rid);
        defer self.bufferUnmap(buffer_rid);

        @memcpy(range[offset..], s);
    }

    pub fn bufferMap(self: *OpenGLRenderer, buffer_rid: RID) Renderer.BufferMapError![]u8 {
        _ = self;

        const buffer = buffer_rid.as(GLBuffer);
        return buffer.buffer.mapRange(u8, 0, buffer.size, .{ .read = true, .write = true });
    }

    pub fn bufferUnmap(self: *OpenGLRenderer, buffer_rid: RID) void {
        _ = self;

        const buffer = buffer_rid.as(GLBuffer);
        _ = buffer.buffer.unmap();
    }

    //
    // Image
    //

    pub fn imageCreate(self: *OpenGLRenderer, options: Renderer.ImageOptions) Renderer.ImageCreateError!RID {
        const texture = gl.genTexture();
        texture.storage2D(options.layers, options.format.asGLInternal(), options.width, options.height);

        return .{ .inner = @intFromPtr(try createWithInit(GLImage, self.allocator, .{
            .width = options.width,
            .height = options.height,
            .texture = texture,
            .format = options.format,
        })) };
    }

    pub fn imageUpdate(self: *OpenGLRenderer, image_rid: RID, s: []const u8, offset: usize, layer: usize) Renderer.UpdateImageError!void {
        _ = self;
        _ = offset; // TODO !!!!

        const image = image_rid.as(GLImage);
        image.texture.subImage2D(layer, 0, 0, image.width, image.height, image.format.asGL(), image.format.asGLPixelType(), s.ptr);
    }

    pub fn imageSetLayout(self: *OpenGLRenderer, image_rid: RID, new_layout: Renderer.ImageLayout) Renderer.ImageSetLayoutError!void {
        _ = self;
        _ = image_rid;
        _ = new_layout;
    }

    //
    // Material
    //

    pub fn materialCreate(self: *OpenGLRenderer, options: Renderer.MaterialOptions) Renderer.MaterialCreateError!RID {
        const program = gl.createProgram();

        for (options.shaders) |shader_ref| {
            const source = assets.getShaderData(shader_ref.path);
            const shader = gl.createShader(shader_ref.stage.asGL());

            shader.source(1, &.{source});
            shader.compile();

            program.attach(shader);
            shader.delete();
        }

        program.link();

        return .{ .inner = @intFromPtr(try createWithInit(GLMaterial, self.allocator, .{
            .width = options.width,
            .height = options.height,
            .program = program,
        })) };
    }

    pub fn materialSetParam(self: *OpenGLRenderer, material_rid: RID, name: []const u8, value: Renderer.MaterialParameterValue) Renderer.MaterialSetParamError!void {
        _ = self;
        _ = name;
        _ = material_rid;
        _ = value;

        // const material = material_rid.as(GLMaterial);

        // switch (value) {
        //     .image => |i| {},
        //     .buffer => |b| {},
        // }
    }
};

const GLBuffer = struct {
    pub const resource_signature: usize = @truncate(0xa762ba799a388d06);

    signature: usize = resource_signature,
    size: usize,
    buffer: gl.Buffer,
};

const GLImage = struct {
    pub const resource_signature: usize = @truncate(0x28ad24fc8d360f19);

    signature: usize = resource_signature,
    width: usize,
    height: usize,
    texture: gl.Texture,
    format: Renderer.Format,
};

const GLMaterial = struct {
    pub const resource_signature: usize = @truncate(0x3bb25ffc8d3afef5);

    signature: usize = resource_signature,
    program: gl.Program,

    topology: Renderer.Topology,
    polygon_mode: Renderer.PolygonMode,
    cull_mode: Renderer.CullMode,
};

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const gl = @import("zgl");
const assets = @import("../assets.zig");

const Allocator = std.mem.Allocator;
const Window = @import("Window.zig");
const Renderer = @import("Renderer.zig");
const RID = Renderer.RID;
const Graph = @import("Graph.zig");

const createWithInit = Renderer.createWithInit;

pub const OpenGLRenderer = struct {
    allocator: Allocator,
    context: c.EMSCRIPTEN_WEBGL_CONTEXT_HANDLE,
    size: Renderer.Size,
    statistics: Renderer.Statistics,
    output_renderpass: RID,

    pub const vtable: Renderer.VTable = .{
        .create_device = @ptrCast(&createDevice),
        .destroy = @ptrCast(&destroy),

        .process_graph = @ptrCast(&processGraph),

        .get_size = @ptrCast(&getSize),
        .get_statistics = @ptrCast(&getStatistics),

        .configure = @ptrCast(&configure),
        .get_output_render_pass = @ptrCast(&getOutputRenderPass),
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

        .material_create = @ptrCast(&materialCreate),
        .material_set_param = @ptrCast(&materialSetParam),

        .mesh_create = @ptrCast(&meshCreate),
        .mesh_get_indices_count = @ptrCast(&meshGetIndicesCount),

        .renderpass_create = @ptrCast(&renderPassCreate),

        .framebuffer_create = @ptrCast(&framebufferCreate),
    };

    pub fn createDevice(self: *OpenGLRenderer, window: *const Window, index: ?usize) Renderer.CreateDeviceError!void {
        _ = window;
        _ = index;

        self.context = c.emscripten_webgl_create_context("#canvas", &c.EmscriptenWebGLContextAttributes{
            .majorVersion = 2,
            .minorVersion = 0,
            .alpha = true,
            .depth = true,
        });

        _ = c.emscripten_webgl_make_context_current(self.context);

        gl.binding.load({}, webgl_get_proc_address) catch return error.NoSuitableDevice;

        gl.enable(.depth_test);

        self.output_renderpass = self.renderPassCreate(.{
            .attachments = &.{},
        }) catch return error.OutOfMemory;
    }

    pub fn destroy(self: *OpenGLRenderer) void {
        _ = self;
    }

    pub fn processGraph(self: *OpenGLRenderer, graph: *const Graph) Renderer.ProcessGraphError!void {
        _ = self;

        const rp = graph.main_render_pass orelse return error.Failed;

        for (rp.draw_calls.items) |*call| {
            const mesh = call.mesh.as(GLMesh);
            const material = call.material.as(GLMaterial);

            std.debug.assert(call.first_vertex == 0);

            material.program.use();
            material.vao.bind();

            gl.bindBuffer(mesh.element_buffer.as(GLBuffer).buffer, .element_array_buffer);

            gl.enableVertexAttribArray(0);
            gl.bindBuffer(mesh.vertex_buffer.as(GLBuffer).buffer, .array_buffer);

            gl.drawElements(.triangles, call.vertex_count, mesh.index_type, 0);
        }

        std.debug.print("{}\n", .{rp.draw_calls.items.len});

        _ = c.emscripten_webgl_commit_frame();
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

    pub fn getOutputRenderPass(self: *OpenGLRenderer) RID {
        return self.output_renderpass;
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
        const target = options.usage.asGL();

        const buffer = gl.genBuffer();
        gl.bindBuffer(buffer, target);
        defer gl.bindBuffer(.invalid, target);

        return .{ .inner = @intFromPtr(try createWithInit(GLBuffer, self.allocator, .{
            .size = options.size,
            .buffer = buffer,
            .target = target,
        })) };
    }

    pub fn bufferUpdate(self: *OpenGLRenderer, buffer_rid: RID, s: []const u8, offset: usize) Renderer.BufferUpdateError!void {
        _ = self;

        std.debug.assert(offset == 0);

        const buffer = buffer_rid.as(GLBuffer);

        gl.bindBuffer(buffer.buffer, buffer.target);
        defer gl.bindBuffer(.invalid, buffer.target);

        gl.bufferData(buffer.target, u8, s, .static_draw);
    }

    pub fn bufferMap(self: *OpenGLRenderer, buffer_rid: RID) Renderer.BufferMapError![]u8 {
        _ = self;

        const buffer = buffer_rid.as(GLBuffer);

        gl.bindBuffer(buffer.buffer, buffer.target);
        defer gl.bindBuffer(.invalid, buffer.target);

        return gl.mapBufferRange(.array_buffer, u8, 0, buffer.size, .{ .read = true, .write = true })[0..buffer.size];
    }

    pub fn bufferUnmap(self: *OpenGLRenderer, buffer_rid: RID) void {
        _ = self;

        const buffer = buffer_rid.as(GLBuffer);

        gl.bindBuffer(.invalid, buffer.target);
        defer gl.bindBuffer(.invalid, buffer.target);

        _ = gl.unmapBuffer(.array_buffer);
    }

    //
    // Image
    //

    pub fn imageCreate(self: *OpenGLRenderer, options: Renderer.ImageOptions) Renderer.ImageCreateError!RID {
        const target: gl.TextureTarget = if (options.layers > 1) .@"2d_array" else .@"2d";

        const texture = gl.genTexture();
        gl.bindTexture(texture, .@"2d");
        gl.texStorage2D(target, options.layers, options.format.asGLInternal(), options.width, options.height);

        return .{ .inner = @intFromPtr(try createWithInit(GLImage, self.allocator, .{
            .width = options.width,
            .height = options.height,
            .texture = texture,
            .format = options.format,
            .target = target,
        })) };
    }

    pub fn imageUpdate(self: *OpenGLRenderer, image_rid: RID, s: []const u8, offset: usize, layer: usize) Renderer.UpdateImageError!void {
        _ = self;

        std.debug.assert(offset == 0);

        const image = image_rid.as(GLImage);
        gl.bindTexture(image.texture, image.target);
        defer gl.bindTexture(.invalid, image.target);

        gl.texSubImage2D(image.target, layer, 0, 0, image.width, image.height, image.format.asGLPixelFormat(), image.format.asGLPixelType(), s.ptr);
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

            if (builtin.mode == .Debug) {
                const s = try shader.getCompileLog(self.allocator);
                defer self.allocator.free(s);

                if (s.len > 0) std.debug.print("{s}\n", .{s});
            }

            program.attach(shader);
            shader.delete();
        }

        program.link();

        if (builtin.mode == .Debug) {
            const s = try program.getCompileLog(self.allocator);
            defer self.allocator.free(s);

            if (s.len > 0) std.debug.print("{s}\n", .{s});
        }

        const params = try self.allocator.alloc(GLMaterial.Param, options.params.len);

        for (options.params, 0..options.params.len) |param, index| {
            params[index] = .{
                .name = try self.allocator.dupe(u8, param.name),
                .value = null,
            };
        }

        const vao = gl.genVertexArray();

        gl.bindVertexArray(vao);
        defer gl.bindVertexArray(.invalid);

        gl.enableVertexAttribArray(0); // vertex
        gl.vertexAttribPointer(0, 3, .float, false, 3 * @sizeOf(f32), 0);

        // gl.enableVertexAttribArray(1); // normal
        // gl.vertexAttribPointer(0, 3, .float, false, 3 * @sizeOf(f32), 0);

        // gl.enableVertexAttribArray(2); // uv
        // gl.vertexAttribPointer(0, 2, .float, false, 2 * @sizeOf(f32), 0);

        return .{ .inner = @intFromPtr(try createWithInit(GLMaterial, self.allocator, .{
            .program = program,
            .params = params,
            .topology = options.topology,
            .polygon_mode = options.polygon_mode,
            .cull_mode = options.cull_mode,
            .transparency = options.transparency,
            .vao = vao,
        })) };
    }

    pub fn materialSetParam(self: *OpenGLRenderer, material_rid: RID, name: []const u8, value: Renderer.MaterialParameterValue) Renderer.MaterialSetParamError!void {
        _ = self;

        const material = material_rid.as(GLMaterial);
        const param = material.getParam(name) orelse return error.InvalidParam;

        switch (value) {
            .image => |i| {
                _ = i;

                param.value = value;

                // TODO: Set sampling parameters here.
            },
            .buffer => |b| {
                _ = b;

                // const location = material.program.uniformBlockIndex(name) orelse unreachable;

                // param.value = value;
                // param.location = location;
                // FIXME
            },
        }
    }

    //
    // Mesh
    //

    pub fn meshCreate(self: *OpenGLRenderer, options: Renderer.MeshOptions) Renderer.MeshCreateError!RID {
        const element_buffer = try self.bufferCreate(.{ .size = options.index_type.bytes() * options.indices.len, .usage = .{ .index_buffer = true } });
        try self.bufferUpdate(element_buffer, options.indices, 0);

        const vertex_buffer = try self.bufferCreate(.{ .size = @sizeOf([3]f32) * options.vertices.len, .usage = .{ .vertex_buffer = true } });
        try self.bufferUpdate(vertex_buffer, options.vertices, 0);

        const normal_buffer = try self.bufferCreate(.{ .size = @sizeOf([3]f32) * options.normals.len, .usage = .{ .vertex_buffer = true } });
        try self.bufferUpdate(normal_buffer, options.normals, 0);

        const uv_buffer = try self.bufferCreate(.{ .size = @sizeOf([2]f32) * options.texture_coords.len, .usage = .{ .vertex_buffer = true } });
        try self.bufferUpdate(uv_buffer, options.texture_coords, 0);

        return .{ .inner = @intFromPtr(try createWithInit(GLMesh, self.allocator, .{
            .element_buffer = element_buffer,
            .vertex_buffer = vertex_buffer,
            .normal_buffer = normal_buffer,
            .uv_buffer = uv_buffer,
            .indices_count = options.indices.len / options.index_type.bytes(),
            .index_type = options.index_type.asGL(),
        })) };
    }

    pub fn meshGetIndicesCount(self: *OpenGLRenderer, mesh_rid: RID) usize {
        _ = self;

        const mesh = mesh_rid.as(GLMesh);
        return mesh.indices_count;
    }

    //
    // RenderPass
    //

    pub fn renderPassCreate(self: *OpenGLRenderer, options: Renderer.RenderPassOptions) Renderer.RenderPassCreateError!RID {
        _ = options;

        return .{ .inner = @intFromPtr(try createWithInit(GLRenderPass, self.allocator, .{})) };
    }

    //
    // Framebuffer
    //

    pub fn framebufferCreate(self: *OpenGLRenderer, options: Renderer.FramebufferOptions) Renderer.FramebufferCreateError!RID {
        _ = options;

        const fb = gl.genFramebuffer();

        return .{ .inner = @intFromPtr(try createWithInit(GLFramebuffer, self.allocator, .{
            .framebuffer = fb,
        })) };
    }
};

const GLBuffer = struct {
    pub const resource_signature: usize = @truncate(0xa762ba799a388d06);

    signature: usize = resource_signature,
    size: usize,
    buffer: gl.Buffer,
    target: gl.BufferTarget,
};

const GLImage = struct {
    pub const resource_signature: usize = @truncate(0x28ad24fc8d360f19);

    signature: usize = resource_signature,
    width: usize,
    height: usize,
    texture: gl.Texture,
    format: Renderer.Format,

    target: gl.TextureTarget,
};

const GLMaterial = struct {
    pub const resource_signature: usize = @truncate(0x3bb25ffc8d3afef5);

    const Param = struct {
        name: []const u8,
        value: ?Renderer.MaterialParameterValue = null,
        // Either the uniform location or block index.
        location: u32 = 0,
    };

    signature: usize = resource_signature,
    program: gl.Program,
    vao: gl.VertexArray,

    topology: Renderer.Topology,
    polygon_mode: Renderer.PolygonMode,
    cull_mode: Renderer.CullMode,

    transparency: bool,

    params: []Param,

    pub fn getParam(self: *const GLMaterial, name: []const u8) ?*Param {
        for (self.params) |*param| {
            if (std.mem.eql(u8, param.name, name)) return param;
        }
        return null;
    }
};

const GLMesh = struct {
    pub const resource_signature: usize = @truncate(0xf8e46f97e5191997);

    signature: usize = resource_signature,

    element_buffer: RID,
    vertex_buffer: RID,
    normal_buffer: RID,
    uv_buffer: RID,

    indices_count: usize,
    index_type: gl.ElementType,
};

const GLRenderPass = struct {
    pub const resource_signature: usize = @truncate(0xa2f319ccb4be8b06);

    signature: usize = resource_signature,
};

const GLFramebuffer = struct {
    pub const resource_signature: usize = @truncate(0x66654a3561048ca7);

    signature: usize = resource_signature,
    framebuffer: gl.Framebuffer,
};

fn webgl_get_proc_address(ctx: void, name: [:0]const u8) ?gl.binding.FunctionPointer {
    _ = ctx;
    return @ptrCast(c.emscripten_webgl_get_proc_address(name.ptr));
}

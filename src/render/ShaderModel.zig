const std = @import("std");
const vk = @import("vulkan");

const Self = @This();
const Allocator = std.mem.Allocator;

pub const InputRate = enum(u32) {
    vertex = 0,
    instance = 1,

    pub fn toVk(self: InputRate) vk.VertexInputRate {
        switch (self) {
            .vertex => return .vertex,
            .instance => return .instance,
        }
    }
};

pub const Type = union(enum) {
    float: void,
    int: void,
    uint: void,

    vec2: void,
    vec3: void,
    vec4: void,

    dvec2: void,
    dvec3: void,
    dvec4: void,

    mat4: void,

    buffer: []const Type,

    pub fn slots(self: Type) usize {
        switch (self) {
            .float, .int, .uint, .vec2, .vec3, .vec4, .dvec2 => return 1,
            .dvec3, .dvec4 => return 2,
            .mat4 => return 4,
            .buffer => |fields| {
                var num_of_slots: usize = 0;
                for (fields) |field| num_of_slots += field.slots();
                return num_of_slots;
            },
        }
    }

    pub fn byteSize(self: Type) usize {
        switch (self) {
            .float, .int, .uint => return @sizeOf(f32),
            .vec2 => return 2 * @sizeOf(f32),
            .vec3 => return 3 * @sizeOf(f32),
            .vec4 => return 4 * @sizeOf(f32),
            .dvec2 => return 2 * @sizeOf(f64),
            .dvec3 => return 3 * @sizeOf(f64),
            .dvec4 => return 4 * @sizeOf(f64),
            .mat4 => return 4 * 4 * @sizeOf(f32),
            .buffer => |fields| {
                var size: usize = 0;
                for (fields) |field| size += field.byteSize();
                return size;
            },
        }
    }
};

pub const Input = struct {
    binding: usize,
    type: Type,
    offset: usize = 0,
};

pub const Buffer = struct {
    rate: InputRate,
    element_type: Type,
};

pub const Stage = enum {
    vertex,
    fragment,
    geometry,
    compute,

    pub fn toVkFlags(self: Stage) vk.ShaderStageFlags {
        switch (self) {
            .vertex => return .{ .vertex_bit = true },
            .fragment => return .{ .fragment_bit = true },
            .geometry => return .{ .geometry_bit = true },
            .compute => return .{ .compute_bit = true },
        }
    }
};

pub const PushConstant = struct {
    type: Type,
    // TODO: Allow multiple stages.
    stage: Stage,
    offset: usize = 0,
};

pub const Descriptor = struct {
    binding: usize,
    type: vk.DescriptorType,
    // TODO: Allow multiple stages.
    stage: Stage,
};

pub const ShaderRef = struct {
    path: []const u8,
    stage: ?Stage = null,
    fn_name: ?[:0]const u8 = null,

    pub fn getStage(self: *const ShaderRef) Stage {
        if (self.stage) |stage|
            return stage;

        const ext = std.fs.path.extension(self.path);

        if (std.mem.eql(u8, ext, ".vert")) {
            return .vertex;
        } else if (std.mem.eql(u8, ext, ".frag")) {
            return .fragment;
        } else {
            return .compute;
        }
    }
};

pub const Options = struct {
    shaders: []const ShaderRef,

    buffers: []const Buffer = &.{},
    inputs: []const Input = &.{},
    push_constants: []const PushConstant = &.{},
    descriptors: []const Descriptor = &.{},

    topology: vk.PrimitiveTopology = .triangle_list,
    polygon_mode: vk.PolygonMode = .fill,
    cull_mode: vk.CullModeFlags = .{ .back_bit = true },
};

// TODO: Remove all vulkan stuff from here.

vk_bindings: std.ArrayList(vk.VertexInputBindingDescription),
vk_attribs: std.ArrayList(vk.VertexInputAttributeDescription),
vk_push_constants: std.ArrayList(vk.PushConstantRange),
vk_descriptor_bindings: std.ArrayList(vk.DescriptorSetLayoutBinding),

topology: vk.PrimitiveTopology,
polygon_mode: vk.PolygonMode,
cull_mode: vk.CullModeFlags,

shaders: []const ShaderRef,

pub fn init(
    allocator: Allocator,
    comptime options: Options,
) !Self {
    inline for (options.inputs) |input| {
        if (input.binding > options.buffers.len)
            @compileError(std.fmt.comptimePrint("Binding out of bounds, got {} but len is {}", .{ input.binding, options.buffers.len }));
    }

    var vk_bindings: std.ArrayList(vk.VertexInputBindingDescription) = try .initCapacity(allocator, options.buffers.len);
    errdefer vk_bindings.deinit();

    inline for (options.buffers, 0..options.buffers.len) |buffer, index| {
        vk_bindings.appendAssumeCapacity(vk.VertexInputBindingDescription{
            .binding = @intCast(index),
            .input_rate = buffer.rate.toVk(),
            .stride = @intCast(buffer.element_type.byteSize()),
        });
    }

    const vk_attribs = try convertToVkAttribs(allocator, options.inputs);
    errdefer vk_attribs.deinit();

    var vk_push_constants: std.ArrayList(vk.PushConstantRange) = try .initCapacity(allocator, options.push_constants.len);
    errdefer vk_push_constants.deinit();

    for (options.push_constants) |push_constant| {
        vk_push_constants.appendAssumeCapacity(vk.PushConstantRange{ .offset = @intCast(push_constant.offset), .size = @intCast(push_constant.type.byteSize()), .stage_flags = push_constant.stage.toVkFlags() });
    }

    var vk_descriptor_bindings: std.ArrayList(vk.DescriptorSetLayoutBinding) = try .initCapacity(allocator, options.descriptors.len);
    errdefer vk_descriptor_bindings.deinit();

    for (options.descriptors) |descriptor| {
        // TODO: Check what is `p_immutable_samplers` and if it can be used to optimize the code.
        vk_descriptor_bindings.appendAssumeCapacity(.{ .binding = @intCast(descriptor.binding), .descriptor_type = descriptor.type, .descriptor_count = 1, .stage_flags = descriptor.stage.toVkFlags(), .p_immutable_samplers = null });
    }

    return .{
        .vk_bindings = vk_bindings,
        .vk_attribs = vk_attribs,
        .vk_push_constants = vk_push_constants,
        .vk_descriptor_bindings = vk_descriptor_bindings,

        .topology = options.topology,
        .polygon_mode = options.polygon_mode,
        .cull_mode = options.cull_mode,
        .shaders = options.shaders,
    };
}

pub fn deinit(self: *const Self) void {
    self.vk_bindings.deinit();
    self.vk_attribs.deinit();
    self.vk_push_constants.deinit();
    self.vk_descriptor_bindings.deinit();
}

fn countVkInputs(comptime inputs: []const Input) usize {
    var slots: usize = 0;

    for (inputs) |input| {
        slots += input.type.slots();
    }

    return slots;
}

fn convertToVkAttribs(allocator: Allocator, comptime inputs: []const Input) !std.ArrayList(vk.VertexInputAttributeDescription) {
    var vk_attribs: std.ArrayList(vk.VertexInputAttributeDescription) = try .initCapacity(allocator, countVkInputs(inputs));
    var location: usize = 0;

    for (inputs) |input| {
        if (input.type == .mat4) {
            vk_attribs.appendAssumeCapacity(vk.VertexInputAttributeDescription{ .binding = @intCast(input.binding), .location = @intCast(location), .format = .r32g32b32a32_sfloat, .offset = @intCast(input.offset) });
            vk_attribs.appendAssumeCapacity(vk.VertexInputAttributeDescription{ .binding = @intCast(input.binding), .location = @intCast(location + 1), .format = .r32g32b32a32_sfloat, .offset = @intCast(input.offset + 16) });
            vk_attribs.appendAssumeCapacity(vk.VertexInputAttributeDescription{ .binding = @intCast(input.binding), .location = @intCast(location + 2), .format = .r32g32b32a32_sfloat, .offset = @intCast(input.offset + 32) });
            vk_attribs.appendAssumeCapacity(vk.VertexInputAttributeDescription{ .binding = @intCast(input.binding), .location = @intCast(location + 3), .format = .r32g32b32a32_sfloat, .offset = @intCast(input.offset + 48) });
        } else {
            const format: vk.Format = switch (input.type) {
                .float => .r32_sfloat,
                .int => .r32_sint,
                .uint => .r32_uint,
                .vec2 => .r32g32_sfloat,
                .vec3 => .r32g32b32_sfloat,
                .vec4 => .r32g32b32a32_sfloat,
                .dvec2 => .r64g64_sfloat,
                .dvec3 => .r64g64b64_sfloat,
                .dvec4 => .r64g64b64a64_sfloat,
                .mat4 => unreachable,
                .buffer => unreachable,
            };

            vk_attribs.appendAssumeCapacity(vk.VertexInputAttributeDescription{ .binding = @intCast(input.binding), .location = @intCast(location), .format = format, .offset = @intCast(input.offset) });
        }

        location += input.type.slots();
    }

    return vk_attribs;
}

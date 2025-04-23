const std = @import("std");

const bufPrint = std.fmt.bufPrint;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var source = std.json.Scanner.initCompleteInput(std.heap.smp_allocator, @embedFile("webgpu.json"));
    defer source.deinit();

    var diagnostics: std.json.Diagnostics = .{};
    source.enableDiagnostics(&diagnostics);

    const webgpu = std.json.parseFromTokenSource(WebGPU, std.heap.smp_allocator, &source, .{}) catch |e| {
        std.debug.panic("json parsing: {}:{}", .{ diagnostics.getLine(), diagnostics.getColumn() });
        return e;
    };
    defer webgpu.deinit();

    var writer = DynamicWriter.init(b.allocator);
    try generateBindings(webgpu.value, &writer);

    const write_file = b.addWriteFiles();
    const generated_path = write_file.add("webgpu.zig", writer.string());

    const module = b.addModule("webgpu", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = generated_path,
    });

    _ = module;
}

const DynamicWriter = struct {
    data: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) DynamicWriter {
        return .{
            .data = .init(allocator),
        };
    }

    pub fn writeAll(self: *DynamicWriter, bytes: []const u8) !void {
        try self.data.appendSlice(bytes);
    }

    pub fn string(self: *const DynamicWriter) []const u8 {
        return self.data.items;
    }
};

fn generateBindings(webgpu: WebGPU, file: *DynamicWriter) !void {
    try file.writeAll(
        \\const std = @import("std");
        \\
        \\pub const Bool = u32;
        \\pub const TRUE: Bool = 1;
        \\pub const FALSE: Bool = 0;
        \\
        \\
    );

    for (webgpu.constants) |constant| try generateConstant(constant, file);

    try file.writeAll(
        \\
        \\
    );

    const with_null: []const []const u8 = &.{
        "callback_mode",
    };

    for (webgpu.enums) |@"enum"| try generateEnum(@"enum", with_null, file);

    try file.writeAll(
        \\
    );

    for (webgpu.bitflags) |bitflags| try generateBitflags(bitflags, file);

    try file.writeAll(
        \\
    );

    for (webgpu.structs) |@"struct"| try generateStruct(@"struct", file);

    try file.writeAll(toplevel_structs);

    try file.writeAll(
        \\
    );

    for (webgpu.objects) |object| try generateObject(object, file);

    try file.writeAll(
        \\
    );

    for (webgpu.callbacks) |callback| try generateCallback(callback, file);

    try file.writeAll(
        \\
    );

    for (webgpu.functions) |function| try generateFunction(function, file);

    try file.writeAll(
        \\
        \\const c = struct {
        \\
    );

    var buf: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    var buf3: [128]u8 = undefined;

    for (webgpu.objects) |object| {
        for (object.methods) |method| {
            try file.writeAll(bufPrint(&buf, "    pub extern fn wgpu{s}{s}(", .{ convertToCamelCase(&buf2, object.name, true), convertToCamelCase(&buf3, method.name, true) }) catch unreachable);

            try file.writeAll(argToString(&buf2, Arg{
                .name = "self",
                .doc = "",
                .type = bufPrint(&buf3, "object.{s}", .{object.name}) catch unreachable,
            }));

            if (method.args.len > 0) try file.writeAll(", ");

            var index: usize = 0;

            for (method.args) |arg| {
                try file.writeAll(argToString(&buf2, arg));

                if (index < method.args.len - 1)
                    try file.writeAll(", ");

                index += 1;
            }

            if (method.callback) |callback| {
                try file.writeAll(bufPrint(&buf, ", callback: {s}CallbackInfo", .{convertToCamelCase(&buf2, callback[9..], true)}) catch unreachable);
            }

            try file.writeAll(") callconv(.c) ");

            if (method.returns) |ret| {
                const arg_type = typeToString(&buf2, ret.type);

                try file.writeAll(arg_type);
            } else if (method.callback) |_| {
                try file.writeAll("Future");
            } else {
                try file.writeAll("void");
            }

            try file.writeAll(";\n");
        }
    }

    for (webgpu.functions) |function| try generateExternFunction(function, file);

    try file.writeAll(
        \\};
        \\
    );
}

// TODO: Probably should generate things like `WGPUError!Adapter` for some functions.
// TODO: Check errors

const instance_methods: []const u8 =
    \\    pub fn requestAdapterSync(self: Instance, options: ?*const RequestAdapterOptions) Adapter {
    \\        const CallbackResult = struct {
    \\            status: RequestAdapterStatus = .success,
    \\            adapter: ?Adapter = null,
    \\            mutex: std.Thread.Mutex = .{},
    \\        };
    \\
    \\        const callback = struct {
    \\            fn callback(status: RequestAdapterStatus, adapter: Adapter, message: [*:0]const u8, user_data: *CallbackResult) callconv(.c) void {
    \\                _ = message;
    \\                user_data.status = status;
    \\                user_data.adapter = adapter;
    \\                user_data.mutex.unlock();
    \\            }
    \\        }.callback;
    \\
    \\        var user_data: CallbackResult = .{};
    \\        user_data.mutex.lock();
    \\
    \\        _ = self.requestAdapter(options, .{
    \\            .callback = @ptrCast(&callback),
    \\            .user_data1 = @ptrCast(&user_data),
    \\        });
    \\
    \\        user_data.mutex.lock();
    \\        defer user_data.mutex.unlock();
    \\
    \\        return user_data.adapter orelse unreachable;
    \\    }
;

const adapter_methods: []const u8 =
    \\    pub fn requestDeviceSync(self: Adapter, descriptor: ?*const DeviceDescriptor) Device {
    \\        const CallbackResult = struct {
    \\            status: RequestAdapterStatus = .success,
    \\            device: ?Device = null,
    \\            mutex: std.Thread.Mutex = .{},
    \\        };
    \\
    \\        const callback = struct {
    \\            fn callback(status: RequestDeviceStatus, device: Device, message: [*:0]const u8, user_data: *CallbackResult) callconv(.c) void {
    \\                _ = message;
    \\                user_data.status = status;
    \\                user_data.device = device;
    \\                user_data.mutex.unlock();
    \\            }
    \\        }.callback;
    \\
    \\        var user_data: CallbackResult = .{};
    \\        user_data.mutex.lock();
    \\
    \\        _ = self.requestDevice(descriptor, .{
    \\            .callback = @ptrCast(&callback),
    \\            .user_data1 = @ptrCast(&user_data),
    \\        });
    \\
    \\        user_data.mutex.lock();
    \\        defer user_data.mutex.unlock();
    \\
    \\        return user_data.adapter orelse unreachable;
    \\    }
    \\
;

const toplevel_structs: []const u8 =
    \\pub const SurfaceSourceCanvasHTMLSelector = extern struct {
    \\    next: ?*anyopaque = null,
    \\    selector: [*:0]const u8,
    \\};
    \\
;

fn generateConstant(constant: Constant, file: *DynamicWriter) !void {
    var buf: [128]u8 = undefined;

    try writeDocs(constant.doc, file);
    try file.writeAll(bufPrint(&buf, "pub const {s} = {s};\n", .{ constant.name, valueToString(constant.value) }) catch unreachable);
}

fn generateEnum(@"enum": Enum, with_null: []const []const u8, file: *DynamicWriter) !void {
    var buf: [128]u8 = undefined;
    var name_buf: [128]u8 = undefined;

    try writeDocs(@"enum".doc, file);
    try file.writeAll(bufPrint(&buf, "pub const {s} = enum(u32) {{\n", .{convertToCamelCase(&name_buf, @"enum".name, true)}) catch unreachable);

    for (with_null) |s| {
        if (std.mem.eql(u8, s, @"enum".name)) try file.writeAll("    null = 0,\n");
    }

    for (@"enum".entries) |entry| {
        try file.writeAll(bufPrint(&buf, "    {s},\n", .{convertToSnakeCase(&name_buf, entry.name)}) catch unreachable);
    }

    try file.writeAll("};\n\n");
}

fn generateBitflags(bitflags: Bitflags, file: *DynamicWriter) !void {
    var buf: [128]u8 = undefined;
    var name_buf: [128]u8 = undefined;

    try writeDocs(bitflags.doc, file);
    try file.writeAll(bufPrint(&buf, "pub const {s} = packed struct(u64) {{\n", .{convertToCamelCase(&name_buf, bitflags.name, true)}) catch unreachable);

    for (bitflags.entries) |entry| {
        if (std.mem.eql(u8, entry.name, "none")) continue; // `none` bitflags are represented by `.{}`
        try file.writeAll(bufPrint(&buf, "    {s}: bool = false,\n", .{convertToSnakeCase(&name_buf, entry.name)}) catch unreachable);
    }

    if (bitflags.entries.len < 65) {
        try file.writeAll(bufPrint(&buf, "    _reserved: u{} = 0,\n", .{65 - bitflags.entries.len}) catch unreachable);
    }

    try file.writeAll("};\n\n");
}

fn generateStruct(@"struct": Struct, file: *DynamicWriter) !void {
    var buf: [128]u8 = undefined;
    var name_buf: [128]u8 = undefined;
    var type_buf: [128]u8 = undefined;
    var default_buf: [128]u8 = undefined;

    try writeDocs(@"struct".doc, file);
    try file.writeAll(bufPrint(&buf, "pub const {s} = extern struct {{\n", .{convertToCamelCase(&name_buf, @"struct".name, true)}) catch unreachable);

    if (std.mem.eql(u8, @"struct".type, "extensible")) try file.writeAll("    next: ?*const anyopaque = null,\n");

    for (@"struct".members) |member| {
        const member_name = convertToSnakeCase(&name_buf, member.name);
        const member_type = typeToString(&type_buf, member.type);

        if (std.mem.startsWith(u8, member.type, "array<")) {
            try file.writeAll(bufPrint(&buf, "    {s}_size: usize,\n", .{member_name}) catch unreachable);
            try file.writeAll(bufPrint(&buf, "    {s}_ptr: {s},\n", .{ member_name, member_type }) catch unreachable);
        } else {
            if (member.default) |dv| {
                const default_value = switch (dv) {
                    .integer => |v| bufPrint(&default_buf, "{}", .{v}) catch unreachable,
                    .float => |v| bufPrint(&default_buf, "{d}", .{v}) catch unreachable,

                    .string => |v| if (std.mem.startsWith(u8, member.type, "enum."))
                        bufPrint(&default_buf, ".{s}", .{v}) catch unreachable
                    else if (std.mem.startsWith(u8, member.type, "bitflag."))
                        if (std.mem.eql(u8, v, "none"))
                            ".{}"
                        else
                            bufPrint(&default_buf, ".{{ .{s} = true }}", .{v}) catch unreachable
                    else if (std.mem.startsWith(u8, member.type, "struct."))
                        if (std.mem.eql(u8, v, "zero"))
                            ".{}" // bufPrint(&default_buf, "std.mem.zeroes({s})", .{member_type}) catch unreachable
                        else
                            bufPrint(&default_buf, ".{{ .{s} = true }}", .{v}) catch unreachable
                    else if (std.mem.startsWith(u8, v, "constant."))
                        convertToSnakeCase(&default_buf, v[9..])
                    else if (std.mem.startsWith(u8, v, "0x"))
                        v
                    else
                        bufPrint(&default_buf, "\"{s}\"", .{v}) catch unreachable,

                    .bool => |v| if (v) "TRUE" else "FALSE",
                    else => std.debug.panic("default value is not supported: {}", .{dv}),
                };

                try file.writeAll(bufPrint(&buf, "    {s}: {s} = {s},\n", .{ member_name, member_type, default_value }) catch unreachable);
            } else {
                if (member.optional) |_| {
                    if (std.mem.startsWith(u8, member.type, "object.")) {
                        try file.writeAll(bufPrint(&buf, "    {s}: ?{s} = null,\n", .{ member_name, member_type }) catch unreachable);
                    } else if (std.mem.startsWith(u8, member.type, "struct.")) {
                        try file.writeAll(bufPrint(&buf, "    {s}: {s} = .{{}},\n", .{ member_name, member_type }) catch unreachable);
                    } else {
                        unreachable;
                    }
                } else {
                    try file.writeAll(bufPrint(&buf, "    {s}: {s},\n", .{ member_name, member_type }) catch unreachable);
                }
            }
        }
    }

    try file.writeAll("};\n\n");
}

fn generateObject(object: Object, file: *DynamicWriter) !void {
    var buf: [128]u8 = undefined;
    var name_buf: [128]u8 = undefined;
    var fn_buf: [128]u8 = undefined;
    var arg_buf: [128]u8 = undefined;

    try writeDocs(object.doc, file);
    try file.writeAll(bufPrint(&buf, "pub const {s} = *const opaque {{\n", .{convertToCamelCase(&name_buf, object.name, true)}) catch unreachable);

    for (object.methods) |method| {
        try writeDocs(method.doc, file);
        try file.writeAll(bufPrint(&buf, "    pub fn {s}(", .{convertToCamelCase(&fn_buf, method.name, false)}) catch unreachable);

        var index: usize = 0;

        try file.writeAll(argToString(&arg_buf, Arg{
            .name = "self",
            .doc = "",
            .type = bufPrint(&name_buf, "object.{s}", .{object.name}) catch unreachable,
        }));

        if (method.args.len > 0) try file.writeAll(", ");

        for (method.args) |arg| {
            try file.writeAll(argToString(&arg_buf, arg));

            if (index < method.args.len - 1)
                try file.writeAll(", ");

            index += 1;
        }

        if (method.callback) |callback| {
            try file.writeAll(bufPrint(&buf, ", callback: {s}CallbackInfo", .{convertToCamelCase(&name_buf, callback[9..], true)}) catch unreachable);
        }

        try file.writeAll(") ");

        if (method.returns) |ret| {
            const arg_type = typeToString(&arg_buf, ret.type);

            if (ret.optional) |_| {
                try file.writeAll("?");
            }

            try file.writeAll(arg_type);
        } else if (method.callback) |_| {
            try file.writeAll("Future");
        } else {
            try file.writeAll("void");
        }

        try file.writeAll(" {\n");

        if (method.returns) |_|
            try file.writeAll("        return ")
        else if (method.callback) |_|
            try file.writeAll("        return ")
        else
            try file.writeAll("        ");

        try file.writeAll(bufPrint(&buf, "c.wgpu{s}{s}(", .{ convertToCamelCase(&name_buf, object.name, true), convertToCamelCase(&fn_buf, method.name, true) }) catch unreachable);

        index = 0;

        try file.writeAll("self");

        if (method.args.len > 0) try file.writeAll(", ");

        for (method.args) |arg| {
            try file.writeAll(convertToSnakeCase(&name_buf, arg.name orelse unreachable));

            if (index < method.args.len - 1)
                try file.writeAll(", ");

            index += 1;
        }

        if (method.callback) |_| {
            try file.writeAll(", callback");
        }

        try file.writeAll(");\n    }\n");
    }

    if (std.mem.eql(u8, object.name, "instance"))
        try file.writeAll(instance_methods)
    else if (std.mem.eql(u8, object.name, "adapter"))
        try file.writeAll(adapter_methods);

    try file.writeAll("};\n\n");
}

fn generateCallback(callback: Callback, file: *DynamicWriter) !void {
    var buf: [512]u8 = undefined;
    var name_buf: [128]u8 = undefined;
    var arg_buf: [128]u8 = undefined;

    const name = convertToCamelCase(&name_buf, callback.name, true);

    try file.writeAll(bufPrint(&buf,
        \\pub const {s}CallbackInfo = extern struct {{
        \\    next: ?*anyopaque = null,
        \\    mode: CallbackMode = .null,
        \\    callback: {s}Callback,
        \\    user_data1: ?*anyopaque = null,
        \\    user_data2: ?*anyopaque = null,
        \\}};
        \\
    , .{ name, name }) catch unreachable);

    try writeDocs(callback.doc, file);
    try file.writeAll(bufPrint(&buf, "pub const {s}Callback = *const fn (", .{name}) catch unreachable);

    var index: usize = 0;

    for (callback.args) |arg| {
        try file.writeAll(argToString(&arg_buf, arg));

        if (index < callback.args.len)
            try file.writeAll(", ");

        index += 1;
    }

    try file.writeAll("user_data: ?*anyopaque");

    try file.writeAll(bufPrint(&buf, ") callconv(.c) void;\n", .{}) catch unreachable);
}

fn generateFunction(function: Function, file: *DynamicWriter) !void {
    var buf: [128]u8 = undefined;
    var name_buf: [128]u8 = undefined;
    var fn_buf: [128]u8 = undefined;
    var arg_buf: [128]u8 = undefined;

    try writeDocs(function.doc, file);
    try file.writeAll(bufPrint(&buf, "pub fn {s}(", .{convertToCamelCase(&fn_buf, function.name, false)}) catch unreachable);

    var index: usize = 0;

    for (function.args) |arg| {
        try file.writeAll(argToString(&arg_buf, arg));

        if (index < function.args.len - 1)
            try file.writeAll(", ");

        index += 1;
    }

    try file.writeAll(") ");

    if (function.returns) |ret| {
        const arg_type = typeToString(&arg_buf, ret.type);

        try file.writeAll(arg_type);
    } else {
        try file.writeAll("void");
    }

    try file.writeAll(" {\n");

    if (function.returns) |_|
        try file.writeAll("    return ")
    else
        try file.writeAll("    ");

    try file.writeAll(bufPrint(&buf, "c.wgpu{s}(", .{convertToCamelCase(&name_buf, function.name, true)}) catch unreachable);

    index = 0;

    for (function.args) |arg| {
        try file.writeAll(convertToSnakeCase(&name_buf, arg.name orelse unreachable));

        if (index < function.args.len - 1)
            try file.writeAll(", ");

        index += 1;
    }

    try file.writeAll(");\n}\n");
}

fn generateExternFunction(function: Function, file: *DynamicWriter) !void {
    var buf: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;

    try file.writeAll(bufPrint(&buf, "    pub extern fn wgpu{s}(", .{convertToCamelCase(&buf2, function.name, true)}) catch unreachable);

    var index: usize = 0;

    for (function.args) |arg| {
        try file.writeAll(argToString(&buf2, arg));

        if (index < function.args.len - 1)
            try file.writeAll(", ");

        index += 1;
    }

    try file.writeAll(") callconv(.c) ");

    if (function.returns) |ret| {
        const arg_type = typeToString(&buf2, ret.type);

        try file.writeAll(arg_type);
    } else {
        try file.writeAll("void");
    }

    try file.writeAll(";\n");
}

fn writeDocs(doc: []const u8, file: *DynamicWriter) !void {
    if (std.mem.eql(u8, doc, "TODO") or std.mem.eql(u8, doc, "TODO\n")) {
        return;
    }

    var stream = std.io.fixedBufferStream(doc);
    var reader = stream.reader();

    var buf: [256]u8 = undefined;

    while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        try file.writeAll("/// ");
        try file.writeAll(line);
        try file.writeAll("\n");
    }
}

fn argToString(buf: []u8, arg: Arg) []const u8 {
    var line_buf: [128]u8 = undefined;
    var name_buf: [128]u8 = undefined;
    var type_buf: [128]u8 = undefined;

    var stream = std.io.fixedBufferStream(buf);
    var writer = stream.writer();

    const arg_name = convertToSnakeCase(&name_buf, arg.name orelse unreachable);
    const arg_type = typeToString(&type_buf, arg.type);

    writer.writeAll(bufPrint(&line_buf, "{s}: ", .{arg_name}) catch unreachable) catch unreachable;

    if ((arg.optional orelse false) and (std.mem.startsWith(u8, arg.type, "object.") or arg.pointer != null)) {
        // NOTE: some structs and other types can be `optional`.
        writer.writeAll("?") catch unreachable;
    }

    if (arg.pointer) |ptr| {
        if (!std.mem.startsWith(u8, arg.type, "array<") or std.mem.eql(u8, ptr, "immutable")) {
            if (std.mem.eql(u8, ptr, "immutable")) {
                writer.writeAll("*const ") catch unreachable;
            } else if (std.mem.eql(u8, ptr, "mutable")) {
                writer.writeAll("*") catch unreachable;
            }
        } else {
            std.debug.panic("array with mutable pointer", .{});
        }
    }

    writer.writeAll(bufPrint(&line_buf, "{s}", .{arg_type}) catch unreachable) catch unreachable;

    return buf[0 .. stream.getPos() catch 0];
}

fn valueToString(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "uint32_max")) {
        return "std.math.maxInt(u32)";
    } else if (std.mem.eql(u8, value, "uint64_max")) {
        return "std.math.maxInt(u64)";
    } else if (std.mem.eql(u8, value, "usize_max")) {
        return "std.math.maxInt(usize)";
    } else if (std.mem.eql(u8, value, "nan")) {
        return "std.math.nan(f32)";
    } else {
        std.debug.panic("Invalid value '{s}'", .{value});
    }
}

fn typeToString(buf: []u8, ty: []const u8) []const u8 {
    if (std.mem.startsWith(u8, ty, "enum.")) {
        return convertToCamelCase(buf, ty[5..], true);
    } else if (std.mem.startsWith(u8, ty, "bitflag.")) {
        return convertToCamelCase(buf, ty[8..], true);
    } else if (std.mem.startsWith(u8, ty, "object.")) {
        return convertToCamelCase(buf, ty[7..], true);
    } else if (std.mem.startsWith(u8, ty, "struct.")) {
        return convertToCamelCase(buf, ty[7..], true); // FIXME
    } else if (std.mem.startsWith(u8, ty, "callback.")) {
        const v = convertToCamelCase(buf, ty[9..], true);
        @memcpy(buf[v.len .. v.len + 8], "Callback");

        return buf[0 .. v.len + 8];
    } else if (std.mem.startsWith(u8, ty, "array<")) {
        const inner = ty[6 .. ty.len - 1];

        @memcpy(buf[0..9], "[*]const ");
        const v = typeToString(buf[9..], inner);
        return buf[0 .. v.len + 9];
    } else if (std.mem.eql(u8, ty, "out_string")) {
        return "[*:0]const u8"; // FIXME
    } else if (std.mem.eql(u8, ty, "string_with_default_empty")) {
        return "[*:0]const u8"; // FIXME
    } else if (std.mem.eql(u8, ty, "nullable_string")) {
        return "?[*:0]const u8"; // FIXME
    } else if (std.mem.eql(u8, ty, "float32") or std.mem.eql(u8, ty, "nullable_float32")) {
        return bufPrint(buf, "f32", .{}) catch unreachable;
    } else if (std.mem.eql(u8, ty, "float64_supertype")) {
        return bufPrint(buf, "f64", .{}) catch unreachable;
    } else if (std.mem.eql(u8, ty, "int32")) {
        return bufPrint(buf, "i32", .{}) catch unreachable;
    } else if (std.mem.eql(u8, ty, "uint16")) {
        return bufPrint(buf, "u16", .{}) catch unreachable;
    } else if (std.mem.eql(u8, ty, "uint32")) {
        return bufPrint(buf, "u32", .{}) catch unreachable;
    } else if (std.mem.eql(u8, ty, "uint64")) {
        return bufPrint(buf, "u64", .{}) catch unreachable;
    } else if (std.mem.eql(u8, ty, "usize")) {
        return bufPrint(buf, "usize", .{}) catch unreachable;
    } else if (std.mem.eql(u8, ty, "bool")) {
        return bufPrint(buf, "Bool", .{}) catch unreachable;
    } else if (std.mem.eql(u8, ty, "c_void")) {
        return bufPrint(buf, "*anyopaque", .{}) catch unreachable;
    } else {
        std.debug.panic("cannot convert type {s}\n", .{ty});
    }
}

fn convertToSnakeCase(buf: []u8, str: []const u8) []const u8 {
    var index: usize = 0;
    var length: usize = 0;

    var prev_prevent_conversion: bool = false;

    while (index < str.len) : (index += 1) {
        if (std.ascii.isUpper(str[index])) {
            if (index > 0 and !prev_prevent_conversion) {
                buf[length] = '_';
                length += 1;
            }
            buf[length] = std.ascii.toLower(str[index]);
            length += 1;
        } else {
            buf[length] = str[index];
            length += 1;
        }

        prev_prevent_conversion = str[index] == '_' or std.ascii.isUpper(str[index]) or std.ascii.isDigit(str[index]);
    }

    if (std.mem.eql(u8, buf[0..length], "opaque")) {
        return "@\"opaque\"";
    } else if (std.mem.eql(u8, buf[0..length], "error")) {
        return "@\"error\"";
    } else if (std.ascii.isDigit(buf[0])) {
        std.mem.copyBackwards(u8, buf[2 .. length + 2], buf[0..length]);
        buf[0] = '@';
        buf[1] = '"';
        buf[length + 2] = '"';
        length += 3;
    }

    return buf[0..length];
}

fn convertToCamelCase(buf: []u8, str: []const u8, upper: bool) []const u8 {
    var index: usize = 0;
    var length: usize = 0;

    while (index < str.len) : (index += 1) {
        if (upper and index == 0) {
            buf[length] = std.ascii.toUpper(str[index]);
            length += 1;
        } else if (str[index] == '_') {
            index += 1;
            buf[length] = std.ascii.toUpper(str[index]);
            length += 1;
        } else {
            buf[length] = str[index];
            length += 1;
        }
    }

    return buf[0..length];
}

const WebGPU = struct {
    copyright: []const u8,
    name: []const u8,
    enum_prefix: usize,
    doc: []const u8,

    constants: []const Constant,
    typedefs: []const struct { _reserved: u32 },
    enums: []const Enum,
    bitflags: []const Bitflags,
    structs: []const Struct,
    callbacks: []const Callback,
    functions: []const Function,
    objects: []const Object,
};

const Enum = struct {
    name: []const u8,
    doc: []const u8,
    entries: []const struct {
        name: []const u8,
        doc: []const u8,
    },
};

const Bitflags = struct {
    name: []const u8,
    doc: []const u8,
    entries: []const struct {
        name: []const u8,
        doc: []const u8,
        value_combination: ?[]const []const u8 = null,
    },
};

const Struct = struct {
    name: []const u8,
    doc: []const u8,
    type: []const u8,
    free_members: ?bool = null,
    extends: ?[]const []const u8 = null,
    members: []const Member,
};

const Callback = struct {
    name: []const u8,
    doc: []const u8,
    style: []const u8,
    args: []const Arg,
};

const Constant = struct {
    name: []const u8,
    value: []const u8,
    doc: []const u8,
};

const Function = struct {
    name: []const u8,
    doc: []const u8,
    returns: ?Arg = null,
    args: []const Arg,
};

const Object = struct {
    name: []const u8,
    doc: []const u8,
    methods: []const struct {
        name: []const u8,
        doc: []const u8,
        callback: ?[]const u8 = null,
        returns: ?Arg = null,
        args: []const Arg = &.{},
    },
};

const Member = struct {
    name: []const u8,
    doc: []const u8,
    type: []const u8,
    default: ?std.json.Value = null,
    pointer: ?[]const u8 = null,
    optional: ?bool = null,
    passed_with_ownership: ?bool = null,
};

const Arg = struct {
    name: ?[]const u8 = null,
    doc: []const u8,
    type: []const u8,
    pointer: ?[]const u8 = null,
    optional: ?bool = null,
    passed_with_ownership: ?bool = null,
};

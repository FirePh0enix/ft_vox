const std = @import("std");
const builtin = @import("builtin");
const sdl = if (builtin.os.tag != .emscripten) @import("sdl") else void;

const Self = @This();
const Driver = @import("Renderer.zig").Driver;
const Allocator = std.mem.Allocator;

const Impl = if (builtin.os.tag != .emscripten) @import("SDLWindow.zig") else @import("EmWindow.zig");

impl: Impl,

pub const Options = struct {
    title: [:0]const u8,
    width: ?usize = null,
    height: ?usize = null,
    driver: Driver,
    resizable: bool = false,
    allocator: Allocator,
};

pub const State = enum {
    down,
    up,
};

pub const Event = union(enum) {
    key: struct {
        state: State,
        key: u32,
        repeat: bool,
    },
    button: struct {
        button: u32,
    },
    motion: struct {
        x_relative: f32,
        y_relative: f32,
    },
    unknown: void,
};

pub fn create(options: Options) !Self {
    return .{ .impl = try Impl.create(options) };
}

pub fn deinit(self: *const Self) void {
    self.impl.deinit();
}

pub fn size(self: *const Self) struct { width: usize, height: usize } {
    const s = self.impl.size();
    return .{ .width = s.width, .height = s.height };
}

pub fn pollEvent(self: *const Self) ?Event {
    return self.impl.pollEvent();
}

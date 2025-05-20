const std = @import("std");
const builtin = @import("builtin");

const Self = @This();
const Driver = @import("render/Renderer.zig").Driver;
const Allocator = std.mem.Allocator;

const Impl = @import("window/SDLWindow.zig");

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
        state: State,
    },
    motion: struct {
        x_relative: f32,
        y_relative: f32,
    },
    resized: struct {
        width: usize,
        height: usize,
    },
    close: void,
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

pub fn close(self: *Self) void {
    self.impl.close();
}

pub fn running(self: *const Self) bool {
    return self.impl.running();
}

pub fn setFullscreen(self: *Self, f: bool) void {
    self.impl.setFullscreen(f);
}

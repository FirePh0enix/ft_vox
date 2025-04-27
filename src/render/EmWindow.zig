const std = @import("std");
const em = @import("em");

const Self = @This();
const Window = @import("Window.zig");
const Event = Window.Event;
const Options = Window.Options;
const Allocator = std.mem.Allocator;

const UserData = struct {
    allocator: Allocator,
    events: std.ArrayListUnmanaged(Event),
};

var global_data: UserData = undefined;

pub fn create(options: Options) !Self {
    global_data = .{ .allocator = options.allocator, .events = .empty };

    _ = em.emscripten_set_keydown_callback("#canvas", @as(*anyopaque, @ptrCast(&global_data)), false, @as(em.em_key_callback_func, @ptrCast(&keydownCallback)));
    _ = em.emscripten_set_keyup_callback("#canvas", @as(*anyopaque, @ptrCast(&global_data)), false, @as(em.em_key_callback_func, @ptrCast(&keyupCallback)));

    return .{};
}

fn keydownCallback(event_type: c_int, key_event: *em.EmscriptenKeyboardEvent, user_data: *UserData) callconv(.c) bool {
    _ = event_type;

    user_data.events.append(user_data.allocator, .{
        .key = .{ .key = key_event.keyCode, .state = .down, .repeat = key_event.repeat },
    }) catch {};

    return true;
}

fn keyupCallback(event_type: c_int, key_event: *em.EmscriptenKeyboardEvent, user_data: *UserData) callconv(.c) bool {
    _ = event_type;

    user_data.events.append(user_data.allocator, .{
        .key = .{ .key = key_event.keyCode, .state = .up, .repeat = key_event.repeat },
    }) catch {};

    return true;
}

pub fn deinit(self: *const Self) void {
    _ = self;
    global_data.events.deinit(global_data.allocator);
}

pub fn size(self: *const Self) struct { width: usize, height: usize } {
    _ = self;

    var width: c_int = undefined;
    var height: c_int = undefined;
    var is_fullscreen: c_int = undefined;

    em.emscripten_get_canvas_size(&width, &height, &is_fullscreen);

    return .{
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

pub fn pollEvent(self: *const Self) ?Event {
    _ = self;
    return global_data.events.pop();
}

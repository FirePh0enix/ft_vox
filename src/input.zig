const std = @import("std");
const c = @import("c");
const zm = @import("zmath");

const Vec = zm.Vec;
const Camera = @import("Camera.zig");
const Window = @import("Window.zig");
const World = @import("voxel/World.zig");

const rdr = @import("render/Renderer.zig").rdr;

pub const Action = enum {
    // Mouvements
    forward,
    backward,
    left,
    right,
    up,
    down,

    sprint,

    // Interactions
    attack,
};

pub const Status = struct {
    value: f32 = 0.0,
    just_pressed: bool = false,
};

pub const mouse_left_button: u8 = 1;
pub const mouse_middle_button: u8 = 2;
pub const mouse_right_button: u8 = 3;

pub var mouse_sensibility: f32 = 0.01;

var actions: std.EnumArray(Action, Status) = .initFill(.{});
var window: *Window = undefined;
var camera: *Camera = undefined;
var mouse_grabbed: bool = false;
var fullscreen: bool = false;

pub fn init(_window: *Window, _camera: *Camera) void {
    window = _window;
    camera = _camera;
}

pub fn isActionPressed(action: Action) bool {
    return actions.get(action).value > 0.0;
}

pub fn isActionJustPressed(action: Action) bool {
    const status = actions.get(action);
    return status.value > 0.0 and status.just_pressed;
}

pub fn getActionValue(action: Action) f32 {
    return actions.get(action).value;
}

fn setAction(action: Action, value: f32) void {
    var status = actions.get(action);

    status.just_pressed = status.value == 0.0 or value == 0.0;
    status.value = value;

    actions.set(action, status);
}

pub fn getMovementVector() Vec {
    // Each time: +Axis - -Axis
    const vec: zm.Vec = .{
        getActionValue(.right) - getActionValue(.left),
        getActionValue(.up) - getActionValue(.down),
        getActionValue(.forward) - getActionValue(.backward),
        0.0,
    };

    if (zm.approxEqAbs(vec, zm.f32x4s(0.0), 0.0001))
        return zm.f32x4s(0.0);
    return zm.normalize3(vec);
}

pub fn setMouseGrab(value: bool) void {
    mouse_grabbed = value;
    _ = c.SDL_SetWindowRelativeMouseMode(window.impl.handle, value);
}

pub fn isMouseGrabbed() bool {
    return mouse_grabbed;
}

pub fn pollEvents() void {
    while (window.pollEvent()) |event| {
        switch (event) {
            .close => {
                window.close();
            },
            .resized => |r| {
                try rdr().configure(.{ .width = r.width, .height = r.height, .vsync = .performance });
            },

            .key => |k| {
                switch (k.state) {
                    .down => switch (k.key) {
                        c.SDLK_F => {
                            _ = c.SDL_SetWindowFullscreen(window.impl.handle, !fullscreen);
                            fullscreen = !fullscreen;

                            const size = window.size();

                            try rdr().configure(.{ .width = size.width, .height = size.height, .vsync = .performance });
                        },

                        c.SDLK_ESCAPE => setMouseGrab(false),

                        c.SDLK_W => setAction(.forward, 1.0),
                        c.SDLK_S => setAction(.backward, 1.0),
                        c.SDLK_A => setAction(.left, 1.0),
                        c.SDLK_D => setAction(.right, 1.0),
                        c.SDLK_SPACE => setAction(.up, 1.0),
                        c.SDLK_LCTRL => setAction(.down, 1.0),
                        c.SDLK_LSHIFT => setAction(.sprint, 1.0),

                        else => {},
                    },

                    .up => switch (event.key.key) {
                        c.SDLK_W => setAction(.forward, 0.0),
                        c.SDLK_S => setAction(.backward, 0.0),
                        c.SDLK_A => setAction(.left, 0.0),
                        c.SDLK_D => setAction(.right, 0.0),
                        c.SDLK_SPACE => setAction(.up, 0.0),
                        c.SDLK_LCTRL => setAction(.down, 0.0),
                        c.SDLK_LSHIFT => setAction(.sprint, 0.0),

                        else => {},
                    },
                }
            },

            .button => |b| {
                switch (b.state) {
                    .down => {
                        if (isMouseGrabbed()) {
                            if (event.button.button == mouse_left_button) setAction(.attack, 1.0);
                        }

                        setMouseGrab(true);
                    },
                    .up => {
                        if (isMouseGrabbed()) {
                            if (event.button.button == mouse_left_button) setAction(.attack, 0.0);
                        }
                    },
                }
            },

            .motion => |m| {
                if (isMouseGrabbed()) camera.rotate(m.x_relative, m.y_relative);
            },

            else => {},
        }
    }
}

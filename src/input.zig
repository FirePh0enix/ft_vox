const std = @import("std");
const sdl = @import("sdl");
const zm = @import("zmath");

const Vec = zm.Vec;
const Camera = @import("Camera.zig");
const Window = @import("render/Window.zig");

const rdr = @import("render/Renderer.zig").rdr;

pub const Action = enum {
    // Mouvements
    forward,
    backward,
    left,
    right,
    up,
    down,

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
var mouse_grabbed: bool = false;
var fullscreen: bool = false;

pub fn init(_window: *Window) void {
    window = _window;
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
    _ = sdl.SDL_SetWindowRelativeMouseMode(window.handle, value);
}

pub fn isMouseGrabbed() bool {
    return mouse_grabbed;
}

pub fn handleSDLEvent(event: sdl.SDL_Event, camera: *Camera) !void {
    switch (event.type) {
        sdl.SDL_EVENT_KEY_DOWN => {
            switch (event.key.key) {
                sdl.SDLK_F => {
                    _ = sdl.SDL_SetWindowFullscreen(window.handle, !fullscreen);
                    fullscreen = !fullscreen;

                    const size = window.size();

                    try rdr().configure(.{ .width = size.width, .height = size.height, .vsync = .performance });
                },
                sdl.SDLK_ESCAPE => setMouseGrab(false),

                sdl.SDLK_W => setAction(.forward, 1.0),
                sdl.SDLK_S => setAction(.backward, 1.0),
                sdl.SDLK_A => setAction(.left, 1.0),
                sdl.SDLK_D => setAction(.right, 1.0),
                sdl.SDLK_SPACE => setAction(.up, 1.0),
                sdl.SDLK_LCTRL => setAction(.down, 1.0),

                else => {},
            }
        },
        sdl.SDL_EVENT_KEY_UP => {
            switch (event.key.key) {
                sdl.SDLK_W => setAction(.forward, 0.0),
                sdl.SDLK_S => setAction(.backward, 0.0),
                sdl.SDLK_A => setAction(.left, 0.0),
                sdl.SDLK_D => setAction(.right, 0.0),
                sdl.SDLK_SPACE => setAction(.up, 0.0),
                sdl.SDLK_LCTRL => setAction(.down, 0.0),

                else => {},
            }
        },

        sdl.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            if (isMouseGrabbed()) {
                if (event.button.button == mouse_left_button) setAction(.attack, 1.0);
            }

            setMouseGrab(true);
        },
        sdl.SDL_EVENT_MOUSE_BUTTON_UP => {
            if (isMouseGrabbed()) {
                if (event.button.button == mouse_left_button) setAction(.attack, 0.0);
            }
        },

        sdl.SDL_EVENT_MOUSE_MOTION => {
            if (isMouseGrabbed()) camera.rotate(event.motion.xrel, event.motion.yrel);
        },

        else => {},
    }
}

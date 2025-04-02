const std = @import("std");
const sdl = @import("sdl");
const zm = @import("zmath");

const Vec = zm.Vec;
const Camera = @import("Camera.zig");

const rdr = @import("render/Renderer.zig").rdr;

pub const Action = enum {
    forward,
    backward,
    left,
    right,

    up,
    down,
};

pub var mouse_sensibility: f32 = 0.01;

var actions: std.EnumArray(Action, f32) = .initFill(0.0);
var window: *sdl.SDL_Window = undefined;
var mouse_grabbed: bool = false;
var fullscreen: bool = false;

pub fn init(sdl_window: *sdl.SDL_Window) void {
    window = sdl_window;
}

pub fn isActionPressed(action: Action) bool {
    return actions.get(action) > 0.0;
}

pub fn getActionValue(action: Action) f32 {
    return actions.get(action);
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
    _ = sdl.SDL_SetWindowRelativeMouseMode(window, value);
}

pub fn isMouseGrabbed() bool {
    return mouse_grabbed;
}

pub fn handleSDLEvent(event: sdl.SDL_Event, camera: *Camera) !void {
    switch (event.type) {
        sdl.SDL_EVENT_KEY_DOWN => {
            switch (event.key.key) {
                sdl.SDLK_F => {
                    _ = sdl.SDL_SetWindowFullscreen(window, !fullscreen);
                    fullscreen = !fullscreen;
                    try rdr().resize();
                },
                sdl.SDLK_ESCAPE => setMouseGrab(false),

                sdl.SDLK_W => actions.set(.forward, 1.0),
                sdl.SDLK_S => actions.set(.backward, 1.0),
                sdl.SDLK_A => actions.set(.left, 1.0),
                sdl.SDLK_D => actions.set(.right, 1.0),
                sdl.SDLK_SPACE => actions.set(.up, 1.0),
                sdl.SDLK_LCTRL => actions.set(.down, 1.0),

                else => {},
            }
        },
        sdl.SDL_EVENT_KEY_UP => {
            switch (event.key.key) {
                sdl.SDLK_W => actions.set(.forward, 0.0),
                sdl.SDLK_S => actions.set(.backward, 0.0),
                sdl.SDLK_A => actions.set(.left, 0.0),
                sdl.SDLK_D => actions.set(.right, 0.0),
                sdl.SDLK_SPACE => actions.set(.up, 0.0),
                sdl.SDLK_LCTRL => actions.set(.down, 0.0),

                else => {},
            }
        },

        sdl.SDL_EVENT_MOUSE_BUTTON_DOWN => setMouseGrab(true),
        sdl.SDL_EVENT_MOUSE_MOTION => {
            if (isMouseGrabbed()) camera.rotate(event.motion.xrel, event.motion.yrel);
        },

        else => {},
    }
}

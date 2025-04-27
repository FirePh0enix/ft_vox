const std = @import("std");
const wgpu = @import("webgpu");

const pthread_t = std.c.pthread_t;

//
// emscripten/html5.h
//

pub const em_html5_short_string_len_bytes: usize = 32;
pub const em_html5_medium_string_len_bytes: usize = 64;
pub const em_html5_long_string_len_bytes: usize = 128;

pub const EmscriptenKeyboardEvent = extern struct {
    timestamp: f64,
    location: u32,
    ctrl_key: bool,
    shift_key: bool,
    alt_key: bool,
    meta_key: bool,
    repeat: bool,
    char_code: u32,
    key_code: u32,
    which: u32,
    key: [em_html5_short_string_len_bytes]u8,
    code: [em_html5_short_string_len_bytes]u8,
    char_value: [em_html5_short_string_len_bytes]u8,
    locale: [em_html5_short_string_len_bytes]u8,
};

pub const EmKeyCallbackFunc = *const fn (event_type: c_int, key_event: *EmscriptenKeyboardEvent, user_data: ?*anyopaque) callconv(.c) bool;

pub extern fn emscripten_set_keypress_callback_on_thread(target: [*:0]const u8, user_data: ?*anyopaque, use_capture: bool, callback: ?EmKeyCallbackFunc, target_thread: pthread_t) c_int;
pub extern fn emscripten_set_keydown_callback_on_thread(target: [*:0]const u8, user_data: ?*anyopaque, use_capture: bool, callback: ?EmKeyCallbackFunc, target_thread: pthread_t) c_int;
pub extern fn emscripten_set_keyup_callback_on_thread(target: [*:0]const u8, user_data: ?*anyopaque, use_capture: bool, callback: ?EmKeyCallbackFunc, target_thread: pthread_t) c_int;

pub const EmscriptenMouseEvent = extern struct {
    timestamp: f64,
    screen_x: i32,
    screen_y: i32,
    client_x: i32,
    client_y: i32,
    ctrl_key: bool,
    shift_key: bool,
    alt_key: bool,
    meta_key: bool,
    button: u16,
    buttons: u16,
    movement_x: i32,
    movement_y: i32,
    target_x: i32,
    target_y: i32,
    canvas_x: i32,
    canvas_y: i32,
    padding: i32,
};

pub const em_callback_thread_context_main_runtime_thread: pthread_t = @ptrFromInt(0x1);
pub const em_callback_thread_context_context_calling_thread: pthread_t = @ptrFromInt(0x2);

pub fn emscripten_set_keypress_callback(target: [*:0]const u8, user_data: ?*anyopaque, use_capture: bool, callback: ?EmKeyCallbackFunc) c_int {
    return emscripten_set_keypress_callback_on_thread(target, user_data, use_capture, callback, em_callback_thread_context_context_calling_thread);
}

pub fn emscripten_set_keydown_callback(target: [*:0]const u8, user_data: ?*anyopaque, use_capture: bool, callback: ?EmKeyCallbackFunc) c_int {
    return emscripten_set_keydown_callback_on_thread(target, user_data, use_capture, callback, em_callback_thread_context_context_calling_thread);
}

pub fn emscripten_set_keyup_callback(target: [*:0]const u8, user_data: ?*anyopaque, use_capture: bool, callback: ?EmKeyCallbackFunc) c_int {
    return emscripten_set_keyup_callback_on_thread(target, user_data, use_capture, callback, em_callback_thread_context_context_calling_thread);
}

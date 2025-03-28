const std = @import("std");

pub fn clear() void {
    std.debug.print("\x1b[2J", .{});
}

pub fn moveToStart() void {
    std.debug.print("\x1b[H", .{});
}

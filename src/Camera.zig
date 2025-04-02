const std = @import("std");
const zm = @import("zmath");

const Self = @This();
const Vec = zm.Vec;
const Quat = zm.Quat;
const Mat = zm.Mat;

const sin = std.math.sin;
const cos = std.math.cos;
const pi = std.math.pi;

position: Vec = .{ 0.0, 0.0, 0.0, 0.0 },
rotation: Vec = .{ 0.0, 0.0, 0.0, 0.0 },
focus_point: Vec = .{ 0.0, 0.0, -1.0, 0.0 },

pub fn forward(self: *const Self) Vec {
    _ = self;
    return .{ 0.0, 0.0, -1.0, 0.0 };
}

pub fn right(self: *const Self) Vec {
    _ = self;
    return .{ 1.0, 0.0, 0.0, 0.0 };
}

pub fn rotate(self: *Self, x_rel: f32, y_rel: f32) void {
    self.rotate_x(y_rel * 0.01);
    self.rotate_y(x_rel * 0.01);
}

fn rotate_x(self: *Self, value: f32) void {
    self.rotation[1] += value;
    self.rotation[1] = std.math.clamp(self.rotation[1], -pi / 2.0, pi / 2.0);

    self.focus_point[0] = self.position[0] + cos(self.rotation[0]) * sin(self.rotation[1]);
    self.focus_point[1] = self.position[1] + sin(self.rotation[0]) * sin(self.rotation[1]);
    self.focus_point[2] = self.position[2] + cos(self.rotation[1]);
}

fn rotate_y(self: *Self, value: f32) void {
    self.rotation[0] += value;

    self.focus_point[0] = self.position[0] + cos(self.rotation[0]) * sin(self.rotation[1]);
    self.focus_point[1] = self.position[1] + sin(self.rotation[0]) * sin(self.rotation[1]);
    self.focus_point[2] = self.position[2] + cos(self.rotation[1]);

    std.debug.print("{}\n", .{self.focus_point});
}

pub fn calculateViewMatrix(self: *const Self) Mat {
    return zm.lookAtLh(self.position, self.position + self.focus_point, .{ 0.0, 1.0, 0.0, 0.0 });
}

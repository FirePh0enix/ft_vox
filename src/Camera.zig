const std = @import("std");
const zm = @import("zmath");
const input = @import("input.zig");

const Self = @This();
const Vec = zm.Vec;
const Quat = zm.Quat;
const Mat = zm.Mat;
const World = @import("voxel/World.zig");

speed: f32 = 0.15,
speed_mul: f32 = 1.0,
position: Vec = .{ 0.0, 0.0, 0.0, 0.0 },
rotation: Vec = .{ 0.0, 0.0, 0.0, 0.0 },

pub fn forward(self: *const Self) Vec {
    return zm.rotate(zm.conjugate(self.rotationQuat()), .{ 0.0, 0.0, -1.0, 1.0 });
}

pub fn right(self: *const Self) Vec {
    return zm.rotate(zm.conjugate(self.rotationQuat()), .{ 1.0, 0.0, 0.0, 1.0 });
}

pub fn rotate(self: *Self, x_rel: f32, y_rel: f32) void {
    self.rotation[0] += y_rel * input.mouse_sensibility;
    self.rotation[1] += x_rel * input.mouse_sensibility;

    if (self.rotation[0] > std.math.tau) self.rotation[0] -= std.math.tau;
    if (self.rotation[0] < -std.math.tau) self.rotation[0] += std.math.tau;
    if (self.rotation[1] > std.math.tau) self.rotation[1] -= std.math.tau;
    if (self.rotation[1] < -std.math.tau) self.rotation[1] += std.math.tau;
}

pub fn updateCamera(self: *Self, world: *World) void {
    const forward_vec = self.forward();
    const right_vec = self.right();
    const up_vec = zm.f32x4(0.0, 1.0, 0.0, 0.0);

    const dir = input.getMovementVector();
    self.position += forward_vec * @as(zm.Vec, @splat(dir[2] * self.speed * self.speed_mul));
    self.position += up_vec * @as(zm.Vec, @splat(dir[1] * self.speed * self.speed_mul));
    self.position += right_vec * @as(zm.Vec, @splat(dir[0] * self.speed * self.speed_mul));

    const attack_range: f32 = 5.0;

    if (input.isActionJustPressed(.attack)) {
        if (world.raycastBlock(.{ .from = self.position, .to = self.position + self.forward() * zm.f32x4s(attack_range) }, 0.1)) |result| {
            world.setBlockState(result.block.pos.x, result.block.pos.y, result.block.pos.z, .{ .id = 0 });
        }
    }

    if (input.isActionPressed(.sprint)) {
        self.speed_mul = 20.0;
    } else {
        self.speed_mul = 1.0;
    }

    @import("root").the_world.updateWorldAround(self.position[0], self.position[2]) catch unreachable;
}

pub fn getViewMatrix(self: *const Self) Mat {
    const orientation = self.rotationQuat();
    const rotation = zm.matFromQuat(orientation);
    const translate = zm.translationV(-self.position);

    return zm.mul(translate, rotation);
}

pub fn rotationQuat(self: *const Self) Quat {
    const q_pitch = zm.quatFromAxisAngle(.{ 1.0, 0.0, 0.0, 0.0 }, self.rotation[0]);
    const q_yaw = zm.quatFromAxisAngle(.{ 0.0, 1.0, 0.0, 0.0 }, self.rotation[1]);

    return zm.normalize4(zm.qmul(q_yaw, q_pitch));
}

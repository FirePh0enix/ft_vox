const std = @import("std");
const zm = @import("zmath");
const input = @import("input.zig");
const tracy = @import("tracy");

const Self = @This();
const Vec = zm.Vec;
const Quat = zm.Quat;
const Mat = zm.Mat;
const World = @import("voxel/World.zig");
const AABB = @import("AABB.zig");
const Text = @import("Text.zig");
const Font = @import("Font.zig");

position: Vec,
rotation: Vec,

speed: f32 = 0.15,
speed_mul: f32 = 1.0,

projection_matrix: zm.Mat = zm.identity(),

aspect_ratio: f32,

/// Field of View in radians.
fov: f32,

/// Frustum of the camera, this can be used to check if a primitive shape is in view of the camera,
/// and implement Frustum Culling.
frustum: Frustum,

attack_pressed: bool = false,

block_label: Text,

pub const Options = struct {
    position: zm.Vec = zm.f32x4s(0.0),
    rotation: zm.Vec = zm.f32x4s(0.0),
    speed: f32 = 0.15,
    speed_mul: f32 = 1.0,
    aspect_ratio: f32,
    fov: f32 = std.math.degreesToRadians(60.0),
    font: *const Font,
};

pub fn init(options: Options) Self {
    var camera: Self = .{
        .speed = options.speed,
        .speed_mul = options.speed_mul,
        .position = options.position,
        .rotation = options.rotation,
        .fov = options.fov,
        .aspect_ratio = options.aspect_ratio,
        .projection_matrix = calculateProjectionMatrix(options.aspect_ratio, options.fov),
        .frustum = undefined,
        .block_label = Text.initCapacity(options.font, 8) catch unreachable,
    };
    camera.frustum = Frustum.init(camera.getViewProjMatrix());
    return camera;
}

pub fn deinit(self: *Self) void {
    self.block_label.deinit();
}

pub fn setAspectRatio(self: *Self, aspect_ratio: f32) void {
    self.projection_matrix = calculateProjectionMatrix(aspect_ratio, self.fov);
    self.aspect_ratio = aspect_ratio;
}

pub fn setFov(self: *Self, fov: f32) void {
    self.projection_matrix = calculateProjectionMatrix(self.aspect_ratio, fov);
    self.fov = fov;
}

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
    // Update the frustum once per frame.
    self.frustum = Frustum.init(self.getViewProjMatrix());

    const forward_vec = self.forward();
    const right_vec = self.right();
    const up_vec = zm.f32x4(0.0, 1.0, 0.0, 0.0);

    if (input.isActionPressed(.sprint)) {
        self.speed_mul = 20.0;
    } else {
        self.speed_mul = 1.0;
    }

    const dir = input.getMovementVector();
    self.position += forward_vec * zm.f32x4s(dir[2] * self.speed * self.speed_mul);
    self.position += up_vec * zm.f32x4s(dir[1] * self.speed * self.speed_mul);
    self.position += right_vec * zm.f32x4s(dir[0] * self.speed * self.speed_mul);

    world.updateWorldAround(self.position[0], self.position[2]) catch {};
}

pub fn getViewMatrix(self: *const Self) Mat {
    const orientation = self.rotationQuat();
    const rotation = zm.matFromQuat(orientation);
    const translate = zm.translationV(-self.position);

    return zm.mul(translate, rotation);
}

pub fn getViewProjMatrix(self: *const Self) Mat {
    return zm.mul(self.getViewMatrix(), self.projection_matrix);
}

pub fn rotationQuat(self: *const Self) Quat {
    const q_pitch = zm.quatFromAxisAngle(.{ 1.0, 0.0, 0.0, 0.0 }, self.rotation[0]);
    const q_yaw = zm.quatFromAxisAngle(.{ 0.0, 1.0, 0.0, 0.0 }, self.rotation[1]);

    return zm.normalize4(zm.qmul(q_yaw, q_pitch));
}

fn calculateProjectionMatrix(aspect_ratio: f32, fov: f32) zm.Mat {
    var projection_matrix = zm.perspectiveFovRh(fov, aspect_ratio, 0.01, 1000.0);
    projection_matrix[1][1] *= -1;
    return projection_matrix;
}

pub const Frustum = struct {
    // https://github.com/gametutorials/tutorials/blob/master/OpenGL/Frustum%20Culling/Frustum.cpp

    const right = 0;
    const left = 1;
    const bottom = 2;
    const top = 3;
    const back = 4;
    const front = 5;

    const a = 0;
    const b = 1;
    const c = 2;
    const d = 3;

    planes: [6]zm.Vec,

    pub fn init(mat: zm.Mat) Frustum {
        var f: Frustum = .{
            .planes = .{
                // right
                .{
                    mat[0][3] - mat[0][0],
                    mat[1][3] - mat[1][0],
                    mat[2][3] - mat[2][0],
                    mat[3][3] - mat[3][0],
                },
                // left
                .{
                    mat[0][3] + mat[0][0],
                    mat[1][3] + mat[1][0],
                    mat[2][3] + mat[2][0],
                    mat[3][3] + mat[3][0],
                },
                // bottom
                .{
                    mat[0][3] + mat[0][1],
                    mat[1][3] + mat[1][1],
                    mat[2][3] + mat[2][1],
                    mat[3][3] + mat[3][1],
                },
                // top
                .{
                    mat[0][3] - mat[0][1],
                    mat[1][3] - mat[1][1],
                    mat[2][3] - mat[2][1],
                    mat[3][3] - mat[3][1],
                },
                // back
                .{
                    mat[0][3] - mat[0][2],
                    mat[1][3] - mat[1][2],
                    mat[2][3] - mat[2][2],
                    mat[3][3] - mat[3][2],
                },
                // front
                .{
                    mat[0][3] + mat[0][2],
                    mat[1][3] + mat[1][2],
                    mat[2][3] + mat[2][2],
                    mat[3][3] + mat[3][2],
                },
            },
        };

        f.normalizePlane(Frustum.right);
        f.normalizePlane(Frustum.left);
        f.normalizePlane(Frustum.bottom);
        f.normalizePlane(Frustum.top);
        f.normalizePlane(Frustum.back);
        f.normalizePlane(Frustum.front);

        return f;
    }

    fn normalizePlane(self: *Frustum, side: usize) void {
        const magnitude = std.math.sqrt(self.planes[side][a] * self.planes[side][a] +
            self.planes[side][b] * self.planes[side][b] +
            self.planes[side][c] * self.planes[side][c]);

        self.planes[side][a] /= magnitude;
        self.planes[side][b] /= magnitude;
        self.planes[side][c] /= magnitude;
        self.planes[side][d] /= magnitude;
    }

    pub fn containsPoint(self: *const Frustum, point: zm.Vec) bool {
        for (0..6) |i| {
            if (self.planes[i][a] * point[0] + self.planes[i][b] * point[1] + self.planes[i][c] * point[2] + self.planes[i][d]) {
                return false;
            }
        }
        return true;
    }

    pub fn containsBox(self: *const Frustum, aabb: AABB) bool {
        for (0..6) |i| {
            if (self.planes[i][a] * (aabb.center[0] - aabb.half_extent[0]) + self.planes[i][b] * (aabb.center[1] - aabb.half_extent[1]) + self.planes[i][c] * (aabb.center[2] - aabb.half_extent[2]) + self.planes[i][d] > 0)
                continue;
            if (self.planes[i][a] * (aabb.center[0] + aabb.half_extent[0]) + self.planes[i][b] * (aabb.center[1] - aabb.half_extent[1]) + self.planes[i][c] * (aabb.center[2] - aabb.half_extent[2]) + self.planes[i][d] > 0)
                continue;
            if (self.planes[i][a] * (aabb.center[0] - aabb.half_extent[0]) + self.planes[i][b] * (aabb.center[1] + aabb.half_extent[1]) + self.planes[i][c] * (aabb.center[2] - aabb.half_extent[2]) + self.planes[i][d] > 0)
                continue;
            if (self.planes[i][a] * (aabb.center[0] + aabb.half_extent[0]) + self.planes[i][b] * (aabb.center[1] + aabb.half_extent[1]) + self.planes[i][c] * (aabb.center[2] - aabb.half_extent[2]) + self.planes[i][d] > 0)
                continue;
            if (self.planes[i][a] * (aabb.center[0] - aabb.half_extent[0]) + self.planes[i][b] * (aabb.center[1] - aabb.half_extent[1]) + self.planes[i][c] * (aabb.center[2] + aabb.half_extent[2]) + self.planes[i][d] > 0)
                continue;
            if (self.planes[i][a] * (aabb.center[0] + aabb.half_extent[0]) + self.planes[i][b] * (aabb.center[1] - aabb.half_extent[1]) + self.planes[i][c] * (aabb.center[2] + aabb.half_extent[2]) + self.planes[i][d] > 0)
                continue;
            if (self.planes[i][a] * (aabb.center[0] - aabb.half_extent[0]) + self.planes[i][b] * (aabb.center[1] + aabb.half_extent[1]) + self.planes[i][c] * (aabb.center[2] + aabb.half_extent[2]) + self.planes[i][d] > 0)
                continue;
            if (self.planes[i][a] * (aabb.center[0] + aabb.half_extent[0]) + self.planes[i][b] * (aabb.center[1] + aabb.half_extent[1]) + self.planes[i][c] * (aabb.center[2] + aabb.half_extent[2]) + self.planes[i][d] > 0)
                continue;

            return false;
        }

        return true;
    }
};

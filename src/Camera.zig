const std = @import("std");
const zm = @import("zmath");
const input = @import("input.zig");

const Self = @This();
const Vec = zm.Vec;
const Quat = zm.Quat;
const Mat = zm.Mat;
const World = @import("voxel/World.zig");
const AABB = @import("AABB.zig");

speed: f32 = 0.15,
speed_mul: f32 = 1.0,
position: Vec = .{ 0.0, 0.0, 0.0, 0.0 },
rotation: Vec = .{ 0.0, 0.0, 0.0, 0.0 },

projection_matrix: zm.Mat = zm.identity(),

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

    if (input.isActionPressed(.sprint)) {
        self.speed_mul = 20.0;
    } else {
        self.speed_mul = 1.0;
    }

    const dir = input.getMovementVector();
    self.position += forward_vec * @as(zm.Vec, @splat(dir[2] * self.speed * self.speed_mul));
    self.position += up_vec * @as(zm.Vec, @splat(dir[1] * self.speed * self.speed_mul));
    self.position += right_vec * @as(zm.Vec, @splat(dir[0] * self.speed * self.speed_mul));

    const attack_range: f32 = 5.0;

    if (input.isActionJustPressed(.attack)) {
        if (world.castRay(.{ .origin = self.position, .dir = forward_vec }, attack_range, 0.01)) |result| {
            // const block = world.registry.getBlock(result.block.state.id) orelse unreachable;
            const pos = result.block.pos;

            // std.debug.print("{s} {d} {}\n", .{ block.name, result.block.distance, result.block.pos });
            world.setBlockState(pos.x, pos.y, pos.z, .{ .id = 0 });
        }
    }

    world.updateWorldAround(self.position[0], self.position[2]) catch unreachable;
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

pub fn frustum(self: *const Self) Frustum {
    return Frustum.init(self.getViewProjMatrix());
}

const zm = @import("zmath");
const noise = @import("math/noise.zig");

pub const SimplexNoiseWithOptions = noise.SimplexNoiseWithOptions;
pub const SimplexNoise = noise.SimplexNoiseWithOptions(f32);

pub const Ray = struct {
    origin: zm.Vec,
    dir: zm.Vec,

    pub fn at(self: *const Ray, t: f32) zm.Vec {
        return self.origin + self.dir * zm.f32x4(t, t, t, 1.0);
    }
};

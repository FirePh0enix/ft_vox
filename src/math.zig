const zm = @import("zmath");

pub const Ray = struct {
    from: zm.Vec,
    to: zm.Vec,

    pub fn at(self: *const Ray, t: f32) zm.Vec {
        return self.from + self.dir() * zm.f32x4s(t);
    }

    pub fn dir(self: *const Ray) zm.Vec {
        return zm.normalize3(self.to - self.from);
    }

    pub fn length(self: *const Ray) f32 {
        return zm.length3(self.to - self.from)[0];
    }
};

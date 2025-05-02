//! Primitive representing an Axis Aligned Bounding Box

const zm = @import("zmath");

const Self = @This();

center: zm.Vec,
half_extent: zm.Vec,

pub fn bounds(self: *const Self) [8]zm.Vec {
    return .{
        // top
        self.center + zm.Vec{ -self.half_extent[0], self.half_extent[1], self.half_extent[2], 0 },
        self.center + zm.Vec{ self.half_extent[0], self.half_extent[1], self.half_extent[2], 0 },
        self.center + zm.Vec{ -self.half_extent[0], self.half_extent[1], -self.half_extent[2], 0 },
        self.center + zm.Vec{ self.half_extent[0], self.half_extent[1], -self.half_extent[2], 0 },

        // bottom
        self.center + zm.Vec{ -self.half_extent[0], -self.half_extent[1], self.half_extent[2], 0 },
        self.center + zm.Vec{ self.half_extent[0], -self.half_extent[1], self.half_extent[2], 0 },
        self.center + zm.Vec{ -self.half_extent[0], -self.half_extent[1], -self.half_extent[2], 0 },
        self.center + zm.Vec{ self.half_extent[0], -self.half_extent[1], -self.half_extent[2], 0 },
    };
}

pub fn minMax(self: *const Self) [2]zm.Vec {
    return .{ self.center - self.half_extent, self.center + self.half_extent };
}

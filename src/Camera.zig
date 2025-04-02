const std = @import("std");
const zm = @import("zmath");

const Self = @This();

position: zm.Vec = .{ 0.0, 0.0, 2.0, 1.0 },
rotation: zm.Vec = .{ 0.0, 0.0, 0.0, 1.0 },
forward: zm.Vec = .{ 0.0, 0.0, -1.0, 0.0 },

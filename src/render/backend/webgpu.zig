const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const gl = @import("zgl");
const assets = @import("../../assets.zig");

const Allocator = std.mem.Allocator;
const Window = @import("../../Window.zig");
const Renderer = @import("../Renderer.zig");
const RID = Renderer.RID;
const Graph = @import("../Graph.zig");

const createWithInit = Renderer.createWithInit;

pub const WGPURenderer = struct {};

const std = @import("std");
const zm = @import("zmath");

const Self = @This();
const RenderFrame = @import("../render/RenderFrame.zig");
const Buffer = @import("../render/Buffer.zig");
const Allocator = std.mem.Allocator;
const BlockInstanceData = RenderFrame.BlockInstanceData;
const Registry = @import("Registry.zig");
const Chunk = @import("Chunk.zig");

allocator: Allocator,

seed: u64,

/// Chunks loaded in memory that are updated and rendered to the player.
chunks: std.ArrayListUnmanaged(Chunk) = .empty,

pub fn deinit(self: *Self) void {
    self.chunks.deinit(self.allocator);
}

pub const Direction = enum(u3) {
    north = 0,
    south = 1,
    west = 2,
    east = 3,
    top = 4,
    down = 5,
};

pub const BlockState = packed struct(u32) {
    id: u16 = 0,

    visibility: u6 = ~@as(u6, 0),
    direction: Direction = .north,

    _padding: u7 = 0,
};

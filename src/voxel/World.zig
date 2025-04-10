const std = @import("std");
const zm = @import("zmath");

const Self = @This();
const RenderFrame = @import("../voxel/RenderFrame.zig");
const Buffer = @import("../render/Buffer.zig");
const Allocator = std.mem.Allocator;
const BlockInstanceData = RenderFrame.BlockInstanceData;
const Registry = @import("Registry.zig");
const Chunk = @import("Chunk.zig");
const Ray = @import("../math.zig").Ray;

const world_directory: []const u8 = "user_data/worlds";

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

pub const BlockPos = struct {
    x: i64,
    y: i64,
    z: i64,
};

pub const RaycastResult = union(enum) {
    block: struct {
        state: BlockState,
        pos: BlockPos,
    },
};

pub const ChunkPos = struct {
    x: i64,
    z: i64,
};

allocator: Allocator,

seed: u64,

/// Chunks loaded in memory that are updated and rendered to the player.
chunks: std.AutoHashMapUnmanaged(ChunkPos, Chunk) = .empty,

pub fn deinit(self: *Self) void {
    self.chunks.deinit(self.allocator);
}

pub fn getChunk(self: *const Self, x: i64, z: i64) ?*Chunk {
    return self.chunks.getPtr(.{ .x = x, .z = z });
}

pub fn getBlockState(self: *const Self, x: i64, y: i64, z: i64) ?BlockState {
    const chunk_x = @divFloor(x, 16);
    const chunk_z = @divFloor(z, 16);

    if (self.getChunk(chunk_x, chunk_z)) |chunk| {
        const local_x: usize = @intCast(@mod(x, 16));
        const local_z: usize = @intCast(@mod(x, 16));

        return chunk.getBlockState(local_x, @intCast(y), local_z);
    }

    return null;
}

pub fn setBlockState(self: *const Self, x: i64, y: i64, z: i64, state: BlockState) void {
    const chunk_x = @divFloor(x, 16);
    const chunk_z = @divFloor(z, 16);

    if (self.getChunk(chunk_x, chunk_z)) |chunk| {
        const local_x: usize = @intCast(@mod(x, 16));
        const local_z: usize = @intCast(@mod(x, 16));

        chunk.setBlockState(local_x, @intCast(y), local_z, state);
    }
}

pub fn raycastBlock(self: *const Self, ray: Ray, precision: f32) ?RaycastResult {
    const length = ray.length();
    var t: f32 = 0.0;

    while (t < length) : (t += precision) {
        const point = ray.at(t);

        const block_x: i64 = @intFromFloat(point[0]);
        const block_y: i64 = @intFromFloat(point[1]);
        const block_z: i64 = @intFromFloat(point[2]);

        if (self.getBlockState(block_x, block_y, block_z)) |state| {
            return RaycastResult{
                .block = .{
                    .state = state,
                    .pos = .{
                        .x = block_x,
                        .y = block_y,
                        .z = block_z,
                    },
                },
            };
        }
    }

    return null;
}

pub fn save(self: *const Self, name: []const u8) !void {
    var worlds_dir = std.fs.cwd().openDir(world_directory, .{}) catch a: {
        try std.fs.cwd().makePath(world_directory);
        break :a try std.fs.cwd().openDir(world_directory, .{});
    };
    defer worlds_dir.close();

    var buf: [128]u8 = undefined;

    try worlds_dir.makePath(name);
    const chunks_path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ name, "chunks" });

    try worlds_dir.makePath(chunks_path);

    const dir = try worlds_dir.openDir(chunks_path, .{});

    var chunks_iter = self.chunks.iterator();
    while (chunks_iter.next()) |entry| {
        try saveChunk(entry.key_ptr.x, entry.key_ptr.z, entry.value_ptr, dir);
    }
}

fn saveChunk(x: i64, z: i64, chunk: *const Chunk, chunks_dir: std.fs.Dir) !void {
    var buf: [128]u8 = undefined;
    const file = try chunks_dir.createFile(try std.fmt.bufPrint(&buf, "{}${}.chunkdata", .{ x, z }), .{});

    var blocks: [Chunk.length * Chunk.height * Chunk.length]u16 = undefined;

    for (0..Chunk.length) |bx| {
        for (0..Chunk.height) |by| {
            for (0..Chunk.length) |bz| {
                blocks[bz * Chunk.length * Chunk.height + by * Chunk.length + bx] = (chunk.getBlockState(bx, by, bz) orelse BlockState{}).id;
            }
        }
    }

    try file.writeAll(std.mem.sliceAsBytes(blocks[0..]));
}

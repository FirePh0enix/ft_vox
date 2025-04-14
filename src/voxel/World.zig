const std = @import("std");
const zm = @import("zmath");
const world_gen = @import("../world_gen.zig");

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

pub const GenerationSettings = struct {
    seed: ?u64 = null,
    sea_level: usize = 50,
};

allocator: Allocator,

seed: u64,
generation_settings: GenerationSettings,

/// Chunks loaded in memory that are updated and rendered to the player.
chunks: std.AutoHashMapUnmanaged(ChunkPos, Chunk) = .empty,
chunks_lock: std.Thread.Mutex = .{},

chunk_worker_state: std.atomic.Value(bool) = .init(false),
chunk_load_worker: ChunkLoadWorker = .{},

pub fn initEmpty(
    allocator: Allocator,
    seed: u64,
    settings: GenerationSettings,
) Self {
    return .{
        .allocator = allocator,
        .seed = seed,
        .generation_settings = settings,
    };
}

pub fn startWorkers(self: *Self, registry: *const Registry) !void {
    self.chunk_worker_state.store(true, .release);
    self.chunk_load_worker.thread = try std.Thread.spawn(.{}, ChunkLoadWorker.worker, .{ &self.chunk_load_worker, self, registry });
}

pub fn deinit(self: *Self) void {
    self.chunk_worker_state.store(false, .release);

    if (self.chunk_load_worker.thread) |thread| {
        self.chunk_load_worker.sleep_semaphore.post();
        thread.join();
        self.chunk_load_worker.orders.deinit(self.allocator);
    }

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

/// Load a chunk on a separate thread.
pub fn loadChunk(self: *Self, pos: ChunkPos) !void {
    self.chunk_load_worker.orders_mutex.lock();
    defer self.chunk_load_worker.orders_mutex.unlock();

    try self.chunk_load_worker.orders.append(self.allocator, pos);
    self.chunk_load_worker.sleep_semaphore.post();
}

const ChunkLoadWorker = struct {
    thread: ?std.Thread = null,
    sleep_semaphore: std.Thread.Semaphore = .{},
    orders_mutex: std.Thread.Mutex = .{},
    orders: std.ArrayListUnmanaged(ChunkPos) = .empty,

    fn worker(self: *ChunkLoadWorker, world: *Self, registry: *const Registry) void {
        var remaining: usize = 0;

        while (world.chunk_worker_state.load(.acquire)) {
            if (remaining == 0) self.sleep_semaphore.wait();

            self.orders_mutex.lock();
            const chunk_pos = self.orders.pop();
            remaining = self.orders.items.len;
            self.orders_mutex.unlock();

            if (chunk_pos) |pos| {
                // TODO: How should chunk generation/load errors should be threated ?
                var chunk = world_gen.generateChunk(world.generation_settings, @intCast(pos.x), @intCast(pos.z)) catch unreachable;
                chunk.computeVisibility(null, null, null, null);
                chunk.rebuildInstanceBuffer(registry) catch unreachable;

                world.chunks_lock.lock();
                defer world.chunks_lock.unlock();

                world.chunks.put(world.allocator, pos, chunk) catch unreachable;
            }
        }
    }
};

pub const ConfigZon = struct {
    seed: u64,
};

pub fn save(self: *const Self, name: []const u8) !void {
    var worlds_dir = std.fs.cwd().openDir(world_directory, .{}) catch a: {
        try std.fs.cwd().makePath(world_directory);
        break :a try std.fs.cwd().openDir(world_directory, .{});
    };
    defer worlds_dir.close();

    var buf: [128]u8 = undefined;

    try worlds_dir.makePath(name);
    const world_path = try worlds_dir.openDir(name, .{});

    // Save the world config
    const config: ConfigZon = .{
        .seed = self.seed,
    };

    const config_file = try world_path.createFile("config.zon", .{});
    try std.zon.stringify.serialize(config, .{}, config_file.writer());

    // Save each chunks
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

    var blocks: [Chunk.length * Chunk.height * Chunk.length]struct { local_pos: Chunk.LocalPos, block_id: u16 } = undefined;
    var block_count: usize = 0;

    for (0..Chunk.length) |bx| {
        for (0..Chunk.height) |by| {
            for (0..Chunk.length) |bz| {
                if (chunk.getBlockState(bx, by, bz)) |state| {
                    blocks[block_count] = .{ .local_pos = .{ .x = @intCast(bx), .y = @intCast(by), .z = @intCast(bz) }, .block_id = state.id };
                    block_count += 1;
                }
            }
        }
    }

    var stream = std.io.fixedBufferStream(std.mem.sliceAsBytes(blocks[0..block_count]));
    try std.compress.zlib.compress(stream.reader(), file.writer(), .{});
}

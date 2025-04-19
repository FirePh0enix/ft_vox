const std = @import("std");
const zm = @import("zmath");
const world_gen = @import("../world_gen.zig");

const Self = @This();
const Allocator = std.mem.Allocator;
const Registry = @import("Registry.zig");
const Chunk = @import("Chunk.zig");
const Ray = @import("../math.zig").Ray;
const SimplexNoise = @import("../math.zig").SimplexNoiseWithOptions(f32);
const Renderer = @import("../render/Renderer.zig");
const Graph = @import("../render/Graph.zig");
const RID = Renderer.RID;

const rdr = Renderer.rdr;

const world_directory: []const u8 = "user_data/worlds";

pub const BlockInstanceData = extern struct {
    position: [3]f32 = .{ 0.0, 0.0, 0.0 },
    textures0: [3]f32 = .{ 0.0, 0.0, 0.0 },
    textures1: [3]f32 = .{ 0.0, 0.0, 0.0 },
    visibility: u32 = 0,
};

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

// https://minecraft.fandom.com/wiki/Ocean
pub const GenerationSettings = struct {
    seed: ?u64 = null,
    sea_level: usize = 62,
};

allocator: Allocator,

seed: u64,
generation_settings: GenerationSettings,
noise: SimplexNoise,

/// Chunks loaded in memory that are updated and rendered to the player.
chunks: std.AutoHashMapUnmanaged(ChunkPos, Chunk) = .empty,
chunks_lock: std.Thread.Mutex = .{},

chunk_worker_state: std.atomic.Value(bool) = .init(false),
chunk_load_worker: ChunkLoadWorker = .{},
chunk_unload_worker: ChunkUnloadWorker = .{},

// TODO: Instance buffers used by chunks to display blocks.
//       This world struct should probably be split in two: The data store part and the updating/rendering part.
// TODO: This array should be resized when changing the render distance at runtime.

buffers: []BufferData = &.{},
buffers_states: std.bit_set.DynamicBitSetUnmanaged = .{},
buffers_mutex: std.Thread.Mutex = .{},

render_distance: usize = 0,

const BufferData = struct {
    rid: RID,
    instance_count: usize,
};

pub fn initEmpty(
    allocator: Allocator,
    seed: u64,
    settings: GenerationSettings,
) Self {
    return .{
        .allocator = allocator,
        .seed = seed,
        .generation_settings = settings,
        .noise = SimplexNoise.initWithSeed(seed),
    };
}

pub fn startWorkers(self: *Self, registry: *const Registry) !void {
    self.chunk_worker_state.store(true, .release);
    self.chunk_load_worker.thread = try std.Thread.spawn(.{}, ChunkLoadWorker.worker, .{ &self.chunk_load_worker, self, registry });
    self.chunk_unload_worker.thread = try std.Thread.spawn(.{}, ChunkUnloadWorker.worker, .{ &self.chunk_unload_worker, self, registry });
}

pub fn createBuffers(self: *Self, render_distance: usize) !void {
    self.render_distance = render_distance;

    self.buffers_states = try .initFull(self.allocator, (render_distance + 1) * 2 * (render_distance + 1) * 2);

    self.buffers = try self.allocator.alloc(BufferData, (render_distance + 1) * 2 * (render_distance + 1) * 2);
    for (0..self.buffers.len) |index| self.buffers[index] = .{ .rid = try rdr().bufferCreate(.{ .size = @sizeOf(BlockInstanceData) * Chunk.block_count, .usage = .{ .vertex_buffer = true, .transfer_dst = true } }), .instance_count = 0 };
}

pub fn deinit(self: *Self) void {
    self.chunk_worker_state.store(false, .release);

    if (self.chunk_load_worker.thread) |thread| {
        self.chunk_load_worker.sleep_semaphore.post();
        thread.join();
        self.chunk_load_worker.orders.deinit(self.allocator);
    }

    rdr().waitIdle();

    for (self.buffers) |buffer| rdr().freeRid(buffer.rid);
    self.allocator.free(self.buffers);

    self.buffers_states.deinit(self.allocator);
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

            const buffer_index = world.acquireBuffer() orelse continue;

            self.orders_mutex.lock();
            const chunk_pos = self.orders.pop();
            remaining = self.orders.items.len;
            self.orders_mutex.unlock();

            if (chunk_pos) |pos| {
                {
                    world.chunks_lock.lock();
                    defer world.chunks_lock.unlock();

                    if (world.chunks.contains(pos)) {
                        world.freeBuffer(buffer_index);
                        continue;
                    }
                }

                // TODO: How should chunk generation/load errors should be threated ?
                var chunk = world_gen.generateChunk(world, world.generation_settings, @intCast(pos.x), @intCast(pos.z)) catch unreachable;
                chunk.computeVisibility(null, null, null, null);
                rebuildInstanceBuffer(&chunk, registry, &world.buffers[buffer_index]) catch unreachable;

                chunk.instance_buffer_index = buffer_index;

                world.chunks_lock.lock();
                defer world.chunks_lock.unlock();

                world.chunks.put(world.allocator, pos, chunk) catch unreachable;
            }
        }
    }
};

/// Unload a chunk on a separate thread.
pub fn unloadChunk(self: *Self, pos: ChunkPos) !void {
    self.chunk_unload_worker.orders_mutex.lock();
    defer self.chunk_unload_worker.orders_mutex.unlock();

    try self.chunk_unload_worker.orders.append(self.allocator, pos);
    self.chunk_unload_worker.sleep_semaphore.post();
}

const ChunkUnloadWorker = struct {
    thread: ?std.Thread = null,
    sleep_semaphore: std.Thread.Semaphore = .{},
    orders_mutex: std.Thread.Mutex = .{},
    orders: std.ArrayListUnmanaged(ChunkPos) = .empty,

    fn worker(self: *ChunkUnloadWorker, world: *Self, registry: *const Registry) void {
        _ = registry;

        var remaining: usize = 0;

        while (world.chunk_worker_state.load(.acquire)) {
            if (remaining == 0) self.sleep_semaphore.wait();

            self.orders_mutex.lock();
            const chunk_pos = self.orders.pop();
            remaining = self.orders.items.len;
            self.orders_mutex.unlock();

            if (chunk_pos) |pos| {
                world.chunks_lock.lock();
                defer world.chunks_lock.unlock();

                const chunk = world.chunks.get(pos);

                if (chunk) |c| {
                    world.freeBuffer(c.instance_buffer_index);
                    _ = world.chunks.remove(pos);
                }
            }
        }
    }
};

pub fn updateWorldAround(self: *Self, px: f32, pz: f32) !void {
    const chunk_x = @as(i64, @intFromFloat(px / 16));
    const chunk_z = @as(i64, @intFromFloat(pz / 16)) - 1;
    const rd: i64 = @intCast(self.render_distance);

    var x = -rd;
    while (x < rd) : (x += 1) {
        var z = -rd;
        while (z < rd) : (z += 1) {
            try self.loadChunk(.{ .x = chunk_x + x, .z = chunk_z + z });
        }
    }

    const min_x = chunk_x - rd;
    const max_x = chunk_x + rd;
    const min_z = chunk_z - rd;
    const max_z = chunk_z + rd;

    self.chunks_lock.lock();
    defer self.chunks_lock.unlock();

    var chunk_iter = self.chunks.iterator();
    while (chunk_iter.next()) |entry| {
        if (entry.key_ptr.x < min_x or entry.key_ptr.x > max_x or entry.key_ptr.z < min_z or entry.key_ptr.z > max_z)
            try self.unloadChunk(entry.key_ptr.*);
    }
}

pub fn acquireBuffer(self: *Self) ?usize {
    self.buffers_mutex.lock();
    defer self.buffers_mutex.unlock();

    const index = self.buffers_states.toggleFirstSet() orelse return null;
    return index;
}

pub fn freeBuffer(self: *Self, index: usize) void {
    self.buffers_mutex.lock();
    defer self.buffers_mutex.unlock();

    self.buffers_states.set(index);
}

pub fn encodeDrawCalls(self: *Self, cube_mesh: RID, shadow_pass: *Graph.RenderPass, shadow_material: RID, render_pass: *Graph.RenderPass, render_material: RID) !void {
    self.chunks_lock.lock();
    defer self.chunks_lock.unlock();

    var chunk_iter = self.chunks.valueIterator();

    while (chunk_iter.next()) |chunk| {
        const buffer_data = &self.buffers[chunk.instance_buffer_index];

        shadow_pass.drawInstanced(cube_mesh, shadow_material, buffer_data.rid, 0, rdr().meshGetIndicesCount(cube_mesh), 0, buffer_data.instance_count);
        render_pass.drawInstanced(cube_mesh, render_material, buffer_data.rid, 0, rdr().meshGetIndicesCount(cube_mesh), 0, buffer_data.instance_count);
    }
}

pub fn rebuildInstanceBuffer(chunk: *Chunk, registry: *const Registry, buffer: *BufferData) !void {
    var index: usize = 0;
    var instances: [Chunk.block_count]BlockInstanceData = @splat(BlockInstanceData{});

    for (0..Chunk.length) |x| {
        for (0..Chunk.height) |y| {
            for (0..Chunk.length) |z| {
                const block: BlockState = chunk.blocks[z * Chunk.length * Chunk.height + y * Chunk.length + x];

                if (block.id == 0 or block.visibility == 0) continue;

                const textures = (registry.getBlock(block.id) orelse unreachable).visual.cube.textures;

                instances[index] = .{
                    .position = .{
                        @floatFromInt(chunk.position.x * 16 + @as(isize, @intCast(x))),
                        @floatFromInt(y),
                        @floatFromInt(chunk.position.z * 16 + @as(isize, @intCast(z))),
                    },
                    .textures0 = .{ @floatFromInt(textures[0]), @floatFromInt(textures[1]), @floatFromInt(textures[2]) },
                    .textures1 = .{ @floatFromInt(textures[3]), @floatFromInt(textures[4]), @floatFromInt(textures[5]) },
                    .visibility = @intCast(block.visibility),
                };
                index += 1;
            }
        }
    }

    buffer.instance_count = index;
    try rdr().bufferUpdate(buffer.rid, std.mem.sliceAsBytes(instances[0..index]), 0);
}

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

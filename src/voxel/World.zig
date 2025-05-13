const std = @import("std");
const zm = @import("zmath");
const gen = @import("gen.zig");
const tracy = @import("tracy");

const Self = @This();
const Allocator = std.mem.Allocator;
const Registry = @import("Registry.zig");
const Chunk = @import("Chunk.zig");
const Block = @import("Block.zig");
const Ray = @import("../math.zig").Ray;
const SimplexNoise = @import("../math.zig").SimplexNoiseWithOptions(f32);
const Renderer = @import("../render/Renderer.zig");
const Graph = @import("../render/Graph.zig");
const Camera = @import("../Camera.zig");
const RID = Renderer.RID;
const Buffer = @import("../render/Buffer.zig");

const rdr = Renderer.rdr;

const world_directory: []const u8 = "user_data/worlds";

pub const GradientType = enum(u8) {
    none = 0,
    grass = 1,
};

pub const BlockInstanceData = extern struct {
    position: [3]f32 = .{ 0.0, 0.0, 0.0 },
    textures0: [3]f32 = .{ 0.0, 0.0, 0.0 },
    textures1: [3]f32 = .{ 0.0, 0.0, 0.0 },
    visibility: u8 = 0,
    gradient: u8 = 0,
    gradient_type: GradientType = .none,
    _padding: u8 = 0,
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

    transparent: bool = false,

    _padding: u6 = 0,

    pub inline fn isAir(self: BlockState) bool {
        return self.id == 0;
    }
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
        distance: f32,
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
chunk_load_worker: ChunkLoadWorker,
chunk_unload_worker: ChunkUnloadWorker = .{},

// TODO: Instance buffers used by chunks to display blocks.
//       This world struct should probably be split in two: The data store part and the updating/rendering part.
// TODO: This array should be resized when changing the render distance at runtime.

buffers: []BufferData = &.{},
buffers_states: std.bit_set.DynamicBitSetUnmanaged = .{},
buffers_mutex: std.Thread.Mutex = .{},

render_distance: usize = 0,
registry: *const Registry = undefined,

const BufferData = struct {
    buffer: Buffer,

    opaque_instance_count: usize = 0,
    transparent_instance_count: usize = 0,
};

pub fn initEmpty(
    allocator: Allocator,
    settings: GenerationSettings,
) Self {
    const seed = settings.seed orelse 0;

    return .{
        .allocator = allocator,
        .generation_settings = settings,
        .seed = seed,
        .noise = SimplexNoise.initWithSeed(seed),
        .chunk_load_worker = .{ .orders = .init(allocator, &@import("root").camera) },
    };
}

pub fn startWorkers(self: *Self, registry: *const Registry) !void {
    self.chunk_worker_state.store(true, .release);
    self.chunk_load_worker.thread = try std.Thread.spawn(.{}, ChunkLoadWorker.worker, .{ &self.chunk_load_worker, self, registry });
    self.chunk_unload_worker.thread = try std.Thread.spawn(.{}, ChunkUnloadWorker.worker, .{ &self.chunk_unload_worker, self, registry });

    self.registry = registry;
}

pub fn createBuffers(self: *Self, render_distance: usize) !void {
    self.render_distance = render_distance;

    self.buffers_states = try .initFull(self.allocator, (render_distance * 2 + 1) * (render_distance * 2 + 1));

    self.buffers = try self.allocator.alloc(BufferData, (render_distance * 2 + 1) * (render_distance * 2 + 1));
    for (0..self.buffers.len) |index| self.buffers[index] = .{ .buffer = try Buffer.create(.{ .size = @sizeOf(BlockInstanceData) * Chunk.block_count, .usage = .{ .vertex_buffer = true, .transfer_dst = true } }) };
}

pub fn deinit(self: *Self) void {
    self.chunk_worker_state.store(false, .release);

    if (self.chunk_load_worker.thread) |thread| {
        self.chunk_load_worker.sleep_semaphore.post();
        thread.join();
        self.chunk_load_worker.orders.deinit();
    }

    if (self.chunk_unload_worker.thread) |thread| {
        self.chunk_unload_worker.sleep_semaphore.post();
        thread.join();
        self.chunk_unload_worker.orders.deinit(self.allocator);
    }

    rdr().waitIdle();

    for (self.buffers) |*buffer| buffer.buffer.destroy();
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

pub fn setBlockState(self: *Self, x: i64, y: i64, z: i64, state: BlockState) void {
    const chunk_x = @divFloor(x, 16);
    const chunk_z = @divFloor(z, 16);

    if (self.getChunk(chunk_x, chunk_z)) |chunk| {
        const local_x: usize = @intCast(x - chunk_x * 16);
        const local_z: usize = @intCast(z - chunk_z * 16);

        std.debug.print("{} {}\n", .{ local_x, local_z });

        chunk.setBlockState(local_x, @intCast(y), local_z, state);

        {
            self.chunks_lock.lock();
            defer self.chunks_lock.unlock();

            chunk.computeVisibilityNoLock(self);
        }

        rebuildInstanceBuffer(chunk, self.registry, &self.buffers[chunk.instance_buffer_index]) catch {};
    }
}

pub fn castRay(self: *const Self, ray: Ray, max_length: f32, precision: f32) ?RaycastResult {
    var t: f32 = 0.0;

    while (t < max_length) : (t += precision) {
        const point = ray.at(t);

        const block_x: i64 = @intFromFloat(point[0]);
        const block_y: i64 = @intFromFloat(point[1]);
        const block_z: i64 = @intFromFloat(point[2]);

        if (block_y < 0) continue;

        if (self.getBlockState(block_x, block_y, block_z)) |state| {
            if (state.isAir()) continue;

            const block = self.registry.getBlock(state.id) orelse continue;

            if (!block.solid) continue;

            return RaycastResult{
                .block = .{
                    .state = state,
                    .pos = .{
                        .x = block_x,
                        .y = block_y,
                        .z = block_z,
                    },
                    .distance = t,
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

    try self.chunk_load_worker.orders.add(pos);
    self.chunk_load_worker.sleep_semaphore.post();
}

const ChunkLoadWorker = struct {
    thread: ?std.Thread = null,
    sleep_semaphore: std.Thread.Semaphore = .{},
    orders_mutex: std.Thread.Mutex = .{},
    orders: std.PriorityQueue(ChunkPos, *const Camera, compareDistance),

    fn compareDistance(c: *const Camera, a: ChunkPos, b: ChunkPos) std.math.Order {
        const distance_a = (c.position[0] - @as(f32, @floatFromInt(a.x * 16))) * (c.position[0] - @as(f32, @floatFromInt(a.x * 16))) + (c.position[2] - @as(f32, @floatFromInt(a.z * 16))) * (c.position[2] - @as(f32, @floatFromInt(a.z * 16)));
        const distance_b = (c.position[0] - @as(f32, @floatFromInt(b.x * 16))) * (c.position[0] - @as(f32, @floatFromInt(b.x * 16))) + (c.position[2] - @as(f32, @floatFromInt(b.z * 16))) * (c.position[2] - @as(f32, @floatFromInt(b.z * 16)));
        return std.math.order(distance_a, distance_b);
    }

    fn worker(self: *ChunkLoadWorker, world: *Self, registry: *const Registry) void {
        tracy.setThreadName("ChunkLoadWorker");

        var remaining: usize = 0;

        while (world.chunk_worker_state.load(.acquire)) {
            if (remaining == 0) self.sleep_semaphore.wait();

            const buffer_index = world.acquireBuffer() orelse continue;

            self.orders_mutex.lock();
            const chunk_pos = self.orders.removeOrNull();
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
                var chunk = gen.generateChunk(world, pos.x, pos.z);
                chunk.instance_buffer_index = buffer_index;

                world.chunks_lock.lock();
                defer world.chunks_lock.unlock();

                chunk.computeVisibilityNoLock(world);
                rebuildInstanceBuffer(&chunk, registry, &world.buffers[buffer_index]) catch unreachable;

                world.chunks.put(world.allocator, pos, chunk) catch unreachable;

                {
                    const chunks: []const ?*Chunk = &.{
                        world.getChunk(pos.x, pos.z - 1),
                        world.getChunk(pos.x, pos.z + 1),
                        world.getChunk(pos.x - 1, pos.z),
                        world.getChunk(pos.x + 1, pos.z),
                    };

                    for (chunks) |c| {
                        if (c) |c2| {
                            c2.computeVisibilityNoLock(world);
                            rebuildInstanceBuffer(c2, registry, &world.buffers[c2.instance_buffer_index]) catch unreachable;
                        }
                    }
                }
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

        tracy.setThreadName("ChunkUnloadWorker");

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

pub fn encodeDrawCalls(self: *Self, camera: *Camera, cube_mesh: RID, render_pass: *Graph.RenderPass, render_material: RID, camera_matrix: zm.Mat, shadow_matrix: zm.Mat) !void {
    const zone = tracy.beginZone(@src(), .{ .name = "World.encodeDrawCalls" });
    defer zone.end();

    self.chunks_lock.lock();
    defer self.chunks_lock.unlock();

    _ = shadow_matrix;

    var chunk_iter = self.chunks.valueIterator();

    while (chunk_iter.next()) |chunk| {
        const buffer_data = &self.buffers[chunk.instance_buffer_index];
        const aabb = chunk.aabb();

        if (!camera.frustum.containsBox(aabb)) {
            continue;
        }

        // shadow_pass.drawInstanced(cube_mesh, shadow_material, buffer_data.rid, 0, rdr().meshGetIndicesCount(cube_mesh), 0, buffer_data.opaque_instance_count, shadow_matrix); // inversing the two matrices is interesting !
        render_pass.drawInstanced(cube_mesh, render_material, buffer_data.buffer, 0, rdr().meshGetIndicesCount(cube_mesh), 0, buffer_data.opaque_instance_count, camera_matrix);
    }

    var chunk_iter2 = self.chunks.valueIterator();
    while (chunk_iter2.next()) |chunk| {
        const buffer_data = &self.buffers[chunk.instance_buffer_index];
        const aabb = chunk.aabb();

        if (!camera.frustum.containsBox(aabb)) {
            continue;
        }

        // shadow_pass.drawInstanced(cube_mesh, shadow_material, buffer_data.rid, 0, rdr().meshGetIndicesCount(cube_mesh), buffer_data.opaque_instance_count, buffer_data.transparent_instance_count, shadow_matrix);
        render_pass.drawInstanced(cube_mesh, render_material, buffer_data.buffer, 0, rdr().meshGetIndicesCount(cube_mesh), buffer_data.opaque_instance_count, buffer_data.transparent_instance_count, camera_matrix);
    }
}

pub fn rebuildInstanceBuffer(chunk: *Chunk, registry: *const Registry, buffer: *BufferData) !void {
    const zone = tracy.beginZone(@src(), .{ .name = "World.rebuildInstanceBuffer" });
    defer zone.end();

    var index: usize = 0;
    var instances: [Chunk.block_count]BlockInstanceData = @splat(BlockInstanceData{});

    const grass_name_hash = Block.getNameHash("grass");

    for (0..Chunk.length) |x| {
        for (0..Chunk.height) |y| {
            for (0..Chunk.length) |z| {
                const block_state: BlockState = chunk.blocks[z * Chunk.length * Chunk.height + y * Chunk.length + x];

                if (block_state.id == 0 or block_state.visibility == 0 or block_state.transparent) continue;

                const block = registry.getBlock(block_state.id) orelse unreachable;
                const textures = block.visual.cube.textures;

                instances[index] = .{
                    .position = .{
                        @floatFromInt(chunk.position.x * 16 + @as(isize, @intCast(x))),
                        @floatFromInt(y),
                        @floatFromInt(chunk.position.z * 16 + @as(isize, @intCast(z))),
                    },
                    .textures0 = .{ @floatFromInt(textures[0]), @floatFromInt(textures[1]), @floatFromInt(textures[2]) },
                    .textures1 = .{ @floatFromInt(textures[3]), @floatFromInt(textures[4]), @floatFromInt(textures[5]) },
                    .visibility = @intCast(block_state.visibility),
                    .gradient_type = if (block.name_hash == grass_name_hash) .grass else .none,
                };
                index += 1;
            }
        }
    }

    buffer.opaque_instance_count = index;

    for (0..Chunk.length) |x| {
        for (0..Chunk.height) |y| {
            for (0..Chunk.length) |z| {
                const block_state: BlockState = chunk.blocks[z * Chunk.length * Chunk.height + y * Chunk.length + x];

                if (block_state.id == 0 or block_state.visibility == 0 or !block_state.transparent) continue;

                const block = registry.getBlock(block_state.id) orelse unreachable;
                const textures = block.visual.cube.textures;

                instances[index] = .{
                    .position = .{
                        @floatFromInt(chunk.position.x * 16 + @as(isize, @intCast(x))),
                        @floatFromInt(y),
                        @floatFromInt(chunk.position.z * 16 + @as(isize, @intCast(z))),
                    },
                    .textures0 = .{ @floatFromInt(textures[0]), @floatFromInt(textures[1]), @floatFromInt(textures[2]) },
                    .textures1 = .{ @floatFromInt(textures[3]), @floatFromInt(textures[4]), @floatFromInt(textures[5]) },
                    .visibility = @intCast(block_state.visibility),
                    .gradient_type = if (block.name_hash == grass_name_hash) .grass else .none,
                };
                index += 1;
            }
        }
    }

    buffer.transparent_instance_count = index - buffer.opaque_instance_count;

    try buffer.buffer.update(std.mem.sliceAsBytes(instances[0..index]), 0);
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

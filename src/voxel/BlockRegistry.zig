const std = @import("std");

const Self = @This();
const Block = @import("Block.zig");
const Allocator = std.mem.Allocator;

blocks: std.ArrayList(Block),

pub fn init(allocator: Allocator) Self {
    return .{
        .blocks = .init(allocator),
    };
}

pub fn registerBlock(self: *Self, block: Block) !void {
    try self.blocks.append(block);
}

pub fn get(self: *const Self, id: u16) ?Block {
    if (id == 0 or id - 1 >= self.blocks.items.len)
        return null;
    return self.blocks.items[id - 1];
}

const std = @import("std");
const vk = @import("vk.zig");
const sdl = @import("sdl");

const GetInstanceProcAddrFn = fn (instance: vk.Instance, procname: [*:0]const u8) *const fn () void;

pub fn main() !void {
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // const vkGetInstanceProcAddr: *const GetInstanceProcAddrFn = @ptrCast(sdl.SDL_Vulkan_GetVkGetInstanceProcAddr());
    // const vkb = try vk.Base.load(vkGetInstanceProcAddr);
    // vkb.createInstance(p_create_info: *const InstanceCreateInfo, p_allocator: ?*const AllocationCallbacks);
}

const vk = @import("vulkan");

pub const apis: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
};

pub const Base = vk.BaseWrapper(apis);

pub const Instance = vk.InstanceProxy(apis);
pub const Device = vk.DeviceProxy(apis);
pub const CommandBuffer = vk.CommandBufferProxy(apis);
pub const Queue = vk.QueueProxy(apis);

pub const Image = vk.Image;
pub const PhysicalDevice = vk.PhysicalDevice;
pub const SwapchainKHR = vk.SwapchainKHR;

pub const n = vk;

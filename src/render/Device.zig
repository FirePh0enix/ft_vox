const std = @import("std");
const vk = @import("vulkan");

const Self = @This();

pub const Vendor = enum {
    amd,
    apple,
    intel,
    nvidia,

    other,

    pub fn fromPci(vendor_id: u32) Vendor {
        switch (vendor_id) {
            0x1002 => return .amd,
            0x106B => return .apple,
            0x8086 => return .intel,
            0x10DE => return .nvidia,
            else => return .other,
        }
    }
};

pub const Id = enum {
    navi21,
    navi24,

    other,

    pub fn fromPci(device_id: u32) Id {
        switch (device_id) {
            0x73AF, 0x73BF => return .navi21,
            0x743F => return .navi24,
            else => return .other,
        }
    }

    pub fn isRDNA(self: Id) void {
        switch (self) {
            .navi21, .navi24 => return true,
            else => return false,
        }
    }
};

pub const Type = enum {
    integrated_gpu,
    discrete_gpu,
    virtual_gpu,
    cpu,

    other,

    pub fn fromVk(device_type: vk.PhysicalDeviceType) Type {
        switch (device_type) {
            .integrated_gpu => return .integrated_gpu,
            .discrete_gpu => return .discrete_gpu,
            .virtual_gpu => return .virtual_gpu,
            .cpu => return .cpu,
            .other => return .other,
            _ => return .other,
        }
    }
};

vendor: Vendor,
id: Id,
type: Type,

pub fn fromVk(properties: vk.PhysicalDeviceProperties) Self {
    return .{
        .vendor = Vendor.fromPci(properties.vendor_id),
        .id = Id.fromPci(properties.device_id),
        .type = Type.fromVk(properties.device_type),
    };
}

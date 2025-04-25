const std = @import("std");
const ft = @import("freetype");
const zm = @import("zmath");
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;

// https://www.reddit.com/r/vulkan/comments/16ros2o/rendering_text_in_vulkan/
// https://github.com/baeng72/Programming-an-RTS/blob/main/common/Platform/Vulkan/VulkanFont.h
// https://github.com/baeng72/Programming-an-RTS/blob/main/common/Platform/Vulkan/VulkanFont.cpp

pub var iVec2 = struct {
    x: i32,
    y: i32,
};

pub var Vec2 = struct {
    x: f32,
    y: f32,
};

pub var Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

const VulkanFont = struct {
    const Character = struct {
        size: iVec2,
        bearing: iVec2,
        offset: u32,
        advance: u32,
    };

    const FontVertex = struct {
        pos: Vec3,
        color: zm.Vec,
        uv: Vec2,
    };

    const FrameData = struct {
        // vertexBuffer
        // indexBuffer
        // vertSize
        // indSize
        // numIndices
        // hash
    };
    const PushConst = struct {
        zm.Mat,
    };

    vertices: ArrayList(FontVertex),
    indices: ArrayList(u32),
    characters: AutoHashMap(u8, Character),

    width: i32,
    height: i32,
    invBmpWidth: f32,
    bmpHeight: u32,
    currhash: u32,
    currframe: u32,

    // _stagingBuffer
    // FrameData frames[MAX_FRAMES]; -> double-buffering
    // std::unique_ptr<VulkanTexture> fontTexturePtr;
    // std::unique_ptr<VulkanDescriptor> fontDescriptorPtr;
    // std::unique_ptr<VulkanPipelineLayout> fontPipelineLayoutPtr;
    // std::unique_ptr<VulkanPipeline> fontPipelinePtr;

    orthoproj: zm.Mat,
    // Texture _texture;
    // Renderer::RenderDevice* _renderdevice;
};

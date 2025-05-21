#pragma once

#include "Error.hpp"
#include "View.hpp"
#include "Window.hpp"

enum class VSync : uint8_t
{
    /**
     * @brief Disable vertical synchronization.
     */
    Off,

    /**
     * @brief Enable vertical synchronization.
     */
    On,
};

enum class BufferVisibility : uint8_t
{
    /**
     * @brief Indicate a buffer is only visible from GPU.
     */
    GPUOnly,

    /**
     * @brief Indicate a buffer visible from GPU and CPU.
     */
    GPUAndCPU,
};

struct BufferUsage
{
    /**
     * @brief Used as source in copy operation.
     */
    uint8_t copy_src : 1 = 0;

    /**
     * @brief Used as destination in copy operation.
     */
    uint8_t copy_dst : 1 = 0;

    /**
     * @brief Used as an uniform buffer.
     */
    uint8_t uniform : 1 = 0;

    /**
     * @brief Used as an index buffer.
     */
    uint8_t index : 1 = 0;

    /**
     * @brief Used as an vertex or instance buffer.
     */
    uint8_t vertex : 1 = 0;
};

enum class TextureFormat : uint8_t
{
    RGBA8Srgb,
    BGRA8Srgb,

    R32Sfloat,
    RG32Sfloat,
    RGB32Sfloat,
    RGBA32Sfloat,

    /**
     * @brief Depth 32-bits per pixel.
     */
    D32,
};

size_t size_of(const TextureFormat& format);

struct TextureUsage
{
    /**
     * @brief Used as source in copy operation.
     */
    uint8_t copy_src : 1 = 0;

    /**
     * @brief Used as destination in copy operation.
     */
    uint8_t copy_dst : 1 = 0;

    uint8_t sampled : 1 = 0;

    uint8_t color_attachment : 1 = 0;
    uint8_t depth_attachment : 1 = 0;
};

class Buffer
{
public:
    /**
     * @brief Update the content of the buffer.
     */
    [[nodiscard]]
    virtual Expected<void> update(View<uint8_t> view, size_t offset) = 0;

    [[nodiscard]]
    virtual size_t size() const = 0;

    virtual ~Buffer() {}

protected:
    Buffer() {}
};

class Texture
{
public:
    /**
     * @brief Update the content of a layer of the texture.
     */
    [[nodiscard]]
    virtual Expected<void> update(View<uint8_t> view, uint32_t layer) = 0;

    /**
     * @brief Update the content of the texture.
     */
    [[nodiscard]]
    Expected<void> update(View<uint8_t> view)
    {
        return update(view, 0);
    }

    [[nodiscard]]
    virtual uint32_t width() const = 0;

    [[nodiscard]]
    virtual uint32_t height() const = 0;

    virtual ~Texture() {}

protected:
    Texture() {}
};

class RenderingDriver
{
public:
    RenderingDriver() {}
    virtual ~RenderingDriver() {}

    RenderingDriver(const RenderingDriver&) = delete;
    RenderingDriver(const RenderingDriver&&) = delete;
    RenderingDriver operator=(const RenderingDriver&) = delete;
    RenderingDriver operator=(const RenderingDriver&&) = delete;

    template <typename T>
    static void create_singleton()
    {
        singleton = (RenderingDriver *)new T();
    };

    /**
     * @brief Returns the singleton for the rendering driver.
     */
    static RenderingDriver *get()
    {
        return singleton;
    }

    /**
     * @brief Initialize the underlaying graphics API.
     */
    [[nodiscard]]
    virtual Expected<void> initialize(const Window& window) = 0;

    /**
     * @brief Configure the surface and swapchain.
     * It must be called every time the window is resized.
     */
    [[nodiscard]]
    virtual Expected<void> configure_surface(const Window& window, VSync vsync) = 0;

    /**
     * @brief Allocate a buffer in the GPU memory.
     */
    [[nodiscard]]
    virtual Expected<Buffer *> create_buffer(size_t size, BufferUsage flags = {}, BufferVisibility visibility = BufferVisibility::GPUOnly) = 0;

    /**
     * @brief Free the memory allocated by a buffer.
     */
    virtual void destroy_buffer(Buffer *buffer) = 0;

    [[nodiscard]]
    virtual Expected<Texture *> create_texture(uint32_t width, uint32_t height, TextureFormat format, TextureUsage usage) = 0;

    [[nodiscard]]
    virtual Expected<Texture *> create_texture_array(uint32_t width, uint32_t height, TextureFormat format, TextureUsage usage, uint32_t layers) = 0;

    [[nodiscard]]
    virtual Expected<Texture *> create_texture_cube(uint32_t width, uint32_t height, TextureFormat format, TextureUsage usage) = 0;

    virtual void destroy_texture(Texture *texture) = 0;

private:
    static RenderingDriver *singleton;
};

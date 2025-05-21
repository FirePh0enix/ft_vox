#include "Render/DriverVulkan.hpp"

#include <print>

#include <SDL3/SDL_vulkan.h>

static inline vk::BufferUsageFlags convert_buffer_usage(BufferUsage usage)
{
    vk::BufferUsageFlags flags{};

    if (usage.copy_src)
        flags |= vk::BufferUsageFlagBits::eTransferSrc;
    if (usage.copy_dst)
        flags |= vk::BufferUsageFlagBits::eTransferDst;
    if (usage.uniform)
        flags |= vk::BufferUsageFlagBits::eUniformBuffer;
    if (usage.index)
        flags |= vk::BufferUsageFlagBits::eIndexBuffer;
    if (usage.vertex)
        flags |= vk::BufferUsageFlagBits::eVertexBuffer;

    return flags;
}

static inline vk::ImageUsageFlags convert_texture_usage(TextureUsage usage)
{
    vk::ImageUsageFlags flags{};

    if (usage.copy_src)
        flags |= vk::ImageUsageFlagBits::eTransferSrc;
    if (usage.copy_dst)
        flags |= vk::ImageUsageFlagBits::eTransferDst;
    if (usage.sampled)
        flags |= vk::ImageUsageFlagBits::eSampled;
    if (usage.color_attachment)
        flags |= vk::ImageUsageFlagBits::eColorAttachment;
    if (usage.depth_attachment)
        flags |= vk::ImageUsageFlagBits::eDepthStencilAttachment;

    return flags;
}

static inline vk::Format convert_texture_format(TextureFormat format)
{
    switch (format)
    {
    case TextureFormat::RGBA8Srgb:
        return vk::Format::eR8G8B8A8Srgb;
    case TextureFormat::BGRA8Srgb:
        return vk::Format::eB8G8R8A8Srgb;
    case TextureFormat::R32Sfloat:
        return vk::Format::eR32Sfloat;
    case TextureFormat::RG32Sfloat:
        return vk::Format::eR32G32Sfloat;
    case TextureFormat::RGB32Sfloat:
        return vk::Format::eR32G32B32Sfloat;
    case TextureFormat::RGBA32Sfloat:
        return vk::Format::eR32G32B32A32Sfloat;
    case TextureFormat::D32:
        return vk::Format::eD32Sfloat;
    }

    return vk::Format::eUndefined;
}

static inline vk::PolygonMode convert_polygon_mode(PolygonMode polygon_mode)
{
    switch (polygon_mode)
    {
    case PolygonMode::Fill:
        return vk::PolygonMode::eFill;
    case PolygonMode::Line:
        return vk::PolygonMode::eLine;
    case PolygonMode::Point:
        return vk::PolygonMode::ePoint;
    };

    return vk::PolygonMode::eFill;
}

static inline vk::CullModeFlags convert_cull_mode(CullMode cull_mode)
{
    switch (cull_mode)
    {
    case CullMode::Back:
        return vk::CullModeFlagBits::eBack;
    case CullMode::Front:
        return vk::CullModeFlagBits::eFront;
    case CullMode::None:
        return vk::CullModeFlagBits::eNone;
    };

    return vk::CullModeFlagBits::eNone;
}

static inline vk::IndexType convert_index_type(IndexType index_type)
{
    switch (index_type)
    {
    case IndexType::Uint16:
        return vk::IndexType::eUint16;
    case IndexType::Uint32:
        return vk::IndexType::eUint32;
    };

    return vk::IndexType::eUint16;
}

static vk::Filter convert_filter(Filter filter)
{
    switch (filter)
    {
    case Filter::Linear:
        return vk::Filter::eLinear;
    case Filter::Nearest:
        return vk::Filter::eNearest;
    }

    return vk::Filter::eLinear;
}

static vk::SamplerAddressMode convert_address_mode(AddressMode address_mode)
{
    switch (address_mode)
    {
    case AddressMode::Repeat:
        return vk::SamplerAddressMode::eRepeat;
    case AddressMode::ClampToEdge:
        return vk::SamplerAddressMode::eClampToEdge;
    }

    return vk::SamplerAddressMode::eRepeat;
}

static vk::SamplerCreateInfo convert_sampler(Sampler sampler)
{
    return vk::SamplerCreateInfo(
        {},
        convert_filter(sampler.mag_filter), convert_filter(sampler.min_filter),
        vk::SamplerMipmapMode::eLinear,
        convert_address_mode(sampler.address_mode.u), convert_address_mode(sampler.address_mode.v), convert_address_mode(sampler.address_mode.w),
        1.0,
        vk::False, 0.0,
        vk::False, vk::CompareOp::eEqual,
        0.0, 0.0,
        vk::BorderColor::eIntOpaqueBlack,
        vk::False);
}

SamplerCache::SamplerCache()
{
}

Expected<vk::Sampler> SamplerCache::get_or_create(Sampler sampler)
{
    auto iter = m_samplers.find(sampler);

    if (iter != m_samplers.end())
    {
        return iter->second;
    }
    else
    {
        auto sampler_vk_result = RenderingDriverVulkan::get()->get_device().createSampler(convert_sampler(sampler));
        YEET_RESULT(sampler_vk_result);

        m_samplers[sampler] = sampler_vk_result.value;
        return sampler_vk_result.value;
    }
}

PipelineCache::PipelineCache()
{
}

Expected<vk::Pipeline> PipelineCache::get_or_create(Material *material, vk::RenderPass render_pass)
{
}

RenderingDriverVulkan::RenderingDriverVulkan()
{
}

RenderingDriverVulkan::~RenderingDriverVulkan()
{
    if (m_device)
    {
        destroy_swapchain();

        m_device.destroyRenderPass(m_render_pass);

        m_device.destroyQueryPool(m_timestamp_query_pool);

        for (size_t i = 0; i < max_frames_in_flight; i++)
        {
            m_device.destroySemaphore(m_image_available_semaphores[i]);
            m_device.destroySemaphore(m_render_finished_semaphores[i]);
            m_device.destroyFence(m_in_flight_fences[i]);
        }

        m_device.freeCommandBuffers(m_graphics_command_pool, m_command_buffers);
        m_device.destroyCommandPool(m_graphics_command_pool);

        m_device.destroy();
    }

    if (m_instance)
    {
        m_instance.destroySurfaceKHR(m_surface);
        m_instance.destroy();
    }
}

std::expected<void, Error> RenderingDriverVulkan::initialize(const Window& window)
{
    Uint32 instance_extensions_count = 0;
    auto instance_extensions = SDL_Vulkan_GetInstanceExtensions(&instance_extensions_count);

    vk::ApplicationInfo app_info("ft_vox", 0, "No engine", 0, VK_API_VERSION_1_2);

    std::vector<const char *> validation_layers;

#ifdef __DEBUG__
    validation_layers.push_back("VK_LAYER_KHRONOS_validation");
#endif

    std::vector<char *> required_instance_extensions(instance_extensions_count);
    for (size_t i = 0; i < instance_extensions_count; i++)
        required_instance_extensions[i] = (char *)instance_extensions[i];

    auto instance_result = vk::createInstance(vk::InstanceCreateInfo({}, &app_info, validation_layers.size(), validation_layers.data(), required_instance_extensions.size(), required_instance_extensions.data()));
    YEET_RESULT(instance_result);
    if (instance_result.result != vk::Result::eSuccess)
        return std::unexpected(instance_result.result);
    m_instance = instance_result.value;

    VkSurfaceKHR surface;

    if (!SDL_Vulkan_CreateSurface(window.get_window_ptr(), m_instance, nullptr, &surface))
        return std::unexpected(ErrorKind::BadDriver);
    m_surface = surface;

    // Select the best physical device
    vk::PhysicalDeviceFeatures required_features = {};
    vk::PhysicalDeviceFeatures optional_features = {};

    std::vector<const char *> required_extensions;
    std::vector<const char *> optional_extensions;

    required_extensions.push_back("VK_KHR_swapchain");

#ifdef __TARGET_APPLE__
    required_extensions.push_back("VK_KHR_portability_subset");
#endif

    vk::PhysicalDeviceHostQueryResetFeatures host_query_reset_features{};

#ifdef __DEBUG__
    host_query_reset_features.hostQueryReset = vk::True;
#endif

#ifdef __TARGET_APPLE__
    vk::PhysicalDevicePortabilitySubsetFeaturesKHR portability_subset_features;
    portability_subset_features.imageViewFormatSwizzle = vk::True;

    host_query_reset_features.pNext = &portability_subset_features;
#endif

    std::vector<vk::PhysicalDevice> physical_devices = m_instance.enumeratePhysicalDevices().value;
    std::optional<PhysicalDeviceWithInfo> physical_device_with_info_result = pick_best_device(physical_devices, required_extensions, optional_extensions);

    if (!physical_device_with_info_result.has_value())
        return std::unexpected(ErrorKind::NoSuitableDevice);

    m_physical_device = physical_device_with_info_result->physical_device;
    m_physical_device_properties = physical_device_with_info_result->properties;
    m_surface_format = physical_device_with_info_result->surface_format;

    std::println("info: GPU selected: {}", m_physical_device_properties.deviceName.data());

    auto surface_capabilities_result = m_physical_device.getSurfaceCapabilitiesKHR(m_surface);
    if (surface_capabilities_result.result != vk::Result::eSuccess)
        return std::unexpected(surface_capabilities_result.result);
    m_surface_capabilities = surface_capabilities_result.value;

    auto surface_present_modes_result = m_physical_device.getSurfacePresentModesKHR(m_surface);
    if (surface_present_modes_result.result != vk::Result::eSuccess)
        return std::unexpected(surface_present_modes_result.result);
    m_surface_present_modes = surface_present_modes_result.value;

    // Create the actual device used to interact with vulkan
    m_graphics_queue_index = physical_device_with_info_result->queue_info.graphics_index.value();
    m_compute_queue_index = physical_device_with_info_result->queue_info.compute_index.value();

    float queue_priority = 1.0f;
    std::array<vk::DeviceQueueCreateInfo, 2> queue_infos{
        vk::DeviceQueueCreateInfo({}, m_graphics_queue_index, 1, &queue_priority),
        vk::DeviceQueueCreateInfo({}, m_compute_queue_index, 1, &queue_priority),
    };

    std::vector<const char *> device_extensions;
    device_extensions.reserve(required_extensions.size() + optional_extensions.size());

    for (const auto& ext : required_extensions)
        device_extensions.push_back(ext);
    for (const auto& ext : optional_extensions)
        device_extensions.push_back(ext);

    // TODO: device features
    vk::PhysicalDeviceFeatures device_features{};

    auto device_result = m_physical_device.createDevice(vk::DeviceCreateInfo({}, queue_infos.size(), queue_infos.data(), validation_layers.size(), validation_layers.data(), device_extensions.size(), device_extensions.data(), &device_features, &host_query_reset_features));
    if (device_result.result != vk::Result::eSuccess)
        return std::unexpected(device_result.result);
    m_device = device_result.value;

    m_graphics_queue = m_device.getQueue(m_graphics_queue_index, 0);
    m_compute_queue = m_device.getQueue(m_compute_queue_index, 0);

    // Allocate enough command buffers and synchronization primitives for each frame in flight.
    auto gcp_result = m_device.createCommandPool(vk::CommandPoolCreateInfo(vk::CommandPoolCreateFlagBits::eResetCommandBuffer, m_graphics_queue_index));
    if (device_result.result != vk::Result::eSuccess)
        return std::unexpected(gcp_result.result);
    m_graphics_command_pool = gcp_result.value;

    auto buffer_alloc_result = m_device.allocateCommandBuffers(vk::CommandBufferAllocateInfo(m_graphics_command_pool, vk::CommandBufferLevel::ePrimary, max_frames_in_flight));
    if (buffer_alloc_result.result != vk::Result::eSuccess)
        return std::unexpected(buffer_alloc_result.result);

    for (size_t i = 0; i < max_frames_in_flight; i++)
    {
        m_image_available_semaphores[i] = m_device.createSemaphore(vk::SemaphoreCreateInfo()).value;
        m_render_finished_semaphores[i] = m_device.createSemaphore(vk::SemaphoreCreateInfo()).value;
        m_in_flight_fences[i] = m_device.createFence(vk::FenceCreateInfo(vk::FenceCreateFlagBits::eSignaled)).value;
    }

    m_timestamp_query_pool = m_device.createQueryPool(vk::QueryPoolCreateInfo({}, vk::QueryType::eTimestamp, max_frames_in_flight * 2)).value;
    for (size_t i = 0; i < max_frames_in_flight; i++)
        m_device.resetQueryPool(m_timestamp_query_pool, i * 2, 2);

    m_memory_properties = m_physical_device.getMemoryProperties();

    // Create a render pass for the output
    std::array<vk::AttachmentDescription, 2> attachments{
        vk::AttachmentDescription(
            {},
            m_surface_format.format, vk::SampleCountFlagBits::e1,
            vk::AttachmentLoadOp::eClear, vk::AttachmentStoreOp::eStore,
            vk::AttachmentLoadOp::eDontCare, vk::AttachmentStoreOp::eDontCare,
            vk::ImageLayout::eUndefined, vk::ImageLayout::ePresentSrcKHR),
        vk::AttachmentDescription(
            {},
            vk::Format::eD32Sfloat, vk::SampleCountFlagBits::e1,
            vk::AttachmentLoadOp::eClear, vk::AttachmentStoreOp::eDontCare,
            vk::AttachmentLoadOp::eDontCare, vk::AttachmentStoreOp::eDontCare,
            vk::ImageLayout::eUndefined, vk::ImageLayout::eDepthStencilAttachmentOptimal),
    };

    const vk::AttachmentReference color_attach(0, vk::ImageLayout::eColorAttachmentOptimal);
    const vk::AttachmentReference depth_attach(1, vk::ImageLayout::eDepthStencilAttachmentOptimal);

    vk::SubpassDescription subpass({}, vk::PipelineBindPoint::eGraphics, {}, {color_attach}, {}, &depth_attach);

    vk::SubpassDependency dependency(
        vk::SubpassExternal, 0,
        vk::PipelineStageFlagBits::eColorAttachmentOutput | vk::PipelineStageFlagBits::eEarlyFragmentTests, vk::PipelineStageFlagBits::eColorAttachmentOutput | vk::PipelineStageFlagBits::eEarlyFragmentTests,
        {}, vk::AccessFlagBits::eColorAttachmentWrite | vk::AccessFlagBits::eDepthStencilAttachmentWrite);

    auto render_pass_result = m_device.createRenderPass(vk::RenderPassCreateInfo({}, attachments, {subpass}, {dependency}));
    YEET_RESULT(render_pass_result);
    m_render_pass = render_pass_result.value;

    YEET(configure_surface(window, VSync::On));

    return {};
}

Expected<void> RenderingDriverVulkan::configure_surface(const Window& window, VSync vsync)
{
    (void)m_device.waitIdle();

    vk::PresentModeKHR present_mode;

    switch (vsync)
    {
    case VSync::Off:
        present_mode = vk::PresentModeKHR::eImmediate;
        break;
    case VSync::On:
        present_mode = vk::PresentModeKHR::eFifoRelaxed;
        break;
    }

    // Accordig to the vulkan spec only FIFO is required to be supported so we fallback on that if other modes are not supported.
    if (std::find(m_surface_present_modes.begin(), m_surface_present_modes.end(), present_mode) == m_surface_present_modes.end())
        present_mode = vk::PresentModeKHR::eFifo;

    const auto& size = window.size();

    const vk::Extent2D surface_extent(std::clamp(size.width, m_surface_capabilities.minImageExtent.width, m_surface_capabilities.maxImageExtent.width),
                                      std::clamp(size.height, m_surface_capabilities.minImageExtent.height, m_surface_capabilities.maxImageExtent.height));

    const uint32_t image_count = m_surface_capabilities.maxImageCount == 0 ? m_surface_capabilities.minImageCount + 1 : std::min(m_surface_capabilities.maxImageCount, m_surface_capabilities.minImageCount + 1);

    auto swapchain_result = m_device.createSwapchainKHR(vk::SwapchainCreateInfoKHR(
        {},
        m_surface,
        image_count,
        m_surface_format.format, m_surface_format.colorSpace,
        surface_extent,
        1,
        vk::ImageUsageFlagBits::eColorAttachment,
        vk::SharingMode::eExclusive,
        0, nullptr,
        m_surface_capabilities.currentTransform,
        vk::CompositeAlphaFlagBitsKHR::eOpaque,
        present_mode,
        vk::True,
        m_swapchain));
    YEET_RESULT(swapchain_result);

    auto depth_texture_result = create_texture(surface_extent.width, surface_extent.height, TextureFormat::D32, {.depth_attachment = 1});
    YEET(depth_texture_result);

    Ref<TextureVulkan> depth_texture_vk = depth_texture_result.value().cast_to<TextureVulkan>();

    auto swapchain_images_result = m_device.getSwapchainImagesKHR(swapchain_result.value);
    YEET_RESULT(swapchain_images_result);

    std::vector<Ref<Texture>> swapchain_textures;
    swapchain_textures.reserve(swapchain_images_result.value.size());

    std::vector<vk::Framebuffer> swapchain_framebuffers;
    swapchain_framebuffers.reserve(swapchain_images_result.value.size());

    for (const auto& swapchain_image : swapchain_images_result.value)
    {
        auto texture_result = create_texture_from_vk_image(swapchain_image, surface_extent.width, surface_extent.height, m_surface_format.format);
        YEET(texture_result);

        Ref<TextureVulkan> texture = texture_result.value().cast_to<TextureVulkan>();

        swapchain_textures.push_back(texture.cast_to<Texture>());

        std::array<vk::ImageView, 2> attachments = {texture->image_view, depth_texture_vk->image_view};

        auto framebuffer_result = m_device.createFramebuffer(vk::FramebufferCreateInfo({}, m_render_pass, attachments, surface_extent.width, surface_extent.height, 1));
        YEET_RESULT(framebuffer_result);

        swapchain_framebuffers.push_back(framebuffer_result.value);
    }

    destroy_swapchain();

    m_swapchain = swapchain_result.value;
    m_depth_texture = depth_texture_result.value();
    m_swapchain_images = std::move(swapchain_images_result.value);
    m_swapchain_textures = std::move(swapchain_textures);
    m_swapchain_framebuffers = std::move(swapchain_framebuffers);
    m_surface_extent = Extent2D(surface_extent.width, surface_extent.height);

    return {};
}

void RenderingDriverVulkan::destroy_swapchain()
{
    if (m_swapchain)
    {
        for (const auto& fb : m_swapchain_framebuffers)
            m_device.destroyFramebuffer(fb);

        m_swapchain_textures.clear();

        m_device.destroySwapchainKHR(m_swapchain);
    }
}

Expected<Ref<Buffer>> RenderingDriverVulkan::create_buffer(size_t size, BufferUsage usage, BufferVisibility visibility)
{
    vk::MemoryPropertyFlags memory_properties{};

    if (visibility == BufferVisibility::GPUOnly)
        memory_properties = vk::MemoryPropertyFlagBits::eDeviceLocal;
    else if (visibility == BufferVisibility::GPUOnly)
        memory_properties = vk::MemoryPropertyFlagBits::eDeviceLocal | vk::MemoryPropertyFlagBits::eHostVisible;

    auto buffer_result = m_device.createBuffer(vk::BufferCreateInfo({}, size, convert_buffer_usage(usage)));
    YEET_RESULT(buffer_result);

    auto memory_result = allocate_memory_for_buffer(buffer_result.value, memory_properties);
    YEET(memory_result);

    return new BufferVulkan(buffer_result.value, memory_result.value(), size);
}

void RenderingDriverVulkan::destroy_buffer(Buffer *buffer)
{
    BufferVulkan *buffer_vk = (BufferVulkan *)buffer;

    m_device.freeMemory(buffer_vk->memory);
    m_device.destroyBuffer(buffer_vk->buffer);
}

Expected<Ref<Texture>> RenderingDriverVulkan::create_texture(uint32_t width, uint32_t height, TextureFormat format, TextureUsage usage)
{
    const vk::Format vk_format = convert_texture_format(format);

    auto image_result = m_device.createImage(vk::ImageCreateInfo(
        {},
        vk::ImageType::e2D,
        vk_format,
        vk::Extent3D(width, height, 1),
        1, // mipLevels
        1,
        vk::SampleCountFlagBits::e1,
        vk::ImageTiling::eOptimal,
        convert_texture_usage(usage),
        vk::SharingMode::eExclusive));
    YEET_RESULT(image_result);

    auto memory_result = allocate_memory_for_image(image_result.value, vk::MemoryPropertyFlagBits::eDeviceLocal);
    YEET(memory_result);

    vk::ImageAspectFlags aspect_mask = format == TextureFormat::D32 ? vk::ImageAspectFlagBits::eDepth : vk::ImageAspectFlagBits::eColor;

    auto image_view_result = m_device.createImageView(vk::ImageViewCreateInfo({}, image_result.value, vk::ImageViewType::e2D, vk_format, {}, vk::ImageSubresourceRange(aspect_mask, 0, 1, 0, 1)));
    YEET_RESULT(image_view_result);

    return new TextureVulkan(image_result.value, memory_result.value(), image_view_result.value, width, height, width * height * size_of(format), true);
}

Expected<Ref<Texture>> RenderingDriverVulkan::create_texture_array(uint32_t width, uint32_t height, TextureFormat format, TextureUsage usage, uint32_t layers)
{
    const vk::Format vk_format = convert_texture_format(format);

    auto image_result = m_device.createImage(vk::ImageCreateInfo(
        {},
        vk::ImageType::e2D,
        vk_format,
        vk::Extent3D(width, height, 1),
        1, // mipLevels
        layers,
        vk::SampleCountFlagBits::e1,
        vk::ImageTiling::eOptimal,
        convert_texture_usage(usage),
        vk::SharingMode::eExclusive));
    YEET_RESULT(image_result);

    auto memory_result = allocate_memory_for_image(image_result.value, vk::MemoryPropertyFlagBits::eDeviceLocal);
    YEET(memory_result);

    vk::ImageAspectFlags aspect_mask = format == TextureFormat::D32 ? vk::ImageAspectFlagBits::eDepth : vk::ImageAspectFlagBits::eColor;

    auto image_view_result = m_device.createImageView(vk::ImageViewCreateInfo({}, image_result.value, vk::ImageViewType::e2D, vk_format, {}, vk::ImageSubresourceRange(aspect_mask, 0, 1, 0, 1)));
    YEET_RESULT(image_view_result);

    return new TextureVulkan(image_result.value, memory_result.value(), image_view_result.value, width, height, width * height * size_of(format), true);
}

Expected<Ref<Texture>> RenderingDriverVulkan::create_texture_cube(uint32_t width, uint32_t height, TextureFormat format, TextureUsage usage)
{
    const vk::Format vk_format = convert_texture_format(format);

    auto image_result = m_device.createImage(vk::ImageCreateInfo(
        vk::ImageCreateFlagBits::eCubeCompatible,
        vk::ImageType::e2D,
        vk_format,
        vk::Extent3D(width, height, 1),
        1, // mipLevels
        6,
        vk::SampleCountFlagBits::e1,
        vk::ImageTiling::eOptimal,
        convert_texture_usage(usage),
        vk::SharingMode::eExclusive));
    YEET_RESULT(image_result);

    auto memory_result = allocate_memory_for_image(image_result.value, vk::MemoryPropertyFlagBits::eDeviceLocal);
    YEET(memory_result);

    vk::ImageAspectFlags aspect_mask = format == TextureFormat::D32 ? vk::ImageAspectFlagBits::eDepth : vk::ImageAspectFlagBits::eColor;

    auto image_view_result = m_device.createImageView(vk::ImageViewCreateInfo({}, image_result.value, vk::ImageViewType::eCube, vk_format, {}, vk::ImageSubresourceRange(aspect_mask, 0, 1, 0, 1)));
    YEET_RESULT(image_view_result);

    return new TextureVulkan(image_result.value, memory_result.value(), image_view_result.value, width, height, width * height * size_of(format), true);
}

void RenderingDriverVulkan::destroy_texture(Texture *texture)
{
    TextureVulkan *texture_vk = (TextureVulkan *)texture;

    m_device.destroyImageView(texture_vk->image_view);

    if (texture_vk->owned)
    {
        m_device.freeMemory(texture_vk->memory);
        m_device.destroyImage(texture_vk->image);
    }
}

Expected<Ref<Mesh>> RenderingDriverVulkan::create_mesh(IndexType index_type, Span<uint8_t> indices, Span<glm::vec3> vertices, Span<glm::vec2> uvs, Span<glm::vec3> normals)
{
    const size_t vertex_count = indices.size() / size_of(index_type);

    auto index_buffer_result = create_buffer(indices.size(), {.copy_dst = 1, .index = 1});
    YEET(index_buffer_result);
    Ref<Buffer> index_buffer = index_buffer_result.value();

    auto vertex_buffer_result = create_buffer(vertices.size() * sizeof(glm::vec3), {.copy_dst = 1, .vertex = 1});
    YEET(vertex_buffer_result);
    Ref<Buffer> vertex_buffer = vertex_buffer_result.value();

    auto uv_buffer_result = create_buffer(uvs.size() * sizeof(glm::vec2), {.copy_dst = 1, .vertex = 1});
    YEET(uv_buffer_result);
    Ref<Buffer> uv_buffer = uv_buffer_result.value();

    auto normal_buffer_result = create_buffer(normals.size() * sizeof(glm::vec3), {.copy_dst = 1, .vertex = 1});
    YEET(normal_buffer_result);
    Ref<Buffer> normal_buffer = normal_buffer_result.value();

    YEET(index_buffer->update(indices.as_bytes(), 0));
    YEET(vertex_buffer->update(vertices.as_bytes(), 0));
    YEET(uv_buffer->update(uvs.as_bytes(), 0));
    YEET(normal_buffer->update(normals.as_bytes(), 0));

    return new MeshVulkan(index_type, convert_index_type(index_type), vertex_count, index_buffer, vertex_buffer, uv_buffer, normal_buffer);
}

void RenderingDriverVulkan::destroy_mesh(Mesh *mesh)
{
    (void)mesh;
}

Expected<Ref<MaterialLayout>> RenderingDriverVulkan::create_material_layout(Span<ShaderRef> shaders, Span<MaterialParam> params, MaterialFlags flags, std::optional<InstanceLayout> instance_layout, CullMode cull_mode, PolygonMode polygon_mode)
{
    std::vector<vk::DescriptorSetLayoutBinding> bindings;
    bindings.reserve(params.size());

    uint32_t binding = 0;

    for (const auto& param : params)
    {
        vk::DescriptorType type = param.kind == MaterialParamKind::Texture ? vk::DescriptorType::eCombinedImageSampler : vk::DescriptorType::eUniformBuffer;

        bindings.push_back(vk::DescriptorSetLayoutBinding(binding, type, 1, {}, {}));
        binding += 1;
    }

    auto layout_result = RenderingDriverVulkan::get()->get_device().createDescriptorSetLayout(vk::DescriptorSetLayoutCreateInfo({}, bindings));
    YEET_RESULT(layout_result);

    auto pool_result = DescriptorPool::create(layout_result.value, params);
    YEET(pool_result);

    std::array<vk::PushConstantRange, 1> push_constant_ranges{
        vk::PushConstantRange(vk::ShaderStageFlagBits::eFragment, 0, sizeof(PushConstants)),
    };
    std::array<vk::DescriptorSetLayout, 1> descriptor_set_layouts{layout_result.value};

    auto pipeline_layout_result = RenderingDriverVulkan::get()->get_device().createPipelineLayout(vk::PipelineLayoutCreateInfo({}, descriptor_set_layouts, push_constant_ranges));
    YEET_RESULT(pipeline_layout_result);

    return new MaterialLayoutVulkan(layout_result.value, pool_result.value(), shaders.to_vector(), instance_layout, params.to_vector(), convert_polygon_mode(polygon_mode), convert_cull_mode(cull_mode), flags, pipeline_layout_result.value);
}

void RenderingDriverVulkan::destroy_material_layout(MaterialLayout *layout)
{
    delete layout;
}

Expected<Ref<Material>> RenderingDriverVulkan::create_material(MaterialLayout *layout)
{
    MaterialLayoutVulkan *layout_vk = (MaterialLayoutVulkan *)layout;

    auto set_result = layout_vk->m_descriptor_pool.allocate();
    YEET(set_result);

    return new MaterialVulkan(layout, set_result.value());
}

void RenderingDriverVulkan::destroy_material(Material *material)
{
    delete material;
}

void RenderingDriverVulkan::draw_graph(const RenderGraph& graph)
{
    vk::Result result = m_device.waitForFences({m_in_flight_fences[m_current_frame]}, vk::True, std::numeric_limits<uint64_t>::max());
    ERR_RESULT_E_RET(result, "");

    auto image_index_result = m_device.acquireNextImageKHR(m_swapchain, std::numeric_limits<uint64_t>::max(), m_image_available_semaphores[m_current_frame]);
    if (image_index_result.result != vk::Result::eSuccess)
        return;

    uint32_t image_index = image_index_result.value;
    vk::CommandBuffer cb = m_command_buffers[image_index];
    vk::Framebuffer fb = m_swapchain_framebuffers[image_index];

    // TODO: Add synchronization

    for (const auto& instruction : graph.get_instructions())
    {
        switch (instruction.kind)
        {
        case InstructionKind::BeginRenderPass:
        {
            std::array<vk::ClearValue, 2> clear_values{
                vk::ClearColorValue(0.0f, 0.0f, 0.0f, 1.0f),
                vk::ClearDepthStencilValue(0.0),
            };

            cb.beginRenderPass(vk::RenderPassBeginInfo(m_render_pass, fb, vk::Rect2D({}, vk::Extent2D(m_surface_extent.width, m_surface_extent.height)), clear_values), vk::SubpassContents::eInline);
            break;
        }
        case InstructionKind::EndRenderPass:
        {
            cb.endRenderPass();
            break;
        }
        case InstructionKind::Draw:
        {
            MeshVulkan *mesh = (MeshVulkan *)instruction.draw.mesh;

            MaterialVulkan *material = (MaterialVulkan *)instruction.draw.material;
            MaterialLayoutVulkan *material_layout = (MaterialLayoutVulkan *)material->get_layout();

            std::optional<Buffer *> instance_buffer = instruction.draw.instance_buffer;

            auto pipeline_result = m_pipeline_cache.get_or_create(material, m_render_pass);
            ERR_EXPECT_B(pipeline_result, "Failed to create");

            cb.bindPipeline(vk::PipelineBindPoint::eGraphics, pipeline_result.value());
            cb.bindDescriptorSets(vk::PipelineBindPoint::eGraphics, material_layout->m_pipeline_layout, 0, {material->descriptor_set}, {});

            Ref<BufferVulkan> index_buffer = mesh->index_buffer.cast_to<BufferVulkan>();
            Ref<BufferVulkan> vertex_buffer = mesh->vertex_buffer.cast_to<BufferVulkan>();
            Ref<BufferVulkan> normal_buffer = mesh->normal_buffer.cast_to<BufferVulkan>();
            Ref<BufferVulkan> uv_buffer = mesh->uv_buffer.cast_to<BufferVulkan>();

            cb.bindIndexBuffer(index_buffer->buffer, 0, mesh->index_type_vk);
            cb.bindVertexBuffers(0, {vertex_buffer->buffer, normal_buffer->buffer, uv_buffer->buffer}, {0, 0, 0});

            if (instance_buffer.has_value())
                cb.bindVertexBuffers(3, {((BufferVulkan *)instance_buffer.value())->buffer}, {0});

            cb.setViewport(0, {vk::Viewport(0.0, 0.0, (float)m_surface_extent.width, (float)m_surface_extent.height, 0.0, 1.0)});
            cb.setScissor(0, {vk::Rect2D({0, 0}, {m_surface_extent.width, m_surface_extent.height})});

            PushConstants push_constants{
                .view_matrix = instruction.draw.view_matrix,
            };

            cb.pushConstants(material_layout->m_pipeline_layout, vk::ShaderStageFlagBits::eVertex, 0, sizeof(PushConstants), &push_constants);

            cb.drawIndexed(mesh->vertex_count(), instruction.draw.instance_count, 0, 0, 0);

            break;
        }
        case InstructionKind::Copy:
        {
            // TODO
            break;
        }
        }
    }

    result = cb.reset();
    ERR_RESULT_E_RET(result, "");

    result = cb.begin(vk::CommandBufferBeginInfo(vk::CommandBufferUsageFlagBits::eOneTimeSubmit));
    ERR_RESULT_E_RET(result, "");

    // TODO: Process the render pass

    result = cb.end();
    ERR_RESULT_E_RET(result, "");

    vk::PipelineStageFlags flags = vk::PipelineStageFlagBits::eColorAttachmentOutput;
    result = m_graphics_queue.submit({vk::SubmitInfo({m_image_available_semaphores[m_current_frame]}, {flags}, {cb}, {m_render_finished_semaphores[m_current_frame]})});
    ERR_RESULT_E_RET(result, "");

    result = m_graphics_queue.presentKHR(vk::PresentInfoKHR({m_image_available_semaphores[m_current_frame]}, {m_swapchain}, {image_index}));
    ERR_RESULT_E_RET(result, "");
}

Expected<Ref<Texture>> RenderingDriverVulkan::create_texture_from_vk_image(vk::Image image, uint32_t width, uint32_t height, vk::Format format)
{
    vk::ImageAspectFlags aspect_mask = format == vk::Format::eD32Sfloat ? vk::ImageAspectFlagBits::eDepth : vk::ImageAspectFlagBits::eColor;

    auto image_view_result = m_device.createImageView(vk::ImageViewCreateInfo({}, image, vk::ImageViewType::e2D, format, {}, vk::ImageSubresourceRange(aspect_mask, 0, 1, 0, 1)));
    YEET_RESULT(image_view_result);

    return new TextureVulkan(image, nullptr, image_view_result.value, width, height, 0, false);
}

std::optional<uint32_t> RenderingDriverVulkan::find_memory_type_index(uint32_t type_bits, vk::MemoryPropertyFlags properties)
{
    uint32_t bits = type_bits;

    for (size_t i = 0; i < m_memory_properties.memoryTypeCount; i++)
    {
        if (bits & 1 && m_memory_properties.memoryTypes[i].propertyFlags & properties)
            return i;
        bits >>= 1;
    }

    return std::nullopt;
}

std::expected<vk::DeviceMemory, Error> RenderingDriverVulkan::allocate_memory_for_buffer(vk::Buffer buffer, vk::MemoryPropertyFlags properties)
{
    vk::MemoryRequirements requirements = m_device.getBufferMemoryRequirements(buffer);
    auto memory_type_index_opt = find_memory_type_index(requirements.memoryTypeBits, properties);

    if (!memory_type_index_opt.has_value())
        return Error::unexpected<vk::DeviceMemory>(ErrorKind::OutOfDeviceMemory);

    uint32_t memory_type_index = memory_type_index_opt.value();
    auto memory_result = m_device.allocateMemory(vk::MemoryAllocateInfo(requirements.size, memory_type_index));
    YEET_RESULT(memory_result);

    auto bind_result = m_device.bindBufferMemory(buffer, memory_result.value, 0);
    YEET_RESULT_E(bind_result);

    return memory_result.value;
}

std::expected<vk::DeviceMemory, Error> RenderingDriverVulkan::allocate_memory_for_image(vk::Image image, vk::MemoryPropertyFlags properties)
{
    vk::MemoryRequirements requirements = m_device.getImageMemoryRequirements(image);
    auto memory_type_index_opt = find_memory_type_index(requirements.memoryTypeBits, properties);

    if (!memory_type_index_opt.has_value())
        return Error::unexpected<vk::DeviceMemory>(ErrorKind::OutOfDeviceMemory);

    uint32_t memory_type_index = memory_type_index_opt.value();
    auto memory_result = m_device.allocateMemory(vk::MemoryAllocateInfo(requirements.size, memory_type_index));
    YEET_RESULT(memory_result);

    auto bind_result = m_device.bindImageMemory(image, memory_result.value, 0);
    YEET_RESULT_E(bind_result);

    return memory_result.value;
}

static bool contains_ext(const std::vector<vk::ExtensionProperties>& extensions, const char *ext)
{
    return std::find_if(extensions.begin(), extensions.end(), [ext](auto& extension)
                        { return std::strcmp(extension.extensionName, ext) == 0; }) != extensions.end();
}

static int32_t calculate_device_score(const vk::PhysicalDeviceProperties& properties, const std::vector<vk::ExtensionProperties>& extensions, const std::vector<const char *>& required_extensions, const std::vector<const char *>& optional_extensions)
{
    int32_t score = 0;

    switch (properties.deviceType)
    {
    case vk::PhysicalDeviceType::eDiscreteGpu:
        score += 100;
        break;
    case vk::PhysicalDeviceType::eIntegratedGpu:
        score += 10;
        break;
    case vk::PhysicalDeviceType::eCpu:
        score += 1;
        break;
    default:
        break;
    }

    // TODO: physical device features

    for (auto& ext : required_extensions)
    {
        if (!contains_ext(extensions, ext))
            return 0;
    }

    for (auto& ext : optional_extensions)
    {
        if (!contains_ext(extensions, ext))
            score += 20;
    }

    return score;
}

std::expected<QueueInfo, bool> RenderingDriverVulkan::find_queue(vk::PhysicalDevice physical_device)
{
    const std::vector<vk::QueueFamilyProperties> queue_properties = physical_device.getQueueFamilyProperties();
    QueueInfo queue_info;

    // Select a graphics queue
    for (size_t i = 0; i < queue_properties.size(); i++)
    {
        const auto& queue_property = queue_properties[i];

        if (queue_property.queueFlags & vk::QueueFlagBits::eGraphics)
        {
            queue_info.graphics_index = i;

            bool present_support = physical_device.getSurfaceSupportKHR(i, m_surface).value;

            if (!present_support)
                return std::unexpected(false);

            break;
        }
    }

    // Select a compute queue
    for (size_t i = 0; i < queue_properties.size(); i++)
    {
        const auto& queue_property = queue_properties[i];

        if (queue_property.queueFlags & vk::QueueFlagBits::eCompute && i != queue_info.graphics_index)
        {
            queue_info.compute_index = i;
        }
    }

    return queue_info;
}

std::optional<PhysicalDeviceWithInfo> RenderingDriverVulkan::pick_best_device(const std::vector<vk::PhysicalDevice>& physical_devices, const std::vector<const char *>& required_extensions, const std::vector<const char *>& optional_extensions)
{
    std::optional<PhysicalDeviceWithInfo> best_device = std::nullopt;
    int32_t best_score = 0;

    for (const auto& physical_device : physical_devices)
    {
        vk::PhysicalDeviceProperties properties = physical_device.getProperties();
        vk::PhysicalDeviceFeatures features = physical_device.getFeatures();

        std::vector<vk::ExtensionProperties> extensions = physical_device.enumerateDeviceExtensionProperties().value;

        int32_t score = calculate_device_score(properties, extensions, required_extensions, optional_extensions);
        QueueInfo queue_info = find_queue(physical_device).value();

        // FIXME: Detect supported surface formats.
        vk::SurfaceFormatKHR surface_format(vk::Format::eB8G8R8A8Srgb, vk::ColorSpaceKHR::eSrgbNonlinear);

        if (score > best_score)
        {
            best_score = score;
            best_device = PhysicalDeviceWithInfo{
                .physical_device = physical_device,
                .properties = properties,
                .features = features,
                .extensions = extensions,
                .queue_info = queue_info,
                .surface_format = surface_format,
            };
        }
    }

    return best_device;
}

Expected<void> BufferVulkan::update(Span<uint8_t> view, size_t offset)
{
#ifdef __DEBUG__
    if (view.size() > size_bytes - offset)
        return std::unexpected(ErrorKind::OutOfBounds);
#endif

    if (view.size() == 0)
        return {};

    auto buffer_result = RenderingDriverVulkan::get()->create_buffer(view.size());
    YEET(buffer_result);

    Ref<BufferVulkan> staging_buffer_vk = buffer_result.value().cast_to<BufferVulkan>();

    // Copy the data into the staging buffer.
    auto map_result = RenderingDriverVulkan::get()->get_device().mapMemory(staging_buffer_vk->memory, 0, view.size(), {});
    YEET_RESULT(map_result);
    std::memcpy(map_result.value, view.data(), view.size());
    RenderingDriverVulkan::get()->get_device().unmapMemory(staging_buffer_vk->memory);

    // Copy from the staging buffer to the final buffer
    vk::CommandBuffer cb = RenderingDriverVulkan::get()->get_transfer_buffer();

    YEET_RESULT_E(cb.reset());
    YEET_RESULT_E(cb.begin(vk::CommandBufferBeginInfo(vk::CommandBufferUsageFlagBits::eOneTimeSubmit)));

    vk::BufferCopy region(0, offset, std::min(view.size(), size_bytes - offset));

    cb.copyBuffer(staging_buffer_vk->buffer, buffer, {region});
    YEET_RESULT_E(cb.end());

    YEET_RESULT_E(RenderingDriverVulkan::get()->get_graphics_queue().submit({vk::SubmitInfo(0, nullptr, nullptr, 1, &cb)}));
    YEET_RESULT_E(RenderingDriverVulkan::get()->get_graphics_queue().waitIdle());

    return {};
}

Expected<void> TextureVulkan::update(Span<uint8_t> view, uint32_t layer)
{
#ifdef __DEBUG__
    if (view.size() > size)
        return std::unexpected(ErrorKind::OutOfBounds);
#endif

    if (view.size() == 0)
        return {};

    auto buffer_result = RenderingDriverVulkan::get()->create_buffer(view.size());
    YEET(buffer_result);

    Ref<BufferVulkan> staging_buffer_vk = buffer_result.value().cast_to<BufferVulkan>();

    // Copy the data into the staging buffer.
    auto map_result = RenderingDriverVulkan::get()->get_device().mapMemory(staging_buffer_vk->memory, 0, view.size(), {});
    YEET_RESULT(map_result);
    std::memcpy(map_result.value, view.data(), view.size());
    RenderingDriverVulkan::get()->get_device().unmapMemory(staging_buffer_vk->memory);

    // Copy from the staging buffer to the final buffer
    vk::CommandBuffer cb = RenderingDriverVulkan::get()->get_transfer_buffer();

    YEET_RESULT_E(cb.reset());
    YEET_RESULT_E(cb.begin(vk::CommandBufferBeginInfo(vk::CommandBufferUsageFlagBits::eOneTimeSubmit)));

    vk::BufferImageCopy region(0, 0, 0, vk::ImageSubresourceLayers(vk::ImageAspectFlagBits::eColor, 0, layer, 1));

    cb.copyBufferToImage(staging_buffer_vk->buffer, image, vk::ImageLayout::eTransferDstOptimal, {region});
    YEET_RESULT_E(cb.end());

    YEET_RESULT_E(RenderingDriverVulkan::get()->get_graphics_queue().submit({vk::SubmitInfo(0, nullptr, nullptr, 1, &cb)}));
    YEET_RESULT_E(RenderingDriverVulkan::get()->get_graphics_queue().waitIdle());

    return {};
}

Expected<DescriptorPool> DescriptorPool::create(vk::DescriptorSetLayout layout, Span<MaterialParam> params)
{
    uint32_t image_sampler_count = 0;
    uint32_t uniform_buffer_count = 0;

    for (const auto& param : params)
    {
        switch (param.kind)
        {
        case MaterialParamKind::Texture:
            image_sampler_count += 1;
            break;
        case MaterialParamKind::UniformBuffer:
            uniform_buffer_count += 1;
            break;
        }
    }

    std::vector<vk::DescriptorPoolSize> sizes;
    if (image_sampler_count > 0)
        sizes.push_back(vk::DescriptorPoolSize(vk::DescriptorType::eCombinedImageSampler, image_sampler_count));
    if (uniform_buffer_count > 0)
        sizes.push_back(vk::DescriptorPoolSize(vk::DescriptorType::eUniformBuffer, uniform_buffer_count));

    auto pool_result = RenderingDriverVulkan::get()->get_device().createDescriptorPool(vk::DescriptorPoolCreateInfo({}, max_sets, sizes.size(), sizes.data()));
    YEET_RESULT(pool_result);

    return DescriptorPool(layout, std::move(sizes));
}

Expected<vk::DescriptorSet> DescriptorPool::allocate()
{
    if (m_allocation_count / max_sets >= m_pools.size())
    {
        YEET(add_pool());
    }

    vk::DescriptorPool pool = m_pools[m_allocation_count / max_sets];

    auto descriptor_set_result = RenderingDriverVulkan::get()->get_device().allocateDescriptorSets(vk::DescriptorSetAllocateInfo(pool, 1, &m_layout));
    YEET_RESULT(descriptor_set_result);

    m_allocation_count += 1;

    return descriptor_set_result.value[0];
}

Expected<void> DescriptorPool::add_pool()
{
    auto pool_result = RenderingDriverVulkan::get()->get_device().createDescriptorPool(vk::DescriptorPoolCreateInfo({}, max_sets, m_sizes.size(), m_sizes.data()));
    YEET_RESULT(pool_result);

    m_pools.push_back(pool_result.value);

    return {};
}

std::optional<uint32_t> MaterialLayoutVulkan::get_param_binding(const std::string& name)
{
    uint32_t binding = 0;

    for (const auto& param : m_params)
    {
        if (!std::strcmp(name.c_str(), param.name))
            return binding;

        binding += 1;
    }

    return std::nullopt;
}

void MaterialVulkan::set_param(const std::string& name, Texture *texture)
{
    std::optional<uint32_t> binding_result = ((MaterialLayoutVulkan *)m_layout)->get_param_binding(name);
    ERR_COND_V(binding_result.has_value(), "Invalid parameter name `%s`", name.c_str());

    TextureVulkan *texture_vk = (TextureVulkan *)texture;

    vk::DescriptorImageInfo image_info(nullptr, texture_vk->image_view, vk::ImageLayout::eShaderReadOnlyOptimal);
    vk::WriteDescriptorSet write_image(descriptor_set, binding_result.value(), 0, 1, vk::DescriptorType::eCombinedImageSampler, &image_info, nullptr, nullptr);

    RenderingDriverVulkan::get()->get_device().updateDescriptorSets({write_image}, {});
}

void MaterialVulkan::set_param(const std::string& name, Buffer *buffer)
{
    std::optional<uint32_t> binding_result = ((MaterialLayoutVulkan *)m_layout)->get_param_binding(name);
    ERR_COND_V(binding_result.has_value(), "Invalid parameter name `%s`", name.c_str());

    BufferVulkan *buffer_vk = (BufferVulkan *)buffer;

    vk::DescriptorBufferInfo buffer_info(buffer_vk->buffer, 0, buffer_vk->size_bytes);
    vk::WriteDescriptorSet write_image(descriptor_set, binding_result.value(), 0, 1, vk::DescriptorType::eCombinedImageSampler, nullptr, &buffer_info, nullptr);

    RenderingDriverVulkan::get()->get_device().updateDescriptorSets({write_image}, {});
}

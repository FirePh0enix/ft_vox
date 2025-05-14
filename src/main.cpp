#include <print>

#include <SDL3/SDL.h>
#include <SDL3/SDL_vulkan.h>

#include <tracy/Tracy.hpp>

#include <freetype/freetype.h>

int main(int argc, char *argv[])
{
    (void)argc;
    (void)argv;

    tracy::SetThreadName("Main");

    static const int WIDTH = 1280;
    static const int HEIGHT = 720;

    SDL_Init(SDL_INIT_EVENTS | SDL_INIT_VIDEO);
    SDL_Window *window = SDL_CreateWindow("ft_vox", WIDTH, HEIGHT, SDL_WINDOW_VULKAN);

    uint32_t count = 0;
    const auto *const extensions = SDL_Vulkan_GetInstanceExtensions(&count);

    vk::ApplicationInfo app_info("ft_vox", 0, "No engine", 0, VK_API_VERSION_1_2);

#ifdef __TARGET_IS_APPLE__
    vk::Instance instance = vk::createInstance(vk::InstanceCreateInfo(vk::InstanceCreateFlagBits::eEnumeratePortabilityKHR, &app_info, count, extensions)).value;
#else
    vk::Instance instance = vk::createInstance(vk::InstanceCreateInfo({}, &app_info, 0, nullptr, count, extensions)).value;
#endif

    bool running = true;

    while (running)
    {
        FrameMark;

        SDL_Event event;
        while (SDL_PollEvent(&event))
        {
            switch (event.type)
            {
            case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
                running = false;
                break;
            default:
                break;
            }
        }
    }

    instance.destroy();
}

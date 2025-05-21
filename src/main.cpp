#include "Render/Driver.hpp"
#include "Render/DriverVulkan.hpp"
#include "Window.hpp"

#include <print>

#include <tracy/Tracy.hpp>

struct BlockInstanceData
{
    glm::vec3 position;
    glm::vec3 textures0;
    glm::vec3 textures1;
    uint8_t visibility;
    uint8_t gradient;
    uint8_t gradient_type;
    uint8_t pad;
};

int main(int argc, char *argv[])
{
    (void)argc;
    (void)argv;

    initialize_error_handling(argv[0]);

    tracy::SetThreadName("Main");

    static const int width = 1280;
    static const int height = 720;

    Window window("ft_vox", width, height);

    RenderingDriver::create_singleton<RenderingDriverVulkan>();

    auto init_result = RenderingDriver::get()->initialize(window);
    EXPECT(init_result);

    RenderGraph graph;

    while (window.is_running())
    {
        std::optional<SDL_Event> event;

        while ((event = window.poll_event()))
        {
            switch (event->type)
            {
            case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
                window.close();
                break;
            default:
                break;
            }
        }

        graph.reset();
    }
}

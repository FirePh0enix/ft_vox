#include <ft2build.h>
#include <freetype/freetype.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_vulkan.h>

#include <dcimgui.h>
#include <backends/dcimgui_impl_sdl3.h>
#include <backends/dcimgui_impl_opengl3.h>

#ifdef TARGET_IS_EMSCRIPTEN

#include <emscripten/html5.h>
#include <webgpu/webgpu.h>

#else

#include <backends/dcimgui_impl_vulkan.h>

#endif

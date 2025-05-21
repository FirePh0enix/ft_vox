cmake_minimum_required(VERSION 3.20)
project(ft_vox)

include(FetchContent)

set(VERSION_MAJOR 1)
set(VERSION_MINOR 0)
set(VERSION_PATCH 0)

option(BUILD_DOC "Build documentation" OFF)

set(SOURCES
    src/main.cpp

    src/Core/Error.cpp
    src/Render/Driver.cpp
    src/Render/DriverVulkan.cpp
    src/Render/Graph.cpp
    src/Window.cpp
)

set(RESOURCES_COPY
    assets/fonts/Anonymous.ttf

    assets/textures/Dirt.png
    assets/textures/Grass_Side.png
    assets/textures/Grass_Top.png
    assets/textures/Sand.png
    assets/textures/Stone.png
    assets/textures/Water.png
)

set(RESOURCES_SHADERS
    assets/shaders/depth_only.frag
    assets/shaders/font.frag
    assets/shaders/font.vert
    assets/shaders/voxel.frag
    assets/shaders/voxel.vert
)

if (UNIX AND NOT APPLE)
    set(TARGET_IS_LINUX YES)
elseif(APPLE)
    set(TARGET_IS_APPLE YES)
elseif(WIN32)
    set(TARGET_IS_MSVC YES)
endif()

# Generate the `compile_commands.json`
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_executable(ft_vox ${SOURCES})

target_include_directories(ft_vox PRIVATE ${CMAKE_SOURCE_DIR}/src)

# Speed-up compilation by precompiling large most headers
target_precompile_headers(ft_vox PUBLIC src/precompiled.hpp)

# Disable exceptions
target_compile_options(ft_vox PUBLIC -fno-exceptions -fno-rtti)

# Enable warnings
target_compile_options(ft_vox PUBLIC -Wall -Wextra)

# Enable support for C++23
set_property(TARGET ft_vox PROPERTY CXX_STANDARD 23)

if (TARGET_IS_LINUX)
    target_compile_definitions(ft_vox PRIVATE __TARGET_LINUX__)
elseif(TARGET_IS_APPLE)
    target_compile_definitions(ft_vox PRIVATE __TARGET_APPLE__)
elseif(TARGET_IS_MSVC)
    target_compile_definitions(ft_vox PRIVATE __TARGET_MSVC__)
endif()

if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_definitions(ft_vox PRIVATE __DEBUG__)

    # Enable the use of std::stacktrace on linux with gcc
    if (TARGET_IS_LINUX)
        target_link_libraries(ft_vox PUBLIC stdc++exp)
    endif()
endif()

# Use mold when available to speed-up linking
find_program(MOLD mold)
if(MOLD)
    target_link_options(ft_vox PUBLIC -fuse-ld=mold)
endif()

if(TARGET_IS_LINUX OR TARGET_IS_APPLE OR TARGET_IS_MSVC)
    target_compile_definitions(ft_vox PRIVATE __USE_VULKAN__)
endif()

if (TARGET_IS_LINUX OR TARGET_IS_APPLE)
    target_compile_options(ft_vox PRIVATE -fdiagnostics-color)
endif()

#
# Fetch dependencies
#

# VulkanHeaders
FetchContent_Declare(
    VulkanHeaders
    URL https://github.com/KhronosGroup/Vulkan-Headers/archive/v1.4.313.tar.gz
)
FetchContent_MakeAvailable(VulkanHeaders)
target_link_libraries(ft_vox PRIVATE Vulkan::Headers)
target_link_libraries(ft_vox PRIVATE vulkan)

# SDL
set(SDL_STATIC ON)

FetchContent_Declare(
    SDL
    GIT_REPOSITORY https://github.com/libsdl-org/SDL
    GIT_TAG 8aa5b97bb5be8e8f62fd76c3181439e20f3de5e9
)
FetchContent_MakeAvailable(SDL)
target_link_libraries(ft_vox PUBLIC SDL3::SDL3)

# SDL_image
FetchContent_Declare(
    SDL_image
    GIT_REPOSITORY https://github.com/libsdl-org/SDL_image
    GIT_TAG 1c23b06a13161314f6f33e7ab35a2e5c601f1bc3
)
FetchContent_MakeAvailable(SDL_image)
target_link_libraries(ft_vox PUBLIC SDL3_image::SDL3_image)

# ImGui
FetchContent_Declare(
    ImGui
    GIT_REPOSITORY https://github.com/ocornut/imgui
    GIT_TAG b5a73033ab54009186bb8e4c711e03e6b939cb91
)
FetchContent_MakeAvailable(ImGui)
target_sources(ft_vox PRIVATE
    ${imgui_SOURCE_DIR}/imgui.cpp
    ${imgui_SOURCE_DIR}/imgui_draw.cpp
    ${imgui_SOURCE_DIR}/imgui_tables.cpp
    ${imgui_SOURCE_DIR}/imgui_widgets.cpp
    ${imgui_SOURCE_DIR}/backends/imgui_impl_sdl3.cpp
    ${imgui_SOURCE_DIR}/backends/imgui_impl_vulkan.cpp
)
target_include_directories(ft_vox PRIVATE
    ${imgui_SOURCE_DIR}
)

# glm
FetchContent_Declare(
    glm
    GIT_REPOSITORY https://github.com/g-truc/glm
    GIT_TAG 2d4c4b4dd31fde06cfffad7915c2b3006402322f
)
FetchContent_MakeAvailable(glm)
target_link_libraries(ft_vox PRIVATE glm::glm-header-only)

# FreeType
FetchContent_Declare(
    FreeType
    GIT_REPOSITORY https://github.com/freetype/freetype
    GIT_TAG 8a152c824ae08fc3459df5c87e10770fc47f80b1
)
FetchContent_MakeAvailable(FreeType)
target_link_libraries(ft_vox PRIVATE freetype)

# tracy
set(BUILD_SHARED_LIBS OFF)

FetchContent_Declare(
    tracy
    GIT_REPOSITORY https://github.com/wolfpld/tracy
    GIT_TAG 5d542dc09f3d9378d005092a4ad446bd405f819a # v0.11.1
)
FetchContent_MakeAvailable(tracy)
target_link_libraries(ft_vox PRIVATE TracyClient)

# libbacktrace
FetchContent_Declare(
    libbacktrace
    GIT_REPOSITORY https://github.com/ianlancetaylor/libbacktrace
    GIT_TAG 793921876c981ce49759114d7bb89bb89b2d3a2d
)
FetchContent_MakeAvailable(libbacktrace)

if(TARGET_IS_LINUX OR TARGET_IS_APPLE)
    set(ENV${CC} ${CMAKE_C_COMPILER})
    set(ENV{CXX} ${CMAKE_CXX_COMPILER})

    # Configure
    execute_process(
        OUTPUT_QUIET
        COMMAND ${libbacktrace_SOURCE_DIR}/configure
        WORKING_DIRECTORY ${libbacktrace_BINARY_DIR}
    )

    # Build
    execute_process(
        OUTPUT_QUIET
        COMMAND make
        WORKING_DIRECTORY ${libbacktrace_BINARY_DIR}
    )

    # Install
    execute_process(
        OUTPUT_QUIET
        COMMAND make install
        WORKING_DIRECTORY ${libbacktrace_BINARY_DIR}
    )

    target_link_directories(ft_vox PRIVATE ${libbacktrace_BINARY_DIR}/.libs)
    target_link_libraries(ft_vox PRIVATE backtrace)
    target_include_directories(ft_vox PRIVATE ${libbacktrace_SOURCE_DIR})
endif()

# MacOS dependencies
if (TARGET_IS_APPLE)
    # MoltenVK
    FetchContent_Declare(
        MoltenVK
        URL https://github.com/KhronosGroup/MoltenVK/releases/download/v1.2.11-artifacts/MoltenVK-macos.tar
    )
    FetchContent_MakeAvailable(MoltenVK)

    configure_file(${moltenvk_SOURCE_DIR}/vulkan/icd.d/MoltenVK_icd.json ${CMAKE_BINARY_DIR}/vulkan/icd.d/MoltenVK_icd.json COPYONLY)
    configure_file(${moltenvk_SOURCE_DIR}/vulkan/icd.d/libMoltenVK.dylib ${CMAKE_BINARY_DIR}/vulkan/icd.d/libMoltenVK.dylib COPYONLY)
endif()

# Build documention if doxygen is installed
find_package(Doxygen)
if (DOXYGEN_FOUND AND BUILD_DOC)
    set(DOXYGEN_IN ${CMAKE_CURRENT_SOURCE_DIR}/Doxyfile.in)
    set(DOXYGEN_OUT ${CMAKE_BINARY_DIR}/Doxyfile)

    configure_file(${DOXYGEN_IN} ${DOXYGEN_OUT} @ONLY)

    add_custom_target( doc_doxygen ALL
        COMMAND ${DOXYGEN_EXECUTABLE} ${DOXYGEN_OUT}
        WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
        COMMENT "Generating documentation with Doxygen"
        VERBATIM )
endif()

foreach(RESOURCE ${RESOURCE_COPY})
    configure_file(${CMAKE_SOURCE_DIR}/${RESOURCE} ${CMAKE_BINARY_DIR}/${RESOURCE} COPYONLY)
endforeach()

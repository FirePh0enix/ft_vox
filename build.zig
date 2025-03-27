const std = @import("std");

const Build = std.Build;
const Step = Build.Step;
const LazyPath = Build.LazyPath;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "ft_vox",
        .root_module = exe_mod,
    });

    const vulkan_headers = b.dependency("vulkan_headers", .{});

    const vulkan = b.dependency("vulkan", .{
        .registry = vulkan_headers.path("registry/vk.xml"),
    }).module("vulkan-zig");
    exe.root_module.addImport("vulkan", vulkan);

    if (target.result.os.tag == .macos) {
        // On macOS we need to link with MoltenVK.
        const moltenvk = b.dependency("moltenvk", .{});

        const install_icd = b.addInstallBinFile(moltenvk.path("MoltenVK/dynamic/dylib/macOS/MoltenVK_icd.json"), "vulkan/icd.d/MoltenVK_icd.json");
        const install_lib = b.addInstallBinFile(moltenvk.path("MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"), "vulkan/icd.d/libMoltenVK.dylib");

        b.getInstallStep().dependOn(&install_icd.step);
        b.getInstallStep().dependOn(&install_lib.step);
    }

    const vma = b.dependency("vma", .{});
    exe.root_module.addCSourceFile(.{ .file = b.path("src/render/vk_mem_alloc_impl.cpp") });

    const vma_translate_c = b.addTranslateC(.{
        .root_source_file = vma.path("include/vk_mem_alloc.h"),
        .target = target,
        .optimize = optimize,
    });
    vma_translate_c.addIncludePath(vulkan_headers.path("include"));

    exe.root_module.addImport("vma", vma_translate_c.createModule());
    exe.root_module.addIncludePath(vma.path("include"));
    exe.root_module.addIncludePath(vulkan_headers.path("include"));
    exe.linkLibCpp();

    const sdl = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_link_mode = .static,
    });
    const sdl_lib = sdl.artifact("SDL3");
    exe.linkLibrary(sdl_lib);

    const sdl_header = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl.h"),
        .target = target,
        .optimize = optimize,
    });
    sdl_header.addIncludePath(sdl.path("include"));
    exe.step.dependOn(&sdl_header.step);

    const sdl_mod = sdl_header.createModule();
    exe.root_module.addImport("sdl", sdl_mod);

    const zm = b.dependency("zm", .{
        .target = target,
        .optimize = optimize,
    });
    const zm_mod = zm.module("zm");
    exe.root_module.addImport("zm", zm_mod);

    const zigimg = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    const zigimg_mod = zigimg.module("zigimg");
    exe.root_module.addImport("zigimg", zigimg_mod);

    const glslc = b.dependency("shader_compiler", .{}).artifact("shader_compiler");
    const flags: []const []const u8 = &.{
        "--target", "Vulkan-1.2",
    };
    const files: []const []const u8 = &.{
        "assets/shaders/basic_cube.vert",
        "assets/shaders/basic_cube.frag",
    };

    const shaders_mod = b.createModule(.{
        .root_source_file = b.path("shaders.zig"),
        .target = target,
        .optimize = optimize,
    });

    for (files) |file| {
        const path = addCompileShader(b, glslc, exe, file, flags, optimize);
        const name = b.dupe(std.fs.path.basename(file));

        std.mem.replaceScalar(u8, name, '.', '_');

        shaders_mod.addAnonymousImport(name, .{
            .root_source_file = path,
        });
    }

    exe.root_module.addImport("shaders", shaders_mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const env_map = std.process.getEnvMap(b.allocator) catch unreachable;

    if (env_map.get("XDG_SESSION_TYPE")) |value| {
        // Force SDL to use wayland if available.
        if (std.mem.eql(u8, value, "wayland"))
            run_cmd.setEnvironmentVariable("SDL_VIDEODRIVER", "wayland");
    }

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn addCompileShader(
    b: *Build,
    glslc: *Step.Compile,
    exe: *Step.Compile,
    path: []const u8,
    flags: []const []const u8,
    optimize: std.builtin.OptimizeMode,
) LazyPath {
    const cmd = b.addRunArtifact(glslc);
    cmd.addArgs(flags);

    switch (optimize) {
        .Debug => cmd.addArgs(&.{
            "--robust-access",
        }),
        .ReleaseSafe => cmd.addArgs(&.{
            "--optimize-perf",
            "--robust-access",
        }),
        .ReleaseFast => cmd.addArgs(&.{
            "--optimize-perf",
        }),
        .ReleaseSmall => cmd.addArgs(&.{
            "--optimize-perf",
            "--optimize-size",
        }),
    }

    cmd.addFileArg(b.path(path));
    const output_file = cmd.addOutputFileArg(std.mem.join(b.allocator, "", &.{ path, ".spv" }) catch @panic("OOM"));

    exe.step.dependOn(&cmd.step);

    return output_file;
}

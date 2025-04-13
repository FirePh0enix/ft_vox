const std = @import("std");
const cimgui = @import("cimgui_zig");
const builtin = @import("builtin");

const Build = std.Build;
const Step = Build.Step;
const LazyPath = Build.LazyPath;
const ResolvedTarget = std.Build.ResolvedTarget;
const Optimize = std.builtin.OptimizeMode;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const target_is_emscripten = target.result.os.tag == .emscripten;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target_is_emscripten,
    });

    const exe = if (target_is_emscripten) a: {
        break :a b.addLibrary(.{
            .linkage = .static,
            .name = "ft_vox",
            .root_module = exe_mod,
        });
    } else a: {
        break :a b.addExecutable(.{
            .name = "ft_vox",
            .root_module = exe_mod,
        });
    };

    // Link the SDL
    const sdl = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_link_mode = .static,
    });

    if (!target_is_emscripten) {
        const sdl_lib = sdl.artifact("SDL3");
        exe_mod.linkLibrary(sdl_lib);
    }

    const sdl_header = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl.h"),
        .target = target,
        .optimize = optimize,
    });
    sdl_header.addIncludePath(sdl.path("include"));

    if (target_is_emscripten) {
        sdl_header.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ b.sysroot orelse unreachable, "cache", "sysroot", "include" }) });
    }

    exe.step.dependOn(&sdl_header.step);

    // Vulkan is only supported on desktop.
    // TODO: pull cimgui.zig and add WebGPU support.
    if (!target_is_emscripten) {
        const cimgui_dep = b.dependency("cimgui_zig", .{
            .target = target,
            .optimize = optimize,
            .platform = cimgui.Platform.SDL3,
            .renderer = cimgui.Renderer.Vulkan,
        });
        exe.linkLibrary(cimgui_dep.artifact("cimgui"));

        const vulkan_headers = b.dependency("vulkan_headers", .{});

        const cimgui_header = b.addTranslateC(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/dcimgui.h"),
        });
        cimgui_header.addIncludePath(cimgui_dep.path("dcimgui"));
        cimgui_header.addIncludePath(sdl.path("include"));
        cimgui_header.addIncludePath(vulkan_headers.path("include"));
        exe.root_module.addImport("dcimgui", cimgui_header.createModule());
        exe.step.dependOn(&cimgui_header.step);

        const vulkan = b.dependency("vulkan", .{
            .registry = vulkan_headers.path("registry/vk.xml"),
        }).module("vulkan-zig");
        exe.root_module.addImport("vulkan", vulkan);

        // On macOS we need to install MoltenVK at the correct location.
        if (target.result.os.tag == .macos) {
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
    }

    if (target_is_emscripten) {
        exe_mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ b.sysroot orelse unreachable, "cache", "sysroot", "include" }) });
    }

    // For now WebGPU is imported unconditionally or else zls does not provide completions. In the future webgpu
    // could replace vulkan.
    const webgpu = b.dependency("webgpu", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("webgpu", webgpu.module("webgpu"));

    // Non platform specific dependencies.
    const zm = b.dependency("zmath", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zmath", zm.module("root"));

    const zigimg = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zigimg", zigimg.module("zigimg"));

    // Compile shaders to SPIR-V
    const glslc = b.dependency("shader_compiler", .{
        .target = ResolvedTarget{ .query = .{}, .result = builtin.target },
        .optimize = optimize,
    }).artifact("shader_compiler");
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

    if (!target_is_emscripten) {
        b.installArtifact(exe);
    } else {
        // Compiling for emscripten requires using `emcc` to link the project.

        const run_emcc = b.addSystemCommand(&.{b.pathJoin(&.{ b.sysroot orelse unreachable, "emcc" })});

        for (exe.getCompileDependencies(false)) |compile| {
            run_emcc.addArtifactArg(compile);
        }

        run_emcc.addArg("--use-port=sdl3");

        if (target.result.cpu.arch == .wasm64) {
            run_emcc.addArg("-sMEMORY64");
        }

        run_emcc.addArgs(switch (optimize) {
            .Debug => &.{
                "-O0",
                // Preserve DWARF debug information.
                "-g",
                // Use UBSan (full runtime).
                "-fsanitize=undefined",
            },
            .ReleaseSafe => &.{
                "-O3",
                // Use UBSan (minimal runtime).
                "-fsanitize=undefined",
                "-fsanitize-minimal-runtime",
            },
            .ReleaseFast => &.{
                "-O3",
            },
            .ReleaseSmall => &.{
                "-Oz",
            },
        });

        if (optimize != .Debug) {
            // Perform link time optimization.
            run_emcc.addArg("-flto");
            // Minify JavaScript code.
            run_emcc.addArgs(&.{ "--closure", "1" });
        }

        run_emcc.addArg("-sUSE_WEBGPU");
        run_emcc.addArg("-sLEGACY_RUNTIME"); // Currently required by SDL

        // Patch the default HTML shell to also display messages printed to stderr.
        run_emcc.addArg("--pre-js");
        run_emcc.addFileArg(b.addWriteFiles().add("pre.js", (
            \\Module['printErr'] ??= Module['print'];
            \\
        )));

        run_emcc.addArg("-o");
        const app_html = run_emcc.addOutputFileArg("index.html");

        b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = app_html.dirname(),
            .install_dir = .{ .custom = "www" },
            .install_subdir = "",
        }).step);
    }

    // Add a run step
    const run_step = b.step("run", "Run the app");

    if (!target_is_emscripten) {
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

        run_step.dependOn(&run_cmd.step);
    } else {
        const run_emrun = b.addSystemCommand(&.{b.pathJoin(&.{ b.sysroot orelse unreachable, "emrun" })});
        run_emrun.addArg(b.pathJoin(&.{ b.install_path, "www", "index.html" }));
        if (b.args) |args| run_emrun.addArgs(args);
        run_emrun.step.dependOn(b.getInstallStep());

        run_step.dependOn(&run_emrun.step);
    }

    if (!target_is_emscripten) {
        // Standard lldb on macos will prevent SDL from creating a window.
        const lldb_path = if (@import("builtin").os.tag.isDarwin())
            "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb"
        else
            "lldb";

        const lldb_cmd = b.addSystemCommand(&.{ lldb_path, "./zig-out/bin/ft_vox" });
        lldb_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            lldb_cmd.addArgs(args);
        }

        const lldb_step = b.step("lldb", "Run the app with lldb");
        lldb_step.dependOn(&lldb_cmd.step);
    }

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

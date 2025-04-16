const std = @import("std");
const cimgui = @import("cimgui_zig");
const builtin = @import("builtin");
const zemscripten = @import("zemscripten");

const Build = std.Build;
const Step = Build.Step;
const LazyPath = Build.LazyPath;
const ResolvedTarget = std.Build.ResolvedTarget;
const Optimize = std.builtin.OptimizeMode;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable the thread sanitizer");

    const target_is_emscripten = target.result.os.tag == .emscripten;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target_is_emscripten,
        .sanitize_thread = sanitize_thread,
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

    exe.root_module.addImport("sdl", sdl_header.createModule());
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

    const argzon = b.dependency("argzon", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("argzon", argzon.module("argzon"));

    // Compile shaders to SPIR-V
    var spirv_files: std.ArrayList(CompileShader) = .init(b.allocator);

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

    for (files) |file| {
        const compile_shader = addCompileShader(b, glslc, file, flags, optimize);
        spirv_files.append(compile_shader) catch unreachable;
    }

    // Embed all assets, with some of them transformed, into the executable.
    var embedded_assets = addEmbeddedAssets(b, spirv_files.items);
    for (spirv_files.items) |spirv_file| embedded_assets.step.dependOn(spirv_file.step);

    exe.step.dependOn(embedded_assets.step);
    exe.root_module.addImport("embeded_assets", embedded_assets.module);

    if (!target_is_emscripten) {
        b.installArtifact(exe);
    } else {
        const activate_emsdk_step = zemscripten.activateEmsdkStep(b);

        const zemscripten_dep = b.dependency("zemscripten", .{});
        exe.root_module.addImport("zemscripten", zemscripten_dep.module("root"));

        const sysroot_path = b.pathResolve(&.{ zemscripten.emccPath(b), "..", "cache", "sysroot" });
        exe_mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot_path, "include" }) });
        sdl_header.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot_path, "include" }) });

        const emcc_flags = zemscripten.emccDefaultFlags(b.allocator, optimize);
        // try emcc_flags.put("--pre-js", {}); // FIXME: does not work
        // try emcc_flags.put(std.fs.realpathAlloc(b.allocator, "web/pre.js") catch unreachable, {});

        var emcc_settings = zemscripten.emccDefaultSettings(b.allocator, .{
            .optimize = optimize,
        });

        try emcc_settings.put("ALLOW_MEMORY_GROWTH", "1");
        try emcc_settings.put("USE_WEBGPU", "1");
        try emcc_settings.put("LEGACY_RUNTIME", "1");

        const emcc_step = zemscripten.emccStep(
            b,
            exe,
            .{
                .optimize = optimize,
                .flags = emcc_flags,
                .settings = emcc_settings,
                .use_preload_plugins = true,
                .embed_paths = &.{},
                .preload_paths = &.{},
                .install_dir = .{ .custom = "www" },
                // .shell_file_path = "path/to/html/file"
            },
        );
        emcc_step.dependOn(activate_emsdk_step);

        b.getInstallStep().dependOn(emcc_step);
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
        // const args = if (b.args) |args|
        //     args
        // else
        //     &.{};
        const args: []const []const u8 = &.{ "--browser", "chromium" };

        const emrun_step = zemscripten.emrunStep(b, b.pathJoin(&.{ b.install_path, "www", "ft_vox.html" }), args);
        emrun_step.dependOn(b.getInstallStep());

        // if (b.args) |args| emrun_step.addArgs(args);
        run_step.dependOn(emrun_step);
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

const CompileShader = struct {
    path: LazyPath,
    filename: []const u8,
    step: *Step,
};

fn addCompileShader(
    b: *Build,
    glslc: *Step.Compile,
    path: []const u8,
    flags: []const []const u8,
    optimize: std.builtin.OptimizeMode,
) CompileShader {
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

    const output_filename = std.mem.join(b.allocator, "", &.{ path, ".spv" }) catch @panic("OOM");

    cmd.addFileArg(b.path(path));
    const output_file = cmd.addOutputFileArg(output_filename);

    return .{
        .path = output_file,
        .filename = output_filename,
        .step = &cmd.step,
    };
}

const EmbeddedAssets = struct {
    module: *Build.Module,
    step: *Step,
};

fn addEmbeddedAssets(b: *Build, shaders: []const CompileShader) EmbeddedAssets {
    const module = b.createModule(.{
        .root_source_file = null,
    });

    const source: []const u8 = makes: {
        var s: std.ArrayList(u8) = .init(b.allocator);

        s.appendSlice("pub const embeded = .{\n") catch unreachable;

        {
            s.appendSlice("    .shaders = &.{\n") catch unreachable;

            for (shaders) |shader| {
                const name = std.fs.path.basename(shader.filename);

                s.appendSlice(std.fmt.allocPrint(b.allocator, "        .{{ .name = \"{s}\", .data = @embedFile(\"{s}\") }},\n", .{ name, name }) catch unreachable) catch unreachable;

                module.addAnonymousImport(name, .{
                    .root_source_file = shader.path,
                });
            }

            s.appendSlice("    },\n") catch unreachable;
        }

        s.appendSlice("};") catch unreachable;

        break :makes s.toOwnedSlice() catch unreachable;
    };

    const write_files = b.addWriteFiles();
    const embedded_assets = write_files.add("embedded_assets.zig", source);

    module.root_source_file = embedded_assets;

    return .{
        .module = module,
        .step = &write_files.step,
    };
}

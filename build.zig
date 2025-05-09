const std = @import("std");
const cimgui = @import("cimgui_zig");
const builtin = @import("builtin");
const zemscripten = @import("zemscripten");

const Build = std.Build;
const Step = Build.Step;
const LazyPath = Build.LazyPath;
const ResolvedTarget = std.Build.ResolvedTarget;
const Optimize = std.builtin.OptimizeMode;

// Compile for the web: zig build run `-Dtarget=wasm32-emscripten -Dcpu=baseline+atomics`

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable the thread sanitizer");
    const enable_tracy = b.option(bool, "tracy", "Enable tracy integration") orelse false;
    const emrun_browser = b.option([]const u8, "emrun-browser", "") orelse "chromium";

    const target_is_emscripten = target.result.os.tag == .emscripten;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target_is_emscripten,
        .sanitize_thread = sanitize_thread,
        .single_threaded = false, // force multithreading on web
    });

    const exe = if (target_is_emscripten)
        b.addLibrary(.{
            .linkage = .static,
            .name = "ft_vox",
            .root_module = exe_mod,
        })
    else
        b.addExecutable(.{
            .name = "ft_vox",
            .root_module = exe_mod,
        });

    const c_headers = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/c.h"),
    });
    exe.root_module.addImport("c", c_headers.createModule());

    if (target_is_emscripten) {
        const sysroot_path = b.pathResolve(&.{ zemscripten.emccPath(b), "..", "cache", "sysroot" });
        c_headers.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot_path, "include" }) });
    }

    const sdl = if (!target_is_emscripten)
        b.dependency("sdl", .{
            .target = target,
            .optimize = optimize,
            .preferred_link_mode = .static,
        })
    else a: {
        const sysroot_path = b.pathResolve(&.{ zemscripten.emccPath(b), "..", "cache", "sysroot" });

        b.sysroot = sysroot_path;

        break :a b.dependency("sdl", .{
            .target = target,
            .optimize = optimize,
            .preferred_link_mode = .static,
        });
    };

    c_headers.addIncludePath(sdl.path("include"));

    // On web on use the emscripten port of SDL.
    if (!target_is_emscripten) {
        const sdl_lib = sdl.artifact("SDL3");
        exe_mod.linkLibrary(sdl_lib);
    }

    const cimgui_dep = b.dependency("cimgui_zig", .{
        .target = target,
        .optimize = optimize,
        .platform = cimgui.Platform.SDL3,
        .renderer = if (!target_is_emscripten) cimgui.Renderer.Vulkan else cimgui.Renderer.OpenGL3,
    });
    const cimgui_artifact = cimgui_dep.artifact("cimgui");
    exe.linkLibrary(cimgui_artifact);

    if (target_is_emscripten) {
        const sysroot_include_path = b.pathResolve(&.{ zemscripten.emccPath(b), "..", "cache", "sysroot", "include" });
        cimgui_artifact.addSystemIncludePath(.{ .cwd_relative = sysroot_include_path });
    }

    c_headers.addIncludePath(cimgui_dep.path("dcimgui"));

    if (!target_is_emscripten) {
        const vulkan_headers = b.dependency("vulkan_headers", .{});
        c_headers.addIncludePath(vulkan_headers.path("include"));
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
    }

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

    const zgl = b.dependency("zgl", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zgl", zgl.module("zgl"));

    if (!target_is_emscripten) {
        const tracy = b.dependency("tracy", .{
            .target = target,
            .optimize = optimize,
            .tracy_enable = enable_tracy,
        });
        const tracy_artifact = tracy.artifact("tracy");

        exe_mod.addImport("tracy", tracy.module("tracy"));

        if (enable_tracy) {
            exe_mod.linkLibrary(tracy_artifact);
            exe_mod.link_libcpp = true;
        }
    } else {
        const emscripten_sysroot_path = b.pathResolve(&.{ zemscripten.emccPath(b), "..", "cache", "sysroot" });

        const tracy = b.dependency("tracy", .{
            .target = target,
            .optimize = optimize,
            .tracy_enable = enable_tracy,
        });
        const tracy_artifact = tracy.artifact("tracy");

        exe_mod.addImport("tracy", tracy.module("tracy"));

        if (enable_tracy) {
            exe_mod.linkLibrary(tracy_artifact);
            exe_mod.link_libcpp = true;
        }

        std.debug.print("{s}\n", .{emscripten_sysroot_path});
        tracy_artifact.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ emscripten_sysroot_path, "include" }) });
    }

    const freetype = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
    });
    c_headers.addIncludePath(freetype.path("include"));

    // On web the emscripten port of FreeType is used.
    if (!target_is_emscripten) {
        exe.root_module.linkLibrary(freetype.artifact("freetype"));
    }

    // Compile shaders to SPIR-V
    var spirv_files: std.ArrayList(CompileShader) = .init(b.allocator);

    const glslc = b.dependency("shader_compiler", .{
        .target = ResolvedTarget{ .query = .{}, .result = builtin.target },
        .optimize = optimize,
    }).artifact("shader_compiler");
    const flags: []const []const u8 = &.{
        "--target", "Vulkan-1.2",
    };
    const files: []const []const u8 = if (!target_is_emscripten)
        &.{
            "assets/shaders/vk/basic_cube.vert",
            "assets/shaders/vk/basic_cube.frag",

            "assets/shaders/vk/cube_shadow.vert",
            "assets/shaders/vk/cube_shadow.frag",

            "assets/shaders/vk/font.vert",
            "assets/shaders/vk/font.frag",
        }
    else
        &.{
            "assets/shaders/gl/basic_cube.vert",
            "assets/shaders/gl/basic_cube.frag",

            // "assets/shaders/gl/cube_shadow.vert",
            // "assets/shaders/gl/cube_shadow.frag",

            // "assets/shaders/gl/font.vert",
            // "assets/shaders/gl/font.frag",
        };

    for (files) |file| {
        if (!target_is_emscripten) {
            const compile_shader = addCompileShader(b, glslc, file, flags, optimize);
            spirv_files.append(compile_shader) catch unreachable;
        } else {
            const output_filename = std.mem.join(b.allocator, "", &.{ file, ".spv" }) catch @panic("OOM");
            const file_ident = b.dupe(std.fs.path.basename(output_filename));
            std.mem.replaceScalar(u8, file_ident, '.', '_');

            spirv_files.append(.{
                .path = b.path(file),
                .filename = output_filename,
                .file_ident = file_ident,
                .step = undefined,
            }) catch unreachable;
        }
    }

    // Embed all assets, with some of them transformed, into the executable.
    var embedded_assets = addEmbeddedAssets(b, exe_mod, spirv_files.items);

    if (!target_is_emscripten) {
        for (spirv_files.items) |spirv_file| embedded_assets.step.dependOn(spirv_file.step);
    }

    exe.step.dependOn(embedded_assets.step);
    exe.root_module.addImport("embeded_assets", embedded_assets.module);

    const zemscripten_dep = b.dependency("zemscripten", .{});
    exe.root_module.addImport("zemscripten", zemscripten_dep.module("root"));

    if (target_is_emscripten) {
        const emscripten_sysroot_path = b.pathResolve(&.{ zemscripten.emccPath(b), "..", "cache", "sysroot" });
        c_headers.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ emscripten_sysroot_path, "include" }) });
        c_headers.defineCMacro("TARGET_IS_EMSCRIPTEN", null);
    }

    if (!target_is_emscripten) {
        b.installArtifact(exe);
    } else {
        const activate_emsdk_step = zemscripten.activateEmsdkStep(b);

        var emcc_flags = zemscripten.emccDefaultFlags(b.allocator, optimize);
        var emcc_settings = zemscripten.emccDefaultSettings(b.allocator, .{
            .optimize = optimize,
        });

        try emcc_flags.put("-std=c++11", {});

        try emcc_settings.put("ALLOW_MEMORY_GROWTH", "1");
        try emcc_settings.put("LEGACY_RUNTIME", "1");
        try emcc_settings.put("WASM_WORKERS", "1");
        try emcc_settings.put("MAX_WEBGL_VERSION", "2");
        try emcc_settings.put("FULL_ES3", "1");

        try emcc_settings.put("USE_PTHREADS", "1");
        try emcc_settings.put("USE_FREETYPE", "1");

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
                .shell_file_path = "shell.html",
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
        const args: []const []const u8 = &.{ "--browser", emrun_browser };

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
    step: *Step,

    filename: []const u8,
    file_ident: []const u8,
};

fn addCompileShader(b: *Build, glslc: *Step.Compile, path: []const u8, flags: []const []const u8, optimize: std.builtin.OptimizeMode) CompileShader {
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

    const file_ident = b.dupe(std.fs.path.basename(output_filename));
    std.mem.replaceScalar(u8, file_ident, '.', '_');

    return .{
        .path = output_file,
        .filename = output_filename,
        .step = &cmd.step,
        .file_ident = file_ident,
    };
}

const EmbeddedAssets = struct {
    module: *Build.Module,
    step: *Step,
};

fn addEmbeddedAssets(b: *Build, exe: *Build.Module, shaders: []const CompileShader) EmbeddedAssets {
    const module = b.createModule(.{
        .root_source_file = null,
    });

    module.addImport("engine", exe);

    var textures: std.ArrayList(struct {
        filename: []const u8,
        file_ident: []const u8,
        path: LazyPath,
    }) = .init(b.allocator);

    {
        const textures_dir = std.fs.cwd().openDir("assets/textures", .{ .iterate = true }) catch unreachable;
        var dir_iter = textures_dir.iterate();

        while (dir_iter.next() catch unreachable) |entry| {
            const file_ident = b.dupe(std.fs.path.basename(entry.name));
            std.mem.replaceScalar(u8, file_ident, '.', '_');

            textures.append(.{
                .path = b.path(std.fmt.allocPrint(b.allocator, "assets/textures/{s}", .{entry.name}) catch unreachable),
                .filename = b.dupe(entry.name),
                .file_ident = file_ident,
            }) catch unreachable;
        }
    }

    var blocks: std.ArrayList(struct {
        filename: []const u8,
        file_ident: []const u8,
        path: LazyPath,
    }) = .init(b.allocator);

    {
        const blocks_dir = std.fs.cwd().openDir("assets/blocks", .{ .iterate = true }) catch unreachable;
        var dir_iter = blocks_dir.iterate();

        while (dir_iter.next() catch unreachable) |entry| {
            const file_ident = b.dupe(std.fs.path.basename(entry.name));
            std.mem.replaceScalar(u8, file_ident, '.', '_');

            blocks.append(.{
                .path = b.path(std.fmt.allocPrint(b.allocator, "assets/blocks/{s}", .{entry.name}) catch unreachable),
                .filename = b.dupe(entry.name),
                .file_ident = file_ident,
            }) catch unreachable;
        }
    }

    const source: []const u8 = makes: {
        var s: std.ArrayList(u8) = .init(b.allocator);

        s.appendSlice("const engine = @import(\"engine\");\n") catch unreachable;

        for (shaders) |shader| {
            const name = std.fs.path.basename(shader.filename);

            s.appendSlice(std.fmt.allocPrint(b.allocator, "const _shaders_{s} align(4) = @embedFile(\"{s}\").*;\n", .{ shader.file_ident, name }) catch unreachable) catch unreachable;

            module.addAnonymousImport(name, .{
                .root_source_file = shader.path,
            });
        }

        for (textures.items) |texture| {
            s.appendSlice(std.fmt.allocPrint(b.allocator, "const _textures_{s} = @embedFile(\"{s}\").*;\n", .{ texture.file_ident, texture.filename }) catch unreachable) catch unreachable;

            module.addAnonymousImport(texture.filename, .{
                .root_source_file = texture.path,
            });
        }

        for (blocks.items) |block| {
            s.appendSlice(std.fmt.allocPrint(b.allocator, "const _blocks_{s}: engine.BlockZon = @import(\"{s}\");\n", .{ block.file_ident, block.filename }) catch unreachable) catch unreachable;

            module.addAnonymousImport(block.filename, .{
                .root_source_file = block.path,
            });
        }

        s.appendSlice("pub const embeded: struct { shaders: []const struct { name: []const u8, data: [:0]align(4) const u8 }, textures: []const struct { name: []const u8, data: []const u8 }, blocks: []const struct { name: []const u8, data: engine.BlockZon } } = .{\n") catch unreachable;

        {
            s.appendSlice("    .shaders = &.{\n") catch unreachable;

            for (shaders) |shader| {
                const name = std.fs.path.basename(shader.filename);

                s.appendSlice(std.fmt.allocPrint(b.allocator, "        .{{ .name = \"{s}\", .data = &_shaders_{s} }},\n", .{ name, shader.file_ident }) catch unreachable) catch unreachable;
            }

            s.appendSlice("    },\n") catch unreachable;
        }

        {
            s.appendSlice("    .textures = &.{\n") catch unreachable;

            for (textures.items) |texture| {
                const name = std.fs.path.basename(texture.filename);

                s.appendSlice(std.fmt.allocPrint(b.allocator, "        .{{ .name = \"{s}\", .data = &_textures_{s} }},\n", .{ name, texture.file_ident }) catch unreachable) catch unreachable;
            }

            s.appendSlice("    },\n") catch unreachable;
        }

        {
            s.appendSlice("    .blocks = &.{\n") catch unreachable;

            for (blocks.items) |block| {
                const name = std.fs.path.basename(block.filename);

                s.appendSlice(std.fmt.allocPrint(b.allocator, "        .{{ .name = \"{s}\", .data = _blocks_{s} }},\n", .{ name, block.file_ident }) catch unreachable) catch unreachable;
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

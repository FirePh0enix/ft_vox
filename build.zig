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
        .use_llvm = false, // Use the self-hosted backend.
    });

    const vulkan = b.dependency("vulkan", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");
    exe.root_module.addImport("vulkan", vulkan);

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

    // const glslc = b.dependency("shader_compiler", .{}).artifact("glslc");
    // const flags: []const []const u8 = &.{
    //     "--target=vulkan-1.3",
    // };
    // const files: []const []const u8 = &.{
    //     "shaders/cube.vert",
    // };

    // for (files) |file| {
    //     const path = addCompileShader(b, glslc, exe, file, flags, optimize);
    //     const name = std.fs.path.basename(file);
    //     const name_n = name[0..std.mem.indexOfScalar(u8, name, ".")];
    // }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

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
    const output_file = cmd.addOutputFileArg(b.pathJoin(&.{ path, ".spv" }));

    exe.step.dependOn(&cmd.step);

    return output_file;
}

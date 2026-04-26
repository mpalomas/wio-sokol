const std = @import("std");
const Build = std.Build;
pub const shdc = @import("shdc");

const examples = [_]Example{
    .{ .name = "triangle", .has_shader = true },
};

const Example = struct {
    name: []const u8,
    has_shader: bool = false,
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const unix_backends = b.option([]const u8, "unix_backends", "List of enabled wio backends");

    const dep_wio = b.dependency("wio", .{
        .target = target,
        .optimize = optimize,
        .enable_opengl = true,
        .unix_backends = unix_backends,
    });
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .gl = true,
    });
    const mod_wio_sokol_gl = b.addModule("wio_sokol_gl", .{
        .root_source_file = b.path("src/wio_sokol_gl.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wio", .module = dep_wio.module("wio") },
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
        },
    });
    const examples_step = b.step("examples", "Build all examples");

    inline for (examples) |example| {
        buildExample(b, .{
            .example = example,
            .target = target,
            .optimize = optimize,
            .dep_wio = dep_wio,
            .dep_sokol = dep_sokol,
            .mod_wio_sokol_gl = mod_wio_sokol_gl,
            .examples_step = examples_step,
        }) catch @panic("failed to build example");
    }
}

const BuildExampleOptions = struct {
    example: Example,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dep_wio: *Build.Dependency,
    dep_sokol: *Build.Dependency,
    mod_wio_sokol_gl: *Build.Module,
    examples_step: *Build.Step,
};

fn buildExample(b: *Build, options: BuildExampleOptions) !void {
    const example = options.example;
    const mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.fmt("examples/{s}.zig", .{example.name}) },
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{
            .{ .name = "wio", .module = options.dep_wio.module("wio") },
            .{ .name = "sokol", .module = options.dep_sokol.module("sokol") },
            .{ .name = "wio_sokol_gl", .module = options.mod_wio_sokol_gl },
        },
    });

    const opt_shd_step = try buildExampleShader(b, example);
    const exe = b.addExecutable(.{
        .name = example.name,
        .root_module = mod,
    });
    if (opt_shd_step) |shd_step| {
        exe.step.dependOn(shd_step);
    }

    options.examples_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run.addArgs(args);
    }

    b.step(b.fmt("run-{s}", .{example.name}), b.fmt("Run {s}", .{example.name})).dependOn(&run.step);
}

fn buildExampleShader(b: *Build, example: Example) !?*Build.Step {
    if (!example.has_shader) {
        return null;
    }
    const shaders_dir = "examples/shaders/";
    return shdc.createSourceFile(b, .{
        .shdc_dep = b.dependency("shdc", .{}),
        .input = b.fmt("{s}{s}.glsl", .{ shaders_dir, example.name }),
        .output = b.fmt("{s}{s}.glsl.zig", .{ shaders_dir, example.name }),
        .slang = .{
            .glsl410 = true,
        },
        .reflection = true,
    });
}

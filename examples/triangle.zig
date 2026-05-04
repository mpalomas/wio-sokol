const std = @import("std");
const wio = @import("wio");
const wiox = @import("wiox");
const sokol = @import("sokol");
const wio_sokol_gl = @import("wio_sokol_gl");
const frame_pacing = @import("frame_pacing");
const sg = sokol.gfx;
const slog = sokol.log;
const shd = @import("shaders/triangle.glsl.zig");

pub const std_options = std.Options{
    .log_level = .info,
    .logFn = wio.logFn,
};

const gl_options: wio.GlOptions = .{
    .api = .gl,
    .major_version = 4,
    .minor_version = 1,
    .profile = .core,
    .doublebuffer = true,
    .depth_bits = 24,
    .stencil_bits = 8,
};

const state = struct {
    var bindings: sg.Bindings = .{};
    var pipeline: sg.Pipeline = .{};
};

var allocator: std.mem.Allocator = undefined;
var io: std.Io = undefined;

var window: wio.Window = undefined;
var context: wio.GlContext = undefined;
var pacer: frame_pacing.FramePacer = undefined;
const desired_framebuffer_size: wio.Size = .{ .width = 1280, .height = 720 };
var framebuffer_size: wio.Size = desired_framebuffer_size;
var fps_last_report_ms: ?i64 = null;
var fps_frame_count: u32 = 0;

pub fn main(init: std.process.Init) !void {
    allocator = init.gpa;
    io = init.io;

    try wio.init(allocator, io, .{});
    errdefer {
        wio.deinit();
    }

    // Before a window exists we can only estimate which output scale will apply.
    // Use the first enumerated display as a best-effort guess for the initial size.
    const display_scale = logDisplaysAndGetInitialScale();
    const initial_window_size = logicalWindowSizeForFramebuffer(desired_framebuffer_size, display_scale);

    std.log.info("desired framebuffer {}x{} at scale {d:.4} -> createWindow size {}x{}", .{
        desired_framebuffer_size.width,
        desired_framebuffer_size.height,
        display_scale,
        initial_window_size.width,
        initial_window_size.height,
    });
    window = try wio.createWindow(.{
        .title = "wio + sokol_gfx triangle",
        .scale = 1,
        .size = initial_window_size,
        .gl_options = gl_options,
    });
    errdefer window.destroy();

    if (wiox.display.getWindowDisplay(&window)) |display| {
        defer display.release();

        const actual_scale = logDisplay("window display", display) orelse display.getContentScale();
        const actual_window_size = logicalWindowSizeForFramebuffer(desired_framebuffer_size, actual_scale);

        if (!sizeEql(actual_window_size, initial_window_size)) {
            std.log.info("resize window for desired framebuffer {}x{} at scale {d:.4} -> {}x{}", .{
                desired_framebuffer_size.width,
                desired_framebuffer_size.height,
                actual_scale,
                actual_window_size.width,
                actual_window_size.height,
            });
            window.setSize(actual_window_size);
        }
    } else {
        std.log.info("window display: unavailable", .{});
    }

    context = try window.glCreateContext(.{ .options = gl_options });
    errdefer context.destroy();

    window.glMakeContextCurrent(context);
    window.glSwapInterval(1);

    sg.setup(.{
        .environment = wio_sokol_gl.environment(gl_options),
        .logger = .{ .func = slog.func },
    });
    errdefer sg.shutdown();

    std.log.info("sokol backend: {}", .{sg.queryBackend()});

    initTriangle();
    pacer = frame_pacing.FramePacer.init(io, .{
        .tick_rate_hz = 60.0,
        .mode = .locked,
        .frame_cap_hz = 60.0,
        // spin seems to be accurate on macOS, others not really
        .sleep_mode = .spin,
        // .passive_sleep_margin_ns = 2 * std.time.ns_per_ms,
    });
    if (pacer.detectDisplayRefreshRate(&window)) {
        const quality = pacer.quality();
        std.log.info("frame pacer display rate: {d:.4}Hz", .{quality.display_rate_hz});
    } else {
        std.log.info("frame pacer display rate: unavailable", .{});
    }
    // pacer.enabled = false;

    try wio.run(loop);
}

fn logDisplaysAndGetInitialScale() f64 {
    var display_iter = wiox.display.DisplayIterator.init();
    defer display_iter.deinit();

    var initial_scale: f64 = 1.0;
    var display_index: usize = 0;
    while (display_iter.next()) |display| {
        defer display.release();
        if (display.getCurrentMode()) |mode| {
            if (display_index == 0 and mode.content_scale > 0) {
                initial_scale = mode.content_scale;
            }

            if (mode.refresh_rate.numerator != 0) {
                std.log.info("display {}: {}x{} at ({},{}) scale {d:.2} -> {}x{} pixels @ {d:.4}Hz ({}/{})", .{
                    display_index,
                    mode.bounds.width,
                    mode.bounds.height,
                    mode.bounds.x,
                    mode.bounds.y,
                    mode.content_scale,
                    mode.pixel_width,
                    mode.pixel_height,
                    mode.refresh_rate.hz,
                    mode.refresh_rate.numerator,
                    mode.refresh_rate.denominator,
                });
            } else {
                std.log.info("display {}: {}x{} at ({},{}) scale {d:.2} -> {}x{} pixels @ {d:.3}Hz", .{
                    display_index,
                    mode.bounds.width,
                    mode.bounds.height,
                    mode.bounds.x,
                    mode.bounds.y,
                    mode.content_scale,
                    mode.pixel_width,
                    mode.pixel_height,
                    mode.refresh_rate.hz,
                });
            }
        }
        display_index += 1;
    }

    return initial_scale;
}

fn logDisplay(label: []const u8, display: wiox.display.Display) ?f64 {
    if (display.getCurrentMode()) |mode| {
        if (mode.refresh_rate.numerator != 0) {
            std.log.info("{s}: {}x{} at ({},{}) scale {d:.2} -> {}x{} pixels @ {d:.4}Hz ({}/{})", .{
                label,
                mode.bounds.width,
                mode.bounds.height,
                mode.bounds.x,
                mode.bounds.y,
                mode.content_scale,
                mode.pixel_width,
                mode.pixel_height,
                mode.refresh_rate.hz,
                mode.refresh_rate.numerator,
                mode.refresh_rate.denominator,
            });
        } else {
            std.log.info("{s}: {}x{} at ({},{}) scale {d:.2} -> {}x{} pixels @ {d:.3}Hz", .{
                label,
                mode.bounds.width,
                mode.bounds.height,
                mode.bounds.x,
                mode.bounds.y,
                mode.content_scale,
                mode.pixel_width,
                mode.pixel_height,
                mode.refresh_rate.hz,
            });
        }
        return mode.content_scale;
    }

    std.log.info("{s}: current mode unavailable", .{label});
    return null;
}

fn logicalWindowSizeForFramebuffer(target: wio.Size, scale: f64) wio.Size {
    return .{
        .width = logicalAxisForFramebuffer(target.width, scale),
        .height = logicalAxisForFramebuffer(target.height, scale),
    };
}

fn sizeEql(a: wio.Size, b: wio.Size) bool {
    return a.width == b.width and a.height == b.height;
}

fn logicalAxisForFramebuffer(target: u16, scale: f64) u16 {
    if (target == 0) return 0;

    const safe_scale = if (std.math.isFinite(scale) and scale > 0) scale else 1.0;
    const target_f64: f64 = @floatFromInt(target);

    // Start from ceil(target / scale) so the ideal scaled size is not below target.
    // The backend converts logical -> physical with truncation, so verify explicitly
    // and adjust upward if floating-point rounding would otherwise undershoot.
    var logical: u32 = @intFromFloat(@ceil(target_f64 / safe_scale));
    if (logical == 0) logical = 1;

    while (scaledAxis(@intCast(logical), safe_scale) < target) {
        logical += 1;
    }
    // Keep the result minimal: allow overshoot like 1281, but avoid requesting a
    // larger logical size than necessary once the scaled size already reaches target.
    while (logical > 1 and scaledAxis(@intCast(logical - 1), safe_scale) >= target) {
        logical -= 1;
    }

    return @intCast(logical);
}

fn scaledAxis(logical: u16, scale: f64) u16 {
    const logical_f64: f64 = @floatFromInt(logical);
    const scaled = logical_f64 * scale;
    return @intFromFloat(scaled);
}

fn loop() !bool {
    pacer.beginFrame();

    while (window.getEvent()) |event| {
        switch (event) {
            .close => {
                sg.shutdown();
                context.destroy();
                window.destroy();
                wio.deinit();
                return false;
            },
            .size_physical => |size| {
                framebuffer_size = size;
                std.log.info("framebuffer_size {}x{}", .{
                    size.width,
                    size.height,
                });
            },
            else => {},
        }
    }

    // while (pacer.shouldUpdate()) {
    // Fixed-rate simulation would run here. The triangle has no game state.
    // }

    window.glMakeContextCurrent(context);
    drawTriangle();
    window.glSwapBuffers();
    pacer.endFrame();
    return true;
}

fn initTriangle() void {
    state.bindings.vertex_buffers[0] = sg.makeBuffer(.{
        .data = sg.asRange(&[_]f32{
            0.0,  0.5,  0.5, 1.0, 0.0, 0.0, 1.0,
            0.5,  -0.5, 0.5, 0.0, 1.0, 0.0, 1.0,
            -0.5, -0.5, 0.5, 0.0, 0.0, 1.0, 1.0,
        }),
    });

    state.pipeline = sg.makePipeline(.{
        .shader = sg.makeShader(shd.triangleShaderDesc(sg.queryBackend())),
        .layout = init: {
            var layout = sg.VertexLayoutState{};
            layout.attrs[shd.ATTR_triangle_position].format = .FLOAT3;
            layout.attrs[shd.ATTR_triangle_color0].format = .FLOAT4;
            break :init layout;
        },
        .depth = .{
            .pixel_format = wio_sokol_gl.environment(gl_options).defaults.depth_format,
        },
    });
}

fn drawTriangle() void {
    logFps();

    sg.beginPass(.{
        .swapchain = wio_sokol_gl.swapchain(framebuffer_size, gl_options),
    });
    sg.applyPipeline(state.pipeline);
    sg.applyBindings(state.bindings);
    sg.draw(0, 3, 1);
    sg.endPass();
    sg.commit();
}

fn logFps() void {
    const now = std.Io.Clock.awake.now(io).toMilliseconds();
    if (fps_last_report_ms == null) fps_last_report_ms = now;

    fps_frame_count += 1;
    const elapsed_ms = now - fps_last_report_ms.?;
    if (elapsed_ms >= 1_000) {
        if (pacer.enabled == false) {
            const fps = @divTrunc(@as(i64, fps_frame_count) * 1_000, elapsed_ms);
            std.log.info("fps {d:.2}", .{fps});
            fps_frame_count = 0;
        } else {
            const stats = pacer.stats();
            const quality = pacer.quality();
            std.log.info("fps {d:.2} frame {d:.3}ms low1 {d:.1} dup {d:.3}% drift {d:.3}ms", .{
                stats.avg_fps,
                stats.avg_frame_time_s * 1_000.0,
                stats.low1_fps,
                quality.unexpected_duplicate_ratio * 100.0,
                quality.drift_seconds * 1_000.0,
            });
        }
        fps_last_report_ms = now;
    }
}

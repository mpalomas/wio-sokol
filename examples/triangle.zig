const std = @import("std");
const wio = @import("wio");
const sokol = @import("sokol");
const wio_sokol_gl = @import("wio_sokol_gl");
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

var debug_allocator = std.heap.DebugAllocator(.{}).init;
var allocator: std.mem.Allocator = undefined;
var threaded: std.Io.Threaded = undefined;
var io: std.Io = undefined;

var window: wio.Window = undefined;
var context: wio.GlContext = undefined;
var framebuffer_size: wio.Size = .{ .width = 640, .height = 480 };
var fps_last_report_ms: ?i64 = null;
var fps_frame_count: u32 = 0;

pub fn main() !void {
    allocator = debug_allocator.allocator();
    threaded = std.Io.Threaded.init(allocator, .{});
    io = threaded.io();

    try wio.init(allocator, io, .{});
    errdefer {
        wio.deinit();
        threaded.deinit();
        _ = debug_allocator.deinit();
    }

    window = try wio.createWindow(.{
        .title = "wio + sokol_gfx triangle",
        .scale = 1,
        .gl_options = gl_options,
    });
    errdefer window.destroy();

    context = try window.glCreateContext(.{ .options = gl_options });
    errdefer context.destroy();

    window.glMakeContextCurrent(&context);
    window.glSwapInterval(0);

    sg.setup(.{
        .environment = wio_sokol_gl.environment(gl_options),
        .logger = .{ .func = slog.func },
    });
    errdefer sg.shutdown();

    std.log.info("sokol backend: {}", .{sg.queryBackend()});

    initTriangle();

    try wio.run(loop);
}

fn loop() !bool {
    while (window.getEvent()) |event| {
        switch (event) {
            .close => {
                sg.shutdown();
                context.destroy();
                window.destroy();
                wio.deinit();
                threaded.deinit();
                _ = debug_allocator.deinit();
                return false;
            },
            .size_physical => |size| framebuffer_size = size,
            else => {},
        }
    }

    window.glMakeContextCurrent(&context);
    drawTriangle();
    window.glSwapBuffers();
    return true;
}

fn initTriangle() void {
    state.bindings.vertex_buffers[0] = sg.makeBuffer(.{
        .data = sg.asRange(&[_]f32{
            0.0, 0.5, 0.5, 1.0, 0.0, 0.0, 1.0,
            0.5, -0.5, 0.5, 0.0, 1.0, 0.0, 1.0,
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
        const fps = @divTrunc(@as(i64, fps_frame_count) * 1_000, elapsed_ms);
        std.log.info("fps {}", .{fps});
        fps_frame_count = 0;
        fps_last_report_ms = now;
    }
}

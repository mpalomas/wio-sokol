const wio = @import("wio");
const sg = @import("sokol").gfx;

pub fn environment(gl_options: wio.GlOptions) sg.Environment {
    return .{
        .defaults = .{
            .color_format = .RGBA8,
            .depth_format = depthFormat(gl_options),
            .sample_count = sampleCount(gl_options),
        },
    };
}

pub fn swapchain(size: wio.Size, gl_options: wio.GlOptions) sg.Swapchain {
    return .{
        .width = size.width,
        .height = size.height,
        .sample_count = sampleCount(gl_options),
        .color_format = .RGBA8,
        .depth_format = depthFormat(gl_options),
        .gl = .{
            .framebuffer = 0,
        },
    };
}

fn depthFormat(gl_options: wio.GlOptions) sg.PixelFormat {
    if (gl_options.depth_bits == 0) {
        return .NONE;
    }
    if (gl_options.stencil_bits == 0) {
        return .DEPTH;
    }
    return .DEPTH_STENCIL;
}

fn sampleCount(gl_options: wio.GlOptions) i32 {
    return if (gl_options.samples == 0) 1 else gl_options.samples;
}

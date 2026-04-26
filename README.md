# wio-sokol integration examples

This is a small repo showing off how to integrate sokol-zig with wio. Both are absolutely fantastic!

**But sokol_app exists?! why wio?**
- wio is pure zig (zig + system libs of course)
- wio allows to control vsync: turning vsync off, and choosing your exact target FPS in your main loop, is possible and entirely up to you

Still sokol_gfx is one of the best lean, modern GPU abstraction. It fits in the right place, support multiple backends, and is very small (code/binary size) compated to WebGPU implementations.

## Build

```sh
zig build -Doptimize=ReleaseSmall examples
```

## Run one example:

```sh
zig build -Doptimize=ReleaseSmall run-triangle
```

# Sokol-Like Frame Pacing Plan

## Goal

Design a simpler frame pacing API for `wio-sokol`, inspired by `sokol_app.h` after
the 02-Apr-2026 timing rewrite.

This plan is intentionally about presented frames, not fixed simulation ticks. The
current `FramePacer` in `src/frame_pacing.zig` already covers fixed-update
accumulation, interpolation, pacing stats, and frame caps. The proposed API should
instead answer three direct questions:

- What frame duration should the app use this frame?
- Does the app appear to be effectively vsynced?
- If the user asks for `60.0`, `120.0`, or another display-related rate, how do we
  pace presentation without fighting the real display cadence?

## Sokol Findings

Relevant local references:

- `/Users/mpalomas/dev/c++/sokol/CHANGELOG.md`, 02-Apr-2026.
- `/Users/mpalomas/dev/c++/sokol/CHANGELOG.md`, 20-Feb-2026 and 03-Mar-2026.
- `/Users/mpalomas/dev/c++/sokol/sokol_app.h`, `>>frame timing`.
- `/Users/mpalomas/dev/c++/sokol/sokol_app.h`, macOS Metal display-link code.

The 02-Apr-2026 Sokol change replaced the old moving-average filter with an
exponential moving average:

- clamp raw frame deltas to `[1us, 100ms]`;
- keep `dt` as the unfiltered, clamped duration;
- if `abs(dt - smooth_dt) > 4ms`, reset the filter to the new delta;
- otherwise update `ema = ema + 0.025 * (dt - ema)`;
- expose both filtered `sapp_frame_duration()` and unfiltered
  `sapp_frame_duration_unfiltered()`.

Sokol removed its D3D11/DXGI timestamp path because DXGI timing was unreliable in
too many real cases: obscured/minimized windows, externally-forced vsync-off, and
stale/useless timestamps. Windows now uses the same generic measured wall-clock
timing path as the other non-Apple backends.

macOS Metal is the exception. Since the 20-Feb-2026 change, Sokol uses
`CAMetalLayer` plus `CADisplayLink` on macOS 14+. The frame callback is driven by
`CADisplayLink`, and frame duration is computed from consecutive
`CADisplayLink.timestamp` values. Sokol does not EMA-filter that value because the
display-link timestamp is stable enough to use directly. When the display link is
not active, Sokol falls back to the generic measured+filtered timing path.

The 03-Mar-2026 macOS follow-up matters for lifecycle handling: on macOS 14,
invalidating `CADisplayLink` could crash in some occlusion/minimize cases, so
Sokol pauses and unpauses the display link instead. Sokol also uses a fallback
`NSTimer` at 60Hz while the window is minimized or fully obscured because
`CADisplayLink` stops firing there.

## Existing Project Context

`wio-extra` already exposes display refresh through `wiox.display`:

```zig
const display = wiox.display.getWindowDisplay(&window) orelse return;
const refresh = display.getRefreshRate();
```

`RefreshRate` carries both a float and, when available, an exact rational:

```zig
pub const RefreshRate = struct {
    hz: f64 = 0,
    numerator: u32 = 0,
    denominator: u32 = 0,
};
```

On macOS, `wio-extra` uses `CVDisplayLinkGetNominalOutputVideoRefreshPeriod` to
query the nominal refresh period. This is good for detecting rates such as
`120.0006Hz`.

The local `wio-extra` fork now also exposes a macOS 14+ `CADisplayLink` source:

```zig
var display_link = try window.createDisplayLink(.{
    .preferred_frame_rate_hz = clock.info().effective_hz,
});
display_link.start();
```

Display-link ticks are delivered as `.display_link` events carrying the display
timestamp and duration. `FrameClock.beginFrameWithDisplayLink()` consumes those
durations directly without EMA filtering. `wio-extra`'s macOS `wioWait()` now
runs the current run loop when no `NSEvent` is pending, so `CADisplayLink` wakes
the app without mouse or trackpad input.

## Implemented API

The presented-frame API lives in `src/sokol_pacing.zig` beside the existing
fixed-update pacer. `FrameClock` is intentionally separate from the current
accumulator-based `FramePacer`.

```zig
var clock = sokol_pacing.FrameClock.init(io, .{});
```

Configuration:

```zig
pub const FrameClockDesc = struct {
    smoothing: TimingSmoothing = .{ .sokol_ema = .{} },
    target: FrameTarget = .display,
    sleep_mode: SleepMode = .hybrid,
    vsync_probe_frames: u32 = 120,
    vsync_match_tolerance_ratio: f64 = 0.025,
    display_snap_tolerance_ratio: f64 = 0.005,
    passive_sleep_margin_ns: i64 = 1 * std.time.ns_per_ms,
    spin_threshold_ns: i64 = 200 * std.time.ns_per_us,
};

pub const FrameTarget = union(enum) {
    none,
    display,
    hz: f64,
    refresh_fraction: struct {
        numerator: u32,
        denominator: u32,
    },
};

pub const VsyncState = enum {
    unknown,
    likely_on,
    likely_off,
};
```

Core loop:

```zig
while (window.getEvent()) |event| switch (event) {
    .display_link => |frame| {
        clock.beginFrameWithDisplayLink(frame);
        draw();
        window.glSwapBuffers();
        clock.endFrame(&window);
    },
    .draw, .size_physical => {
        clock.beginFrame(); // measured fallback path
        draw();
        window.glSwapBuffers();
        clock.endFrame(&window);
    },
    else => {},
};
```

Queries:

```zig
pub fn frameDuration(self: *const FrameClock) f64;
pub fn frameDurationUnfiltered(self: *const FrameClock) f64;
pub fn observedFrameRate(self: *const FrameClock) f64;
pub fn displayRefreshRate(self: *const FrameClock) ?wiox.display.RefreshRate;
pub fn vsyncState(self: *const FrameClock) VsyncState;
pub fn isEffectivelyVsynced(self: *const FrameClock) bool;
pub fn presentationDecision(self: *const FrameClock) PresentationDecision;
```

Control:

```zig
pub fn setTargetHz(self: *FrameClock, hz: f64) void;
pub fn setTargetDisplay(self: *FrameClock) void;
pub fn setTargetRefreshFraction(self: *FrameClock, numerator: u32, denominator: u32) void;
pub fn setDisplayRefreshRate(self: *FrameClock, rate: wiox.display.RefreshRate) bool;
pub fn detectDisplayRefreshRate(self: *FrameClock, window: *wio.Window) bool;
pub fn resync(self: *FrameClock) void;
pub fn beginFrameWithDisplayLink(self: *FrameClock, frame: wio.DisplayLinkFrame) void;
```

Presentation decision:

```zig
pub const PresentationDecision = struct {
    requested_hz: f64,
    target_hz: f64,
    effective_hz: f64,
    display_hz: f64,
    present_this_frame: bool,
    repeat_count: u32,
    software_wait_s: f64,
};
```

For the current immediate-mode triangle, `present_this_frame` is always `true`.
`repeat_count` still records the display-derived cadence decision, for example
`60.0003Hz` as every other refresh on a `120.0006Hz` display.

## Timing Pipeline

Generic timing should match Sokol:

1. Use a monotonic clock.
2. Measure `now - last`.
3. Clamp to `[1us, 100ms]`.
4. Store the clamped value as `unfiltered_dt`.
5. If the new value differs from the current smooth value by more than `4ms`,
   reset EMA and smooth delta to the new value.
6. Otherwise apply `ema += 0.025 * (dt - ema)`.
7. Expose both filtered and unfiltered durations.

The implementation can keep nanoseconds internally, but the Sokol constants should
be represented exactly:

```zig
dt_min_ns = 1 * std.time.ns_per_us
dt_max_ns = 100 * std.time.ns_per_ms
reset_threshold_ns = 4 * std.time.ns_per_ms
alpha = 0.025
```

This should become the default smoothing mode. The current rolling average can
remain available, but the Sokol-like API should not default to it.

The macOS display-link path bypasses this filter:

1. `wio-extra` receives a `CADisplayLink` callback.
2. It computes `duration_s` from consecutive `CADisplayLink.timestamp` values,
   using `targetTimestamp - timestamp` for the first frame when available.
3. `FrameClock.beginFrameWithDisplayLink()` clamps the duration to the Sokol
   `[1us, 100ms]` range, stores it as both raw and filtered duration, resets the
   EMA state to that value, and marks the clock as `likely_on`.

## Vsync Detection

There is no portable, reliable "is vsync currently active" query in this stack.
The first API should infer effective vsync from observed frame intervals.

Algorithm:

1. Detect the window display with `wiox.display.getWindowDisplay(window)`.
2. Convert the refresh rate to an exact `f64`, preferring `numerator/denominator`.
3. Collect a rolling window of post-present frame durations, for example 120
   samples after warmup.
4. Use unfiltered clamped deltas for classification, not EMA-smoothed deltas.
5. For each sample, find the nearest display multiple:
   `period * round(sample / period)`.
6. Count samples that land within `vsync_match_tolerance_ratio`, initially `2.5%`,
   of a display multiple.
7. Classify as `likely_on` when enough samples, for example `85%`, match display
   multiples and the observed average rate is near `display_hz / integer`.
8. Classify as `likely_off` when enough samples exist but the cadence is not near
   display multiples or is clearly faster than the display.

Examples:

- 120Hz display, vsync on, render every refresh: samples near `8.333ms`,
  `likely_on`.
- 120Hz display, vsync on, app effectively 60Hz: samples near `16.666ms`,
  `likely_on`, divisor `2`.
- 60Hz nominal display reporting `59.95Hz`, target `60.0`: treat as display
  matched because the requested rate is within snap tolerance.
- Vsync off, loop runs at 3000fps: samples much smaller than display period,
  `likely_off`.

Classification should be exposed as a diagnosis, not as a hard guarantee. Driver
control panels, compositor policy, VRR, and minimized windows can all change the
effective behavior.

## Target Rate Resolution

The key rule is that user-friendly rates should snap to the physical display when
they are close enough.

```zig
fn resolveTargetHz(requested_hz: f64, display_hz: ?f64) ResolvedTarget
```

Rules:

- If no display rate is known, use `requested_hz`.
- If `requested_hz` is within `0.5%` of `display_hz / n` or `display_hz * n` for a
  small integer `n`, prefer the exact display-derived rate.
- For `requested_hz = 60.0` and `display_hz = 59.95`, target `59.95`.
- For `requested_hz = 60.0` and `display_hz = 119.92`, target `59.96` with
  `repeat_count = 2`.
- For `requested_hz = 120.0` and `display_hz = 119.92`, target `119.92`.
- For `requested_hz = 30.0` and `display_hz = 119.92`, target `29.98` with
  `repeat_count = 4`.

This produces an explicit distinction:

- `requested_hz`: what the user asked for.
- `effective_hz`: the snapped rate we intend to present.
- `display_hz`: the detected display rate.
- `repeat_count`: how many display refreshes one rendered image should cover.

For the macOS display-link path, `repeat_count` is expressed by the display-link
preferred frame rate: a `60.0003Hz` target on a `120.0006Hz` display produces one
callback every two refreshes. On platforms without a native display callback,
`repeat_count` remains a scheduling/reporting hint that can guide future retained
rendering or redraw skipping.

## Pacing Strategy

Use two different strategies depending on effective vsync.

When vsync is likely on:

- Prefer swap-interval/display pacing.
- Do not software-sleep to the same display boundary before `SwapBuffers`, because
  that risks missing the compositor/display deadline and adds jitter.
- Use the measured post-present duration as the frame duration.
- If target is a divisor of display rate, allow rendering every display callback
  but expose `repeat_count`, or later skip redraw work on non-presented logical
  frames.

When vsync is likely off:

- Use software pacing after rendering/presenting, as the current `FramePacer` does.
- Sleep until the next target deadline, with a hybrid sleep/spin mode.
- Keep an absolute `next_present_ns` schedule instead of sleeping relative to the
  current time only. This prevents small overshoots from permanently lowering FPS.
- If the app misses a deadline by more than one target period, resync to `now`.

Deadline update:

```zig
next_present_ns += target_period_ns;
if (now_ns > next_present_ns + target_period_ns) {
    next_present_ns = now_ns + target_period_ns;
}
```

Hybrid wait:

- sleep while `remaining > passive_margin`;
- spin/yield for the final interval;
- default `passive_margin = 1ms`, but document that macOS may need `2ms` for
  tighter software caps.

## macOS Plan

There are two macOS support levels. Both are implemented in the local workspace.

### Phase 1: Current wio OpenGL Path

For the measured OpenGL fallback path:

- continue using `window.glSwapInterval(1)` to enable display pacing;
- use `wiox.display.getWindowDisplay()` and `Display.getRefreshRate()` for nominal
  refresh;
- infer effective vsync from measured post-`glSwapBuffers()` frame intervals;
- use Sokol EMA for generic frame duration;
- resolve requested rates against the detected display rate;
- avoid software sleeping when the observed cadence is already vsync-like.

This path remains useful for Linux/Win32, macOS versions without `CADisplayLink`,
and fallback redraws such as resize or explicit `.draw` events.

### Phase 2: Native Display-Link Source

To match Sokol’s macOS behavior more closely, `wio-extra` now has a macOS timing
source for macOS 14+:

```zig
pub const DisplayLinkOptions = struct {
    preferred_frame_rate_hz: f64 = 0,
};

pub const DisplayLinkFrame = struct {
    timestamp_s: f64,
    duration_s: f64,
};

var display_link = try window.createDisplayLink(.{
    .preferred_frame_rate_hz = clock.info().effective_hz,
});
display_link.start();
```

Implementation details:

- Prefer `-[NSView displayLinkWithTarget:selector:]`, as Sokol does.
- Set `preferredFrameRateRange` to the resolved target rate when available.
- Use consecutive `CADisplayLink.timestamp` values as the authoritative frame
  duration.
- Do not EMA-filter display-link deltas.
- `DisplayLink.stop()` pauses and resets timing instead of invalidating.
- `DisplayLink.destroy()` invalidates for final cleanup.
- `wioWait()` runs the AppKit run loop when no pending `NSEvent` exists, so
  `CADisplayLink` callbacks wake the app continuously.
- When the window is minimized or fully obscured, expect `CADisplayLink` to stop.
  A fallback `NSTimer` like Sokol's is still a possible future addition.

This phase belongs in `wio-extra` because the callback source must be integrated
with the native AppKit run loop and window/view objects.

## Linux Plan

Linux should use generic Sokol-style measured timing:

- X11/GLX: `glXSwapIntervalEXT/MESA/SGI` controls vsync when available. Timing is
  measured around the loop and classified by observed cadence.
- Wayland/EGL: `eglSwapInterval` may be compositor-mediated. Treat it as a request,
  not a guarantee.
- Do not depend on platform presentation timestamps for the first version.
- Use `wiox.display` refresh rates:
  - Wayland reports millihertz and reduces the rational.
  - X11 should use the existing display module’s current mode data.
- Vsync detection is especially important because compositor behavior may differ
  across desktops.

Software pacing on Linux should use the absolute-deadline hybrid wait path when
vsync is likely off. For GL with vsync on, avoid adding software sleeps.

## Win32 Plan

Windows should also use generic Sokol-style measured timing:

- Do not use DXGI frame statistics for the first version. Sokol removed its DXGI
  timing path because it was not reliable enough.
- D3D11 `Present(sync_interval, flags)` and WGL swap interval are presentation
  controls, but actual effective vsync can be overridden externally.
- Use `QueryPerformanceCounter` indirectly through Zig/std monotonic time unless
  profiling shows a problem.
- Use `wiox.display` refresh rates from `QueryDisplayConfig` where available.
- Infer vsync from observed frame intervals.

If vsync is likely off, use software pacing with an absolute deadline. If vsync is
likely on, let `Present`/`SwapBuffers` block.

## Integration With `triangle.zig`

The current macOS display-link version is structured like this:

```zig
var clock = sokol_pacing.FrameClock.init(io, .{
    .target = .{ .hz = 60.0 },
});
_ = clock.detectDisplayRefreshRate(&window);

window.glSwapInterval(1);
var display_link = try window.createDisplayLink(.{
    .preferred_frame_rate_hz = clock.info().effective_hz,
});
display_link.start();

fn loop() !bool {
    var should_draw = false;
    var has_display_link_timing = false;
    while (window.getEvent()) |event| {
        switch (event) {
            .display_link => |frame| {
                clock.beginFrameWithDisplayLink(frame);
                should_draw = true;
                has_display_link_timing = true;
            },
            .draw, .size_physical => should_draw = true,
            else => {},
        }
    }
    if (!should_draw) {
        wio.wait(.{});
        return true;
    }
    if (!has_display_link_timing) clock.beginFrame();
    draw();
    window.glSwapBuffers();
    clock.endFrame(&window);
    return true;
}
```

Log once per second:

```zig
const info = clock.info();
std.log.info(
    "fps {d:.2} dt {d:.3}ms raw {d:.3}ms display {d:.4}Hz vsync {} repeat {}",
    .{
        counted_fps,
        info.frame_duration_s * 1000.0,
        info.unfiltered_frame_duration_s * 1000.0,
        info.display_hz,
        info.vsync_state,
        info.repeat_count,
    },
);
```

## Implementation Steps

1. Done: add `FrameClock` with Sokol EMA timing and unfiltered duration.
2. Done: add display refresh detection and target-rate resolution.
3. Done: add vsync classification from a rolling window of unfiltered frame
   durations.
4. Done: add absolute-deadline software pacing for `likely_off` or explicit
   software-cap mode.
5. Done: update `triangle.zig` to use `FrameClock` for logs and rate selection.
6. Done: keep the existing `FramePacer` API intact.
7. Done: add a `wio-extra` macOS `CADisplayLink` source and integrate it into
   `triangle.zig`.

## Implementation Progress

- Phase 1, source review: done. Checked the existing `FramePacer`, build module
  wiring, `triangle.zig`, `wio-extra` display refresh API, and Sokol's current
  timing implementation.
- Phase 2, `sokol_pacing.zig`: done. Added `FrameClock`, Sokol-style EMA timing,
  unfiltered duration, display refresh detection, target-rate resolution,
  inferred vsync state, early detection for obviously free-running vsync-off
  loops, presentation decisions, and absolute-deadline software pacing for
  likely-vsync-off cases.
- Phase 3, build/example wiring: done. Added the `sokol_pacing` build module and
  exposed it from `src/root.zig`.
- Phase 4, macOS display-link support: done in the local `wio-extra` fork.
  `Window.createDisplayLink()` creates a macOS 14+ `CADisplayLink` source,
  `.display_link` events carry `timestamp_s` and `duration_s`,
  `DisplayLink.nextFrame()` exposes the latest frame, `stop()` pauses/resets
  timing, and `destroy()` invalidates for final cleanup.
- Phase 5, triangle integration: done. `examples/triangle.zig` creates a display
  link with `preferred_frame_rate_hz = clock.info().effective_hz` on macOS,
  renders from `.display_link` events, feeds those frames to
  `FrameClock.beginFrameWithDisplayLink()`, and keeps measured timing for
  resize/explicit draw fallback events. Non-macOS builds do not call
  `Window.createDisplayLink()` and use the measured loop instead.
- Phase 6, macOS wait-loop fix: done in `wio-extra`. `wioWait()` now runs the
  current AppKit run loop when no `NSEvent` is pending, so `CADisplayLink`
  callbacks wake the app without mouse/trackpad input.
- Phase 7, tests and verification: done for unit/example build coverage.
  `zig build test`, `zig build --fork=/Users/mpalomas/dev/zig/wio-extra test`,
  and `zig build --fork=/Users/mpalomas/dev/zig/wio-extra examples` pass.

Observed macOS result on a `120.0006Hz` display with requested `60.0Hz`:

```text
frame clock display rate: 120.0006Hz target 60.0003Hz repeat 2
macOS display link started at preferred 60.0003Hz
frame/raw duration: ~16.667ms
vsync: likely_on
software wait: 0.000ms
```

This is the expected stable path: the requested `60.0Hz` snaps to exactly half of
the detected display rate, `CADisplayLink` drives frame callbacks, display-link
durations bypass EMA filtering, and no software sleep is applied.

## Tests

Current unit tests cover:

- Sokol EMA behavior: clamp, reset threshold, alpha update, unfiltered value.
- Target resolution:
  - `60.0` against `59.95` resolves to `59.95`;
  - `60.0` against `119.92` resolves to `59.96` and repeat `2`;
  - `120.0` against `119.92` resolves to `119.92`;
  - unknown display keeps requested rate.
- Vsync classifier:
  - stable display-period samples classify as `likely_on`;
  - stable two-period samples classify as `likely_on` with divisor `2`;
  - very short/free-running samples classify as `likely_off`;
  - insufficient samples classify as `unknown`.
- Display-link frames bypass EMA filtering and mark timing as `likely_on`.

Remaining useful unit coverage:

- Software deadline pacing keeps an absolute schedule and resyncs after large
  misses. The implementation exists, but timing-sensitive sleep behavior is
  currently verified manually.

Manual tests:

```sh
zig build test
zig build --fork=/Users/mpalomas/dev/zig/wio-extra test
zig build --fork=/Users/mpalomas/dev/zig/wio-extra examples
zig build --fork=/Users/mpalomas/dev/zig/wio-extra -Doptimize=ReleaseSmall run-triangle
```

Manual scenarios:

- macOS display-link path, target `60.0` on a 120Hz display. Expected:
  `target ~= display / 2`, `repeat 2`, `~16.667ms`, `likely_on`, no software wait.
- macOS display-link path should continue logging without mouse or trackpad input.
- macOS measured fallback path for resize/explicit draw events.
- Linux/Win32 portability: `triangle.zig` gates the display-link path with
  `builtin.os.tag == .macos`; other targets use the measured `FrameClock` path.
- macOS OpenGL, `glSwapInterval(0)`, target `60.0`, software pacing. This needs a
  small example toggle because the current triangle defaults to the display-link
  path.
- Linux X11/Wayland with vsync on and off where the driver/compositor permits it.
- Win32 WGL/D3D with default vsync and with driver-forced vsync off.

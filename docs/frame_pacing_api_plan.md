# Frame Pacing API Plan

## Goal

Add a robust frame pacing module for manual game loops using `wio` and `sokol_gfx`.
The module owns timing, fixed-update accumulation, optional frame caps, display-rate
snapping, smoothing, reset hooks, and pacing-quality metrics. Rendering remains
owned by the application.

## API Shape

The module lives at `src/frame_pacing.zig` and is exposed as the build import
`frame_pacing`.

Primary type:

```zig
var pacer = frame_pacing.FramePacer.init(io, .{
    .tick_rate_hz = 60.0,
    .mode = .unlocked,
    .frame_cap_hz = 0.0,
});
_ = pacer.detectDisplayRefreshRate(&window);
```

Main-loop usage:

```zig
pacer.beginFrame();
while (window.getEvent()) |event| {
    // Handle events.
}
while (pacer.shouldUpdate()) {
    update(pacer.fixedDt());
}
render(pacer.interpolationAlpha());
present();
pacer.endFrame();
```

Important configuration:

- `Mode.locked` runs either zero updates or exactly `update_multiplicity` updates
  once enough time has accumulated.
- `Mode.unlocked` drains the accumulator in fixed steps and exposes a fractional
  interpolation alpha for rendering.
- `Smoothing.rolling` is the default and uses a 4-sample integer rolling average
  with residual correction.
- `Smoothing.ema` matches Sokol's current timing filter defaults: `alpha = 0.025`,
  `4ms` reset threshold, `1us` minimum delta, and `100ms` maximum delta.
- `SleepMode.hybrid` sleeps passively for most of the remaining cap interval and
  spins for the final short interval.

## Public API Reference

Configuration types:

- `Mode.locked`: run zero updates or exactly `update_multiplicity` updates once
  enough time accumulates.
- `Mode.unlocked`: drain all available fixed updates and use
  `interpolationAlpha()` for render interpolation.
- `SleepMode.none`: no cap wait.
- `SleepMode.passive`: only `std.Io.sleep`; low CPU, lower precision.
- `SleepMode.hybrid`: passive sleep plus final spin; recommended software cap.
- `SleepMode.spin`: busy-wait only; useful for diagnostics, high CPU cost.
- `Smoothing.none`: no delta filtering.
- `Smoothing.rolling`: deterministic rolling average with residual correction.
- `Smoothing.ema`: Sokol-style exponential moving average.

`Desc` fields:

- `tick_rate_hz`: fixed simulation update rate. Defaults to `60.0`.
- `mode`: locked or unlocked update scheduling. Defaults to `.locked`.
- `update_multiplicity`: locked-mode update count. Defaults to `1`.
- `vsync_snap`: enables snapping to detected display harmonics. Defaults to `true`.
- `smoothing`: delta filter. Defaults to 4-sample rolling average.
- `snap_tolerance_ns`: harmonic snap tolerance. Defaults to `200us`.
- `frame_cap_hz`: software frame cap; `0` disables. Defaults to `0`.
- `sleep_mode`: cap wait strategy. Defaults to `.hybrid`.
- `passive_sleep_margin_ns`: initial/floor spin margin before deadline. Defaults
  to `1ms`.
- `spin_threshold_ns`: minimum final spin interval. Defaults to `200us`.

`FramePacer` lifecycle and loop functions:

- `init(io, desc)`: create a pacer.
- `beginFrame()`: measure/snap/smooth frame time and prepare updates.
- `shouldUpdate()`: consume one fixed update when available.
- `endFrame()`: record quality metrics and enforce the software cap.
- `resync()`: clear timing discontinuities without clearing stats.
- `resetStats()`: clear frame-time statistics.
- `resetPacingStats()`: clear duplicate/catch-up/drift counters.
- `resetAll()`: reset timing, frame-time stats, and pacing stats.

Timing and control functions:

- `fixedDt()`: fixed update step in seconds.
- `frameDt()`: smoothed/snapped frame delta in seconds.
- `rawDt()`: measured raw frame delta in seconds.
- `interpolationAlpha()`: accumulator remainder for unlocked render interpolation.
- `fps()`: instantaneous FPS from smoothed frame delta.
- `tickRate()`: current fixed update rate in Hz.
- `updateCount()`: fixed updates available for the current frame.
- `setTickRate(hz)`: change fixed update rate and resync.
- `setFrameCap(hz)`: set or disable software frame cap.
- `setDisplayRefreshRate(rate)`: manually set display refresh for snapping.
- `detectDisplayRefreshRate(window)`: query wio-extra display refresh.
- `capToDisplay(window)`: detect display refresh and use it as frame cap.
- `syncTickRateToDisplay(window)`: detect display refresh and use it as tick rate.

Metric snapshots:

- `stats()`: average FPS, average frame time, low 1%, low 0.1%, worst frame time,
  frame-time stddev, and sample count.
- `quality()`: frame/update counts, duplicate/catch-up counts, drift, and display Hz.

## Timing Pipeline

Each `beginFrame()`:

1. Reads `std.Io.Clock.awake`.
2. Clamps negative deltas to zero and anomalous deltas above `8x` desired frame
   time to one desired frame.
3. Records the raw delta in a fixed 300-sample stats ring.
4. Snaps the delta to display refresh harmonics `1x..8x` when display refresh is
   known and the measured delta is within tolerance.
5. Smooths the delta with the selected smoother.
6. Adds the smoothed delta to the fixed-update accumulator.
7. Clears runaway accumulator growth above `8x` desired frame time.
8. Precomputes how many fixed updates are available this frame.

All internal timing is integer nanoseconds. Public durations and rates are
converted to `f64` seconds or Hz at API boundaries.

## Display And Sleep

Display refresh is discovered through `wiox.display.getWindowDisplay(window)` and
`Display.getRefreshRate()`. Exact rational rates are preferred when available;
otherwise the floating-point `hz` value is used. Direct vsync state is not queried;
the pacer infers effective vsync behavior from frame timings and exposes quality
metrics for drift, duplicates, and catch-up frames.

Frame capping uses `std.Io.sleep` and a final spin phase. `wio.wait()` is not used
for precise pacing because current backends are event-pump oriented and some paths
quantize to milliseconds.

## Metrics And Resets

`stats()` returns average FPS, average frame time, low 1%, low 0.1%, worst frame
time, standard deviation, and sample count.

`quality()` returns total frames, total fixed updates, duplicate frames, catch-up
frames, max duplicate streak, duplicate ratios, display rate, and drift.

Reset methods:

- `resync()` clears timing discontinuities and accumulator state.
- `resetStats()` clears frame-time stats only.
- `resetPacingStats()` clears duplicate/catch-up/drift counters only.
- `resetAll()` combines all reset paths for scene loads or major transitions.

## Observations: macOS VRR Displays

MacBook Pro displays support variable refresh rate behavior, so observed frame
durations can vary even when the display reports a nominal refresh rate such as
`120Hz`. On these displays, frame pacing metrics should distinguish simulation
drift from presentation phase error.

The current `drift_seconds` metric is update-based:

```zig
wall_clock_elapsed - (total_fixed_updates * fixed_dt)
```

This is useful for understanding how far committed simulation updates lag or lead
wall time, but it ignores the accumulator remainder in `.unlocked` mode. With a
`60Hz` fixed update rate and a render loop near `120Hz`, this value can accumulate
positively if the loop produces slightly fewer than 60 committed updates per wall
second, even when interpolation still makes presentation look smooth.

The API should expose two drift metrics:

- `update_drift_seconds`: current committed-update metric.
- `presentation_drift_seconds`: accumulator-aware metric computed as
  `wall_clock_elapsed - (total_fixed_updates * fixed_dt + accumulator)`.

For `.unlocked` mode on macOS VRR displays, `presentation_drift_seconds` is the
primary quality metric. `update_drift_seconds` remains useful for simulation lag
diagnostics.

Frame caps should also avoid hard-coding `120.0Hz` on these displays. Prefer
`capToDisplay(window)` when using a software cap, because wio-extra can return an
exact rational refresh rate such as `120.0006Hz`. If relying on the display
pipeline instead, test with the software frame cap disabled and vsync enabled.

Software frame caps on macOS show measurable wake-up overshoot. A `60Hz` cap
targets `16.667ms`, but default hybrid sleep can stabilize around `59.0fps`
(`~16.95ms`, roughly `0.25-0.30ms` late per frame). Raising
`passive_sleep_margin_ns` from `1ms` to `2ms` improves this to roughly `59.5fps`
(`~16.81ms`, roughly `0.14ms` late per frame), at the cost of more active
spinning. This is expected for `std.Io.sleep`/`nanosleep`-style waits on macOS:
if the kernel wakes the thread late, the final spin phase cannot recover the
missed time.

## Verification

Unit tests cover locked/unlocked update behavior, vsync snapping, rolling residual
correction, EMA behavior, spiral protection, stats, quality metrics, and reset
semantics.

Manual verification uses:

```sh
zig build test
zig build -Doptimize=ReleaseSmall run-triangle
```

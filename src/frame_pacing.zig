const std = @import("std");
const wio = @import("wio");
const wiox = @import("wiox");

comptime {
    _ = wio;
}

const max_harmonics = 8;
const spiral_threshold = 8;
const stats_window = 300;
const max_rolling_window = 16;

/// Fixed-update scheduling mode.
pub const Mode = enum {
    /// Run either zero updates or exactly `update_multiplicity` updates when
    /// enough time has accumulated. This is simple and deterministic, but can
    /// duplicate rendered state when update and presentation rates differ.
    locked,
    /// Drain the accumulator in fixed-size update steps and expose the leftover
    /// fraction through `interpolationAlpha()`. Prefer this when render and
    /// simulation rates may differ.
    unlocked,
};

/// Strategy used by `endFrame()` when enforcing `frame_cap_hz`.
pub const SleepMode = enum {
    /// Do not sleep or spin. The frame cap is effectively disabled.
    none,
    /// Use only `std.Io.sleep`. Lowest CPU cost, lowest precision.
    passive,
    /// Sleep for the coarse part of the wait, then spin until the deadline.
    /// This is the recommended software frame-cap mode.
    hybrid,
    /// Busy-wait until the deadline. Highest precision, high CPU/battery cost.
    spin,
};

/// Rolling-average smoothing settings.
pub const RollingConfig = struct {
    /// Number of frame deltas to average. Values are clamped to `1...16`.
    window: u8 = 4,
};

/// Exponential moving average smoothing settings, matching Sokol defaults.
pub const EmaConfig = struct {
    /// EMA coefficient. Lower is smoother; higher reacts faster.
    alpha: f64 = 0.025,
    /// If the new sample differs from the smoothed value by more than this,
    /// reset the filter to the new sample instead of blending.
    reset_threshold_ns: i64 = 4 * std.time.ns_per_ms,
    /// Minimum accepted delta before filtering.
    min_dt_ns: i64 = 1 * std.time.ns_per_us,
    /// Maximum accepted delta before filtering.
    max_dt_ns: i64 = 100 * std.time.ns_per_ms,
};

/// Frame delta smoothing strategy.
pub const Smoothing = union(enum) {
    /// Use measured/snapped deltas directly.
    none,
    /// Use a rolling average with integer residual correction to prevent drift.
    rolling: RollingConfig,
    /// Use a Sokol-style exponential moving average.
    ema: EmaConfig,
};

/// Frame pacer configuration. Zero/default initialization gives a 60Hz locked
/// pacer with rolling smoothing, vsync snapping enabled, no frame cap, and
/// hybrid sleep if a cap is later configured.
pub const Desc = struct {
    /// Fixed simulation update rate in Hz. Invalid values fall back to 60Hz.
    tick_rate_hz: f64 = 60.0,
    /// Fixed-update scheduling mode.
    mode: Mode = .locked,
    /// Number of updates to run per eligible frame in `.locked` mode.
    update_multiplicity: u32 = 1,
    /// Snap measured deltas to display refresh harmonics when a display rate is known.
    vsync_snap: bool = true,
    /// Delta smoothing mode.
    smoothing: Smoothing = .{ .rolling = .{} },
    /// Maximum difference from a display harmonic for vsync snapping.
    snap_tolerance_ns: i64 = 200 * std.time.ns_per_us,
    /// Software frame cap in Hz. `0` disables the cap.
    frame_cap_hz: f64 = 0.0,
    /// Sleep/spin strategy used by `endFrame()` when the frame cap is active.
    sleep_mode: SleepMode = .hybrid,
    /// Initial/floor margin before the cap deadline reserved for spinning.
    passive_sleep_margin_ns: i64 = 1 * std.time.ns_per_ms,
    /// Minimum spin-only interval near the cap deadline.
    spin_threshold_ns: i64 = 200 * std.time.ns_per_us,
};

/// Frame-time statistics over the pacer's fixed-size stats window.
pub const Stats = struct {
    /// Average rendered frames per second.
    avg_fps: f64 = 0,
    /// Average raw frame duration in seconds.
    avg_frame_time_s: f64 = 0,
    /// FPS computed from the average of the worst 1% frame durations.
    low1_fps: f64 = 0,
    /// FPS computed from the average of the worst 0.1% frame durations.
    low01_fps: f64 = 0,
    /// Average duration of the worst 1% frames, in seconds.
    low1_frame_time_s: f64 = 0,
    /// Average duration of the worst 0.1% frames, in seconds.
    low01_frame_time_s: f64 = 0,
    /// Worst raw frame duration seen since init or `resetStats()`.
    worst_frame_time_s: f64 = 0,
    /// Standard deviation of raw frame durations in seconds.
    frame_time_stddev_s: f64 = 0,
    /// Number of valid samples in the stats window.
    sample_count: u32 = 0,
};

/// Pacing-quality metrics.
pub const Quality = struct {
    /// Total frames processed by `beginFrame()`.
    total_frames: u64 = 0,
    /// Total fixed updates consumed by `shouldUpdate()`.
    total_updates: u64 = 0,
    /// Frames where zero fixed updates ran.
    zero_update_frames: u64 = 0,
    /// Frames where more than one fixed update ran.
    multi_update_frames: u64 = 0,
    /// Longest consecutive run of zero-update frames.
    max_zero_update_streak: u32 = 0,
    /// Raw duplicate ratio: `zero_update_frames / total_frames`.
    duplicate_ratio: f64 = 0,
    /// Duplicate ratio expected from a lower tick rate than display rate.
    expected_duplicate_ratio: f64 = 0,
    /// Duplicate ratio above the expected rate.
    unexpected_duplicate_ratio: f64 = 0,
    /// Committed-update drift: wall time minus `total_updates * fixed_dt`.
    /// In `.unlocked` mode this intentionally ignores the accumulator remainder.
    drift_seconds: f64 = 0,
    /// Detected display refresh rate, or zero if unknown.
    display_rate_hz: f64 = 0,
};

/// Stateful frame pacer for a manual game/render loop.
pub const FramePacer = struct {
    enabled: bool = true,
    io: std.Io,
    mode: Mode,
    update_multiplicity: u32,
    vsync_snap: bool,
    smoothing: Smoothing,
    snap_tolerance_ns: i64,
    sleep_mode: SleepMode,
    passive_sleep_margin_ns: i64,
    spin_threshold_ns: i64,

    desired_frame_ns: i64,
    previous_ns: i64,
    frame_start_ns: i64,
    start_ns: i64,
    updates_at_reset: u64,

    display_rate_hz: f64 = 0,
    snap_ns: [max_harmonics]i64 = .{0} ** max_harmonics,

    rolling_history: [max_rolling_window]i64 = .{0} ** max_rolling_window,
    rolling_window: u8 = 4,
    rolling_residual: i64 = 0,
    ema_ns: f64 = 0,
    smooth_frame_ns: i64 = 0,

    accumulator_ns: i64 = 0,
    raw_frame_ns: i64 = 0,
    frame_delta_ns: i64 = 0,
    updates_this_frame: u32 = 0,
    update_counter: u32 = 0,

    frame_cap_hz: f64 = 0,
    frame_cap_ns: i64 = 0,

    total_frames: u64 = 0,
    total_updates: u64 = 0,
    zero_update_frames: u64 = 0,
    multi_update_frames: u64 = 0,
    current_zero_streak: u32 = 0,
    max_zero_update_streak: u32 = 0,

    frame_durations: [stats_window]i64 = .{0} ** stats_window,
    frame_duration_count: u32 = 0,
    frame_duration_index: u32 = 0,
    worst_frame_duration_ns: i64 = 0,

    /// Initialize a frame pacer from a descriptor.
    pub fn init(io: std.Io, desc: Desc) FramePacer {
        const now = nowNs(io);
        var pacer = FramePacer{
            .io = io,
            .mode = desc.mode,
            .update_multiplicity = if (desc.update_multiplicity == 0) 1 else desc.update_multiplicity,
            .vsync_snap = desc.vsync_snap,
            .smoothing = desc.smoothing,
            .snap_tolerance_ns = if (desc.snap_tolerance_ns > 0) desc.snap_tolerance_ns else 200 * std.time.ns_per_us,
            .sleep_mode = desc.sleep_mode,
            .passive_sleep_margin_ns = @max(desc.passive_sleep_margin_ns, 0),
            .spin_threshold_ns = @max(desc.spin_threshold_ns, 0),
            .desired_frame_ns = hzToNs(desc.tick_rate_hz),
            .previous_ns = now,
            .frame_start_ns = now,
            .start_ns = now,
            .updates_at_reset = 0,
        };
        pacer.configureSmoothing(desc.smoothing);
        pacer.setFrameCap(desc.frame_cap_hz);
        return pacer;
    }

    /// Begin a new frame: measure elapsed time, snap/smooth it, update the
    /// accumulator, and precompute how many fixed updates are available.
    pub fn beginFrame(self: *FramePacer) void {
        if (self.enabled == false) return;
        const now = nowNs(self.io);
        const delta = now - self.previous_ns;
        self.beginFrameWithDelta(delta);
        self.previous_ns = now;
        self.frame_start_ns = now;
    }

    /// Return true while a fixed simulation update should run.
    /// Each true result consumes one fixed timestep from the accumulator.
    pub fn shouldUpdate(self: *FramePacer) bool {
        if (self.enabled == false) return false;
        switch (self.mode) {
            .unlocked => {
                if (self.accumulator_ns >= self.desired_frame_ns) {
                    self.accumulator_ns -= self.desired_frame_ns;
                    self.update_counter += 1;
                    self.total_updates += 1;
                    return true;
                }
                return false;
            },
            .locked => {
                if (self.update_counter < self.updates_this_frame) {
                    self.accumulator_ns -= self.desired_frame_ns;
                    self.update_counter += 1;
                    self.total_updates += 1;
                    return true;
                }
                return false;
            },
        }
    }

    /// Finish a frame: record pacing quality and enforce the configured frame cap.
    pub fn endFrame(self: *FramePacer) void {
        if (self.enabled == false) return;
        self.recordPacingQuality();
        self.sleepToFrameCap();
    }

    /// Fixed simulation timestep in seconds.
    pub fn fixedDt(self: *const FramePacer) f64 {
        return nsToSeconds(self.desired_frame_ns);
    }

    /// Smoothed/snapped frame delta in seconds.
    pub fn frameDt(self: *const FramePacer) f64 {
        return nsToSeconds(self.frame_delta_ns);
    }

    /// Raw measured frame delta in seconds before snapping and smoothing.
    pub fn rawDt(self: *const FramePacer) f64 {
        return nsToSeconds(self.raw_frame_ns);
    }

    /// Fractional accumulator remainder for render interpolation.
    /// Always returns zero in `.locked` mode.
    pub fn interpolationAlpha(self: *const FramePacer) f64 {
        if (self.mode == .locked or self.desired_frame_ns <= 0) return 0;
        return @as(f64, @floatFromInt(self.accumulator_ns)) / @as(f64, @floatFromInt(self.desired_frame_ns));
    }

    /// Instantaneous FPS from the current smoothed frame delta.
    pub fn fps(self: *const FramePacer) f64 {
        const dt = self.frameDt();
        return if (dt > 0) 1.0 / dt else 0;
    }

    /// Current fixed update rate in Hz.
    pub fn tickRate(self: *const FramePacer) f64 {
        return nsToHz(self.desired_frame_ns);
    }

    /// Number of fixed updates available for the current frame.
    pub fn updateCount(self: *const FramePacer) u32 {
        return self.updates_this_frame;
    }

    /// Change fixed update rate and resync timing state.
    pub fn setTickRate(self: *FramePacer, hz: f64) void {
        if (!std.math.isFinite(hz) or hz <= 0) return;
        self.desired_frame_ns = hzToNs(hz);
        self.resetTimingState(nowNs(self.io));
    }

    /// Set software frame cap in Hz. `0` disables the cap.
    pub fn setFrameCap(self: *FramePacer, hz: f64) void {
        if (!std.math.isFinite(hz) or hz <= 0) {
            self.frame_cap_hz = 0;
            self.frame_cap_ns = 0;
            return;
        }
        self.frame_cap_hz = hz;
        self.frame_cap_ns = hzToNs(hz);
    }

    /// Set display refresh rate used by vsync snapping.
    /// Returns false when the rate is unknown or invalid.
    pub fn setDisplayRefreshRate(self: *FramePacer, rate: wiox.display.RefreshRate) bool {
        const hz = refreshRateHz(rate);
        if (hz <= 0) {
            self.display_rate_hz = 0;
            self.snap_ns = .{0} ** max_harmonics;
            return false;
        }
        self.display_rate_hz = hz;
        self.computeSnapHarmonics();
        return true;
    }

    /// Detect refresh rate for the display containing `window`.
    pub fn detectDisplayRefreshRate(self: *FramePacer, window: *wio.Window) bool {
        const display = wiox.display.getWindowDisplay(window) orelse return false;
        defer display.release();
        return self.setDisplayRefreshRate(display.getRefreshRate());
    }

    /// Detect display refresh and use it as the software frame cap.
    pub fn capToDisplay(self: *FramePacer, window: *wio.Window) bool {
        if (!self.detectDisplayRefreshRate(window)) return false;
        self.setFrameCap(self.display_rate_hz);
        return true;
    }

    /// Detect display refresh and use it as the fixed update rate.
    pub fn syncTickRateToDisplay(self: *FramePacer, window: *wio.Window) bool {
        if (!self.detectDisplayRefreshRate(window)) return false;
        self.setTickRate(self.display_rate_hz);
        return true;
    }

    /// Clear accumulator/timing discontinuities without clearing statistics.
    pub fn resync(self: *FramePacer) void {
        self.resetTimingState(nowNs(self.io));
    }

    /// Clear frame-time statistics.
    pub fn resetStats(self: *FramePacer) void {
        self.frame_durations = .{0} ** stats_window;
        self.frame_duration_count = 0;
        self.frame_duration_index = 0;
        self.worst_frame_duration_ns = 0;
    }

    /// Clear duplicate/catch-up/drift counters.
    pub fn resetPacingStats(self: *FramePacer) void {
        self.zero_update_frames = 0;
        self.multi_update_frames = 0;
        self.current_zero_streak = 0;
        self.max_zero_update_streak = 0;
        self.start_ns = nowNs(self.io);
        self.updates_at_reset = self.total_updates;
    }

    /// Clear timing, frame-time stats, and pacing-quality stats.
    pub fn resetAll(self: *FramePacer) void {
        self.resync();
        self.resetStats();
        self.resetPacingStats();
    }

    /// Snapshot frame-time statistics.
    pub fn stats(self: *const FramePacer) Stats {
        const count = self.frame_duration_count;
        if (count == 0) return .{};

        var sum: i128 = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            sum += self.frame_durations[i];
        }

        const avg_ns = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(count));
        return .{
            .avg_fps = if (avg_ns > 0) @as(f64, std.time.ns_per_s) / avg_ns else 0,
            .avg_frame_time_s = avg_ns / @as(f64, std.time.ns_per_s),
            .low1_fps = self.percentileLowFps(0.01),
            .low01_fps = self.percentileLowFps(0.001),
            .low1_frame_time_s = nsToSecondsFloat(self.percentileWorstAverageNs(0.01)),
            .low01_frame_time_s = nsToSecondsFloat(self.percentileWorstAverageNs(0.001)),
            .worst_frame_time_s = nsToSeconds(self.worst_frame_duration_ns),
            .frame_time_stddev_s = self.frameTimeStddevSeconds(avg_ns),
            .sample_count = count,
        };
    }

    /// Snapshot pacing-quality and sleep-quality metrics.
    pub fn quality(self: *const FramePacer) Quality {
        const duplicate = if (self.total_frames > 0)
            @as(f64, @floatFromInt(self.zero_update_frames)) / @as(f64, @floatFromInt(self.total_frames))
        else
            0;
        const expected = self.expectedDuplicateRatio();
        return .{
            .total_frames = self.total_frames,
            .total_updates = self.total_updates,
            .zero_update_frames = self.zero_update_frames,
            .multi_update_frames = self.multi_update_frames,
            .max_zero_update_streak = self.max_zero_update_streak,
            .duplicate_ratio = duplicate,
            .expected_duplicate_ratio = expected,
            .unexpected_duplicate_ratio = @max(duplicate - expected, 0),
            .drift_seconds = self.driftSeconds(),
            .display_rate_hz = self.display_rate_hz,
        };
    }

    fn beginFrameWithDelta(self: *FramePacer, measured_delta_ns: i64) void {
        var delta = measured_delta_ns;
        if (delta < 0) delta = 0;
        if (delta > self.desired_frame_ns * spiral_threshold) delta = self.desired_frame_ns;

        self.raw_frame_ns = delta;
        self.recordFrameDuration(delta);

        if (self.vsync_snap) {
            delta = self.snapDelta(delta);
        }

        delta = self.smoothDelta(delta);
        self.frame_delta_ns = delta;
        self.accumulator_ns += delta;

        if (self.accumulator_ns > self.desired_frame_ns * spiral_threshold) {
            self.accumulator_ns = 0;
            self.frame_delta_ns = self.desired_frame_ns;
        }

        self.update_counter = 0;
        switch (self.mode) {
            .unlocked => self.updates_this_frame = @intCast(@max(@divTrunc(self.accumulator_ns, self.desired_frame_ns), 0)),
            .locked => {
                const required = self.desired_frame_ns * @as(i64, @intCast(self.update_multiplicity));
                self.updates_this_frame = if (self.accumulator_ns >= required) self.update_multiplicity else 0;
            },
        }
        self.total_frames += 1;
    }

    fn recordPacingQuality(self: *FramePacer) void {
        if (self.update_counter == 0) {
            self.zero_update_frames += 1;
            self.current_zero_streak += 1;
            self.max_zero_update_streak = @max(self.max_zero_update_streak, self.current_zero_streak);
        } else {
            self.current_zero_streak = 0;
        }

        if (self.update_counter > 1) {
            self.multi_update_frames += 1;
        }
    }

    fn sleepToFrameCap(self: *FramePacer) void {
        if (self.frame_cap_ns <= 0 or self.sleep_mode == .none) return;

        const now = nowNs(self.io);
        const elapsed = now - self.frame_start_ns;
        const remaining = self.frame_cap_ns - elapsed;
        if (remaining <= 0) return;

        switch (self.sleep_mode) {
            .none => {},
            .passive => self.passiveSleep(remaining),
            .spin => self.spinUntil(self.frame_start_ns + self.frame_cap_ns),
            .hybrid => {
                const spin_threshold = @max(self.spin_threshold_ns, 0);
                const passive_margin = @max(self.passive_sleep_margin_ns, spin_threshold);
                const passive_ns = remaining - passive_margin;
                if (passive_ns > 0) self.passiveSleep(passive_ns);
                self.spinUntil(self.frame_start_ns + self.frame_cap_ns);
            },
        }
    }

    fn passiveSleep(self: *FramePacer, duration_ns: i64) void {
        if (duration_ns <= 0) return;
        std.Io.sleep(self.io, .fromNanoseconds(duration_ns), .awake) catch {};
    }

    fn spinUntil(self: *FramePacer, deadline_ns: i64) void {
        while (nowNs(self.io) < deadline_ns) {
            std.atomic.spinLoopHint();
        }
    }

    fn snapDelta(self: *const FramePacer, delta: i64) i64 {
        for (self.snap_ns) |snap| {
            if (snap <= 0) break;
            if (@abs(delta - snap) <= self.snap_tolerance_ns) return snap;
        }
        return delta;
    }

    fn smoothDelta(self: *FramePacer, delta: i64) i64 {
        return switch (self.smoothing) {
            .none => delta,
            .rolling => self.smoothRolling(delta),
            .ema => |config| self.smoothEma(delta, config),
        };
    }

    fn smoothRolling(self: *FramePacer, delta: i64) i64 {
        const window = self.rollingWindow();
        if (window <= 1) return delta;

        var i: usize = 0;
        while (i + 1 < window) : (i += 1) {
            self.rolling_history[i] = self.rolling_history[i + 1];
        }
        self.rolling_history[window - 1] = delta;

        var sum: i64 = 0;
        i = 0;
        while (i < window) : (i += 1) {
            sum += self.rolling_history[i];
        }

        const divisor: i64 = @intCast(window);
        var smoothed = @divTrunc(sum, divisor);
        self.rolling_residual += @rem(sum, divisor);
        smoothed += @divTrunc(self.rolling_residual, divisor);
        self.rolling_residual = @rem(self.rolling_residual, divisor);
        return smoothed;
    }

    fn smoothEma(self: *FramePacer, delta: i64, config: EmaConfig) i64 {
        const clamped = clampI64(delta, config.min_dt_ns, config.max_dt_ns);
        const clamped_f: f64 = @floatFromInt(clamped);
        const delta_error = @abs(clamped - self.smooth_frame_ns);
        if (delta_error > config.reset_threshold_ns) {
            self.ema_ns = clamped_f;
            self.smooth_frame_ns = clamped;
        } else {
            self.ema_ns = self.ema_ns + config.alpha * (clamped_f - self.ema_ns);
            self.smooth_frame_ns = clampI64(roundToI64(self.ema_ns), config.min_dt_ns, config.max_dt_ns);
        }
        return self.smooth_frame_ns;
    }

    fn recordFrameDuration(self: *FramePacer, delta: i64) void {
        self.frame_durations[self.frame_duration_index] = delta;
        self.frame_duration_index = (self.frame_duration_index + 1) % stats_window;
        if (self.frame_duration_count < stats_window) {
            self.frame_duration_count += 1;
        }
        self.worst_frame_duration_ns = @max(self.worst_frame_duration_ns, delta);
    }

    fn percentileLowFps(self: *const FramePacer, fraction: f64) f64 {
        const duration = self.percentileWorstAverageNs(fraction);
        return if (duration > 0) @as(f64, std.time.ns_per_s) / duration else 0;
    }

    fn percentileWorstAverageNs(self: *const FramePacer, fraction: f64) f64 {
        const count: usize = self.frame_duration_count;
        if (count == 0) return 0;

        var sorted: [stats_window]i64 = undefined;
        @memcpy(sorted[0..count], self.frame_durations[0..count]);
        std.sort.insertion(i64, sorted[0..count], {}, greaterThan);

        var worst_count: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(count)) * fraction));
        if (worst_count < 1) worst_count = 1;

        var sum: i128 = 0;
        var i: usize = 0;
        while (i < worst_count) : (i += 1) {
            sum += sorted[i];
        }
        return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(worst_count));
    }

    fn frameTimeStddevSeconds(self: *const FramePacer, avg_ns: f64) f64 {
        const count = self.frame_duration_count;
        if (count < 2) return 0;

        var variance_sum: f64 = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const diff = @as(f64, @floatFromInt(self.frame_durations[i])) - avg_ns;
            variance_sum += diff * diff;
        }

        const stddev_ns = @sqrt(variance_sum / @as(f64, @floatFromInt(count)));
        return stddev_ns / @as(f64, std.time.ns_per_s);
    }

    fn expectedDuplicateRatio(self: *const FramePacer) f64 {
        if (self.display_rate_hz <= 0) return 0;
        const tick_rate = self.tickRate();
        if (tick_rate >= self.display_rate_hz) return 0;
        return 1.0 - tick_rate / self.display_rate_hz;
    }

    fn driftSeconds(self: *const FramePacer) f64 {
        const actual_elapsed = self.previous_ns - self.start_ns;
        const updates_since_reset = self.total_updates - self.updates_at_reset;
        const expected_elapsed = @as(i128, @intCast(updates_since_reset)) * self.desired_frame_ns;
        const drift = @as(i128, actual_elapsed) - expected_elapsed;
        return @as(f64, @floatFromInt(drift)) / @as(f64, std.time.ns_per_s);
    }

    fn configureSmoothing(self: *FramePacer, smoothing: Smoothing) void {
        switch (smoothing) {
            .none => {},
            .rolling => |config| {
                self.rolling_window = @intCast(std.math.clamp(@as(u16, config.window), 1, max_rolling_window));
                self.fillRollingHistory();
            },
            .ema => |config| {
                const clamped = clampI64(self.desired_frame_ns, config.min_dt_ns, config.max_dt_ns);
                self.ema_ns = @floatFromInt(clamped);
                self.smooth_frame_ns = clamped;
            },
        }
    }

    fn resetTimingState(self: *FramePacer, now: i64) void {
        self.accumulator_ns = 0;
        self.update_counter = 0;
        self.updates_this_frame = 0;
        self.raw_frame_ns = 0;
        self.frame_delta_ns = self.desired_frame_ns;
        self.previous_ns = now;
        self.frame_start_ns = now;
        self.rolling_residual = 0;
        self.configureSmoothing(self.smoothing);
    }

    fn fillRollingHistory(self: *FramePacer) void {
        for (&self.rolling_history) |*sample| {
            sample.* = self.desired_frame_ns;
        }
        self.rolling_residual = 0;
    }

    fn rollingWindow(self: *const FramePacer) usize {
        return std.math.clamp(@as(usize, self.rolling_window), 1, max_rolling_window);
    }

    fn computeSnapHarmonics(self: *FramePacer) void {
        if (self.display_rate_hz <= 0) {
            self.snap_ns = .{0} ** max_harmonics;
            return;
        }

        for (&self.snap_ns, 1..) |*snap, harmonic| {
            snap.* = roundToI64(@as(f64, std.time.ns_per_s) * @as(f64, @floatFromInt(harmonic)) / self.display_rate_hz);
        }
    }
};

fn nowNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn hzToNs(hz: f64) i64 {
    const safe_hz = if (std.math.isFinite(hz) and hz > 0) hz else 60.0;
    return @max(roundToI64(@as(f64, std.time.ns_per_s) / safe_hz), 1);
}

fn nsToHz(ns: i64) f64 {
    return if (ns > 0) @as(f64, std.time.ns_per_s) / @as(f64, @floatFromInt(ns)) else 0;
}

fn nsToSeconds(ns: i64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_s);
}

fn nsToSecondsFloat(ns: f64) f64 {
    return ns / @as(f64, std.time.ns_per_s);
}

fn refreshRateHz(rate: wiox.display.RefreshRate) f64 {
    if (rate.numerator > 0 and rate.denominator > 0) {
        return @as(f64, @floatFromInt(rate.numerator)) / @as(f64, @floatFromInt(rate.denominator));
    }
    return if (std.math.isFinite(rate.hz) and rate.hz > 0) rate.hz else 0;
}

fn roundToI64(value: f64) i64 {
    return @intFromFloat(@round(value));
}

fn clampI64(value: i64, min_value: i64, max_value: i64) i64 {
    const lo = @min(min_value, max_value);
    const hi = @max(min_value, max_value);
    return std.math.clamp(value, lo, hi);
}

fn greaterThan(_: void, lhs: i64, rhs: i64) bool {
    return lhs > rhs;
}

test "default descriptor runs one locked update at 60hz" {
    var pacer = FramePacer.init(std.testing.io, .{ .smoothing = .none });
    pacer.beginFrameWithDelta(hzToNs(60));
    try std.testing.expectEqual(@as(u32, 1), pacer.updateCount());
    try std.testing.expect(pacer.shouldUpdate());
    try std.testing.expect(!pacer.shouldUpdate());
}

test "unlocked mode drains multiple updates and leaves interpolation remainder" {
    var pacer = FramePacer.init(std.testing.io, .{ .mode = .unlocked, .smoothing = .none });
    pacer.beginFrameWithDelta(pacer.desired_frame_ns * 3);
    try std.testing.expectEqual(@as(u32, 3), pacer.updateCount());
    try std.testing.expect(pacer.shouldUpdate());
    try std.testing.expect(pacer.shouldUpdate());
    try std.testing.expect(pacer.shouldUpdate());
    try std.testing.expect(!pacer.shouldUpdate());
    try std.testing.expectApproxEqAbs(@as(f64, 0), pacer.interpolationAlpha(), 0.0001);
}

test "locked multiplicity is all or nothing" {
    var pacer = FramePacer.init(std.testing.io, .{
        .mode = .locked,
        .update_multiplicity = 2,
        .smoothing = .none,
    });
    pacer.beginFrameWithDelta(hzToNs(60));
    try std.testing.expectEqual(@as(u32, 0), pacer.updateCount());
    pacer.beginFrameWithDelta(hzToNs(60));
    try std.testing.expectEqual(@as(u32, 2), pacer.updateCount());
}

test "vsync snapping maps near display harmonics" {
    var pacer = FramePacer.init(std.testing.io, .{
        .smoothing = .none,
        .snap_tolerance_ns = 300 * std.time.ns_per_us,
    });
    try std.testing.expect(pacer.setDisplayRefreshRate(.{ .hz = 60.0 }));
    pacer.beginFrameWithDelta(hzToNs(60) + 100 * std.time.ns_per_us);
    try std.testing.expectEqual(hzToNs(60), pacer.frame_delta_ns);
    pacer.beginFrameWithDelta(hzToNs(30) - 100 * std.time.ns_per_us);
    try std.testing.expectEqual(hzToNs(30), pacer.frame_delta_ns);
}

test "rolling smoothing carries residual time" {
    var pacer = FramePacer.init(std.testing.io, .{
        .smoothing = .{ .rolling = .{ .window = 4 } },
    });
    pacer.rolling_history = .{ 0, 0, 0, 0 } ++ .{0} ** (max_rolling_window - 4);

    var total: i64 = 0;
    total += pacer.smoothRolling(1);
    total += pacer.smoothRolling(1);
    total += pacer.smoothRolling(1);
    total += pacer.smoothRolling(1);
    try std.testing.expectEqual(@as(i64, 2), total);
}

test "ema resets on threshold and converges otherwise" {
    var pacer = FramePacer.init(std.testing.io, .{
        .smoothing = .{ .ema = .{
            .alpha = 0.5,
            .reset_threshold_ns = 10,
            .min_dt_ns = 1,
            .max_dt_ns = 1_000,
        } },
    });
    try std.testing.expectEqual(@as(i64, 100), pacer.smoothEma(100, pacer.smoothing.ema));
    try std.testing.expectEqual(@as(i64, 102), pacer.smoothEma(104, pacer.smoothing.ema));
}

test "spiral protection clears excessive accumulator growth" {
    var pacer = FramePacer.init(std.testing.io, .{ .mode = .unlocked, .smoothing = .none });
    pacer.accumulator_ns = pacer.desired_frame_ns * spiral_threshold;
    pacer.beginFrameWithDelta(pacer.desired_frame_ns);
    try std.testing.expectEqual(@as(i64, 0), pacer.accumulator_ns);
}

test "stats compute average lows worst and stddev" {
    var pacer = FramePacer.init(std.testing.io, .{ .smoothing = .none });
    pacer.recordFrameDuration(10);
    pacer.recordFrameDuration(20);
    pacer.recordFrameDuration(30);
    const s = pacer.stats();
    try std.testing.expectEqual(@as(u32, 3), s.sample_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00000002), s.avg_frame_time_s, 0.000000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00000003), s.low1_frame_time_s, 0.000000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00000003), s.worst_frame_time_s, 0.000000001);
    try std.testing.expect(s.frame_time_stddev_s > 0);
}

test "quality metrics count duplicates catchups and expected duplicates" {
    var pacer = FramePacer.init(std.testing.io, .{ .mode = .unlocked, .smoothing = .none });
    try std.testing.expect(pacer.setDisplayRefreshRate(.{ .hz = 120.0 }));

    pacer.beginFrameWithDelta(hzToNs(120));
    pacer.endFrame();
    pacer.beginFrameWithDelta(hzToNs(30));
    while (pacer.shouldUpdate()) {}
    pacer.endFrame();

    const q = pacer.quality();
    try std.testing.expectEqual(@as(u64, 2), q.total_frames);
    try std.testing.expectEqual(@as(u64, 1), q.zero_update_frames);
    try std.testing.expectEqual(@as(u64, 1), q.multi_update_frames);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), q.expected_duplicate_ratio, 0.0001);
}

test "reset functions clear intended state" {
    var pacer = FramePacer.init(std.testing.io, .{ .smoothing = .none });
    pacer.beginFrameWithDelta(hzToNs(60));
    pacer.endFrame();
    pacer.resetStats();
    try std.testing.expectEqual(@as(u32, 0), pacer.stats().sample_count);
    pacer.resetPacingStats();
    try std.testing.expectEqual(@as(u64, 0), pacer.quality().zero_update_frames);
    pacer.resetAll();
    try std.testing.expectEqual(@as(i64, 0), pacer.accumulator_ns);
}

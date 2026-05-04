const std = @import("std");
const wio = @import("wio");
const wiox = @import("wiox");

comptime {
    _ = wio;
}

const default_hz = 60.0;
const sample_window = 240;
const max_refresh_multiple = 8;

pub const SleepMode = enum {
    none,
    passive,
    hybrid,
    spin,
};

pub const TimingSmoothing = union(enum) {
    none,
    sokol_ema: EmaConfig,
};

pub const EmaConfig = struct {
    alpha: f64 = 0.025,
    reset_threshold_ns: i64 = 4 * std.time.ns_per_ms,
    min_dt_ns: i64 = 1 * std.time.ns_per_us,
    max_dt_ns: i64 = 100 * std.time.ns_per_ms,
};

pub const FrameTarget = union(enum) {
    none,
    display,
    hz: f64,
    refresh_fraction: RefreshFraction,
};

pub const RefreshFraction = struct {
    numerator: u32,
    denominator: u32,
};

pub const VsyncState = enum {
    unknown,
    likely_on,
    likely_off,
};

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

pub const PresentationDecision = struct {
    requested_hz: f64 = 0,
    target_hz: f64 = 0,
    effective_hz: f64 = 0,
    display_hz: f64 = 0,
    present_this_frame: bool = true,
    repeat_count: u32 = 1,
    software_wait_s: f64 = 0,
};

pub const Info = struct {
    frame_duration_s: f64 = 0,
    unfiltered_frame_duration_s: f64 = 0,
    observed_fps: f64 = 0,
    display_hz: f64 = 0,
    requested_hz: f64 = 0,
    effective_hz: f64 = 0,
    repeat_count: u32 = 1,
    vsync_state: VsyncState = .unknown,
    sample_count: u32 = 0,
};

pub const ResolvedTarget = struct {
    requested_hz: f64 = 0,
    target_hz: f64 = 0,
    effective_hz: f64 = 0,
    repeat_count: u32 = 1,
    display_hz: f64 = 0,
};

pub const FrameClock = struct {
    io: std.Io,
    smoothing: TimingSmoothing,
    target: FrameTarget,
    sleep_mode: SleepMode,
    vsync_probe_frames: u32,
    vsync_match_tolerance_ratio: f64,
    display_snap_tolerance_ratio: f64,
    passive_sleep_margin_ns: i64,
    spin_threshold_ns: i64,

    previous_ns: i64,
    frame_start_ns: i64,
    raw_frame_ns: i64,
    smooth_frame_ns: i64,
    ema_ns: f64,
    display_rate: wiox.display.RefreshRate = .{},
    display_hz: f64 = 0,
    resolved: ResolvedTarget = .{},
    vsync_state: VsyncState = .unknown,
    observed_divisor: u32 = 0,
    next_present_ns: i64 = 0,
    last_software_wait_ns: i64 = 0,

    samples: [sample_window]i64 = .{0} ** sample_window,
    sample_count: u32 = 0,
    sample_index: u32 = 0,

    pub fn init(io: std.Io, desc: FrameClockDesc) FrameClock {
        const now = nowNs(io);
        var clock = FrameClock{
            .io = io,
            .smoothing = desc.smoothing,
            .target = desc.target,
            .sleep_mode = desc.sleep_mode,
            .vsync_probe_frames = std.math.clamp(desc.vsync_probe_frames, 8, sample_window),
            .vsync_match_tolerance_ratio = if (validPositive(desc.vsync_match_tolerance_ratio)) desc.vsync_match_tolerance_ratio else 0.025,
            .display_snap_tolerance_ratio = if (validPositive(desc.display_snap_tolerance_ratio)) desc.display_snap_tolerance_ratio else 0.005,
            .passive_sleep_margin_ns = @max(desc.passive_sleep_margin_ns, 0),
            .spin_threshold_ns = @max(desc.spin_threshold_ns, 0),
            .previous_ns = now,
            .frame_start_ns = now,
            .raw_frame_ns = hzToNs(default_hz),
            .smooth_frame_ns = hzToNs(default_hz),
            .ema_ns = @floatFromInt(hzToNs(default_hz)),
        };
        clock.resolveTarget();
        return clock;
    }

    pub fn beginFrame(self: *FrameClock) void {
        const now = nowNs(self.io);
        const measured = now - self.previous_ns;
        self.beginFrameWithDelta(measured);
        self.previous_ns = now;
        self.frame_start_ns = now;
    }

    pub fn endFrame(self: *FrameClock, window: ?*wio.Window) void {
        if (self.display_hz <= 0) {
            if (window) |win| _ = self.detectDisplayRefreshRate(win);
        }
        self.classifyVsync();
        self.last_software_wait_ns = 0;
        if (self.shouldSoftwarePace()) {
            self.sleepToNextPresentation();
        }
    }

    pub fn frameDuration(self: *const FrameClock) f64 {
        return nsToSeconds(self.smooth_frame_ns);
    }

    pub fn frameDurationUnfiltered(self: *const FrameClock) f64 {
        return nsToSeconds(self.raw_frame_ns);
    }

    pub fn observedFrameRate(self: *const FrameClock) f64 {
        const avg = self.averageSampleNs();
        return if (avg > 0) @as(f64, std.time.ns_per_s) / avg else 0;
    }

    pub fn displayRefreshRate(self: *const FrameClock) ?wiox.display.RefreshRate {
        return if (self.display_hz > 0) self.display_rate else null;
    }

    pub fn vsyncState(self: *const FrameClock) VsyncState {
        return self.vsync_state;
    }

    pub fn isEffectivelyVsynced(self: *const FrameClock) bool {
        return self.vsync_state == .likely_on;
    }

    pub fn presentationDecision(self: *const FrameClock) PresentationDecision {
        return .{
            .requested_hz = self.resolved.requested_hz,
            .target_hz = self.resolved.target_hz,
            .effective_hz = self.resolved.effective_hz,
            .display_hz = self.display_hz,
            .present_this_frame = true,
            .repeat_count = self.resolved.repeat_count,
            .software_wait_s = nsToSeconds(self.last_software_wait_ns),
        };
    }

    pub fn info(self: *const FrameClock) Info {
        return .{
            .frame_duration_s = self.frameDuration(),
            .unfiltered_frame_duration_s = self.frameDurationUnfiltered(),
            .observed_fps = self.observedFrameRate(),
            .display_hz = self.display_hz,
            .requested_hz = self.resolved.requested_hz,
            .effective_hz = self.resolved.effective_hz,
            .repeat_count = self.resolved.repeat_count,
            .vsync_state = self.vsync_state,
            .sample_count = self.sample_count,
        };
    }

    pub fn setTargetHz(self: *FrameClock, hz: f64) void {
        self.target = .{ .hz = hz };
        self.resolveTarget();
        self.resyncDeadline();
    }

    pub fn setTargetDisplay(self: *FrameClock) void {
        self.target = .display;
        self.resolveTarget();
        self.resyncDeadline();
    }

    pub fn setTargetRefreshFraction(self: *FrameClock, numerator: u32, denominator: u32) void {
        self.target = .{ .refresh_fraction = .{ .numerator = numerator, .denominator = denominator } };
        self.resolveTarget();
        self.resyncDeadline();
    }

    pub fn setDisplayRefreshRate(self: *FrameClock, rate: wiox.display.RefreshRate) bool {
        const hz = refreshRateHz(rate);
        if (hz <= 0) {
            self.display_rate = .{};
            self.display_hz = 0;
            self.resolveTarget();
            return false;
        }
        self.display_rate = rate;
        self.display_hz = hz;
        self.resolveTarget();
        return true;
    }

    pub fn detectDisplayRefreshRate(self: *FrameClock, window: *wio.Window) bool {
        const display = wiox.display.getWindowDisplay(window) orelse return false;
        defer display.release();
        return self.setDisplayRefreshRate(display.getRefreshRate());
    }

    pub fn resync(self: *FrameClock) void {
        const now = nowNs(self.io);
        self.previous_ns = now;
        self.frame_start_ns = now;
        self.raw_frame_ns = hzToNs(default_hz);
        self.smooth_frame_ns = hzToNs(default_hz);
        self.ema_ns = @floatFromInt(self.smooth_frame_ns);
        self.samples = .{0} ** sample_window;
        self.sample_count = 0;
        self.sample_index = 0;
        self.vsync_state = .unknown;
        self.observed_divisor = 0;
        self.resyncDeadline();
    }

    pub fn beginFrameWithDelta(self: *FrameClock, measured_delta_ns: i64) void {
        const clamped = self.clampDelta(measured_delta_ns);
        self.raw_frame_ns = clamped;
        self.recordSample(clamped);
        self.smooth_frame_ns = self.smoothDelta(clamped);
    }

    pub fn beginFrameWithDisplayLink(self: *FrameClock, frame: wio.DisplayLinkFrame) void {
        const now = nowNs(self.io);
        const measured_ns = secondsToNs(frame.duration_s);
        const clamped = self.clampDelta(measured_ns);
        self.raw_frame_ns = clamped;
        self.recordSample(clamped);
        self.smooth_frame_ns = clamped;
        self.ema_ns = @floatFromInt(clamped);
        self.previous_ns = now;
        self.frame_start_ns = now;
        self.vsync_state = .likely_on;
    }

    fn clampDelta(self: *const FrameClock, delta_ns: i64) i64 {
        const config = self.emaConfig();
        return clampI64(@max(delta_ns, 0), config.min_dt_ns, config.max_dt_ns);
    }

    fn smoothDelta(self: *FrameClock, delta_ns: i64) i64 {
        return switch (self.smoothing) {
            .none => delta_ns,
            .sokol_ema => |config| self.smoothEma(delta_ns, config),
        };
    }

    fn smoothEma(self: *FrameClock, delta_ns: i64, config: EmaConfig) i64 {
        const clamped = clampI64(delta_ns, config.min_dt_ns, config.max_dt_ns);
        const delta_error = @abs(clamped - self.smooth_frame_ns);
        if (delta_error > config.reset_threshold_ns) {
            self.ema_ns = @floatFromInt(clamped);
            self.smooth_frame_ns = clamped;
        } else {
            const clamped_f: f64 = @floatFromInt(clamped);
            self.ema_ns = self.ema_ns + config.alpha * (clamped_f - self.ema_ns);
            self.smooth_frame_ns = clampI64(roundToI64(self.ema_ns), config.min_dt_ns, config.max_dt_ns);
        }
        return self.smooth_frame_ns;
    }

    fn emaConfig(self: *const FrameClock) EmaConfig {
        return switch (self.smoothing) {
            .none => .{},
            .sokol_ema => |config| config,
        };
    }

    fn recordSample(self: *FrameClock, delta_ns: i64) void {
        self.samples[self.sample_index] = delta_ns;
        self.sample_index = (self.sample_index + 1) % sample_window;
        if (self.sample_count < sample_window) self.sample_count += 1;
    }

    fn classifyVsync(self: *FrameClock) void {
        if (self.display_hz <= 0 or self.sample_count < 8) {
            self.vsync_state = .unknown;
            self.observed_divisor = 0;
            return;
        }

        const period_ns = hzToNs(self.display_hz);
        const count: usize = self.sample_count;
        var matched: u32 = 0;
        var divisor_sum: u32 = 0;
        var faster_than_display: u32 = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const sample = self.samples[i];
            if (sample <= 0) continue;
            if (@as(f64, @floatFromInt(sample)) < @as(f64, @floatFromInt(period_ns)) * 0.75) {
                faster_than_display += 1;
            }
            const nearest = nearestRefreshMultiple(sample, period_ns);
            const expected = period_ns * @as(i64, @intCast(nearest));
            const delta_error = @abs(sample - expected);
            const tolerance = @as(f64, @floatFromInt(expected)) * self.vsync_match_tolerance_ratio;
            if (@as(f64, @floatFromInt(delta_error)) <= tolerance) {
                matched += 1;
                divisor_sum += nearest;
            }
        }

        const count_f: f64 = @floatFromInt(count);
        const match_ratio = @as(f64, @floatFromInt(matched)) / count_f;
        const faster_ratio = @as(f64, @floatFromInt(faster_than_display)) / count_f;
        if (self.sample_count < self.vsync_probe_frames) {
            if (faster_ratio >= 0.85) {
                self.vsync_state = .likely_off;
                self.observed_divisor = 0;
            } else {
                self.vsync_state = .unknown;
                self.observed_divisor = 0;
            }
            return;
        }

        if (match_ratio >= 0.85 and faster_ratio < 0.10) {
            self.vsync_state = .likely_on;
            self.observed_divisor = if (matched > 0) @max(1, @divTrunc(divisor_sum + matched / 2, matched)) else 1;
        } else {
            self.vsync_state = .likely_off;
            self.observed_divisor = 0;
        }
    }

    fn shouldSoftwarePace(self: *const FrameClock) bool {
        if (self.sleep_mode == .none) return false;
        if (self.resolved.effective_hz <= 0) return false;
        if (self.vsync_state == .likely_on) return false;
        if (self.vsync_state == .likely_off) return true;
        return self.display_hz <= 0;
    }

    fn sleepToNextPresentation(self: *FrameClock) void {
        const period_ns = hzToNs(self.resolved.effective_hz);
        if (period_ns <= 0) return;

        var now = nowNs(self.io);
        if (self.next_present_ns <= 0 or now > self.next_present_ns + period_ns) {
            self.next_present_ns = now + period_ns;
        }

        const remaining = self.next_present_ns - now;
        if (remaining > 0) {
            self.last_software_wait_ns = remaining;
            switch (self.sleep_mode) {
                .none => {},
                .passive => self.passiveSleep(remaining),
                .spin => self.spinUntil(self.next_present_ns),
                .hybrid => {
                    const spin_threshold = @max(self.spin_threshold_ns, 0);
                    const passive_margin = @max(self.passive_sleep_margin_ns, spin_threshold);
                    const passive_ns = remaining - passive_margin;
                    if (passive_ns > 0) self.passiveSleep(passive_ns);
                    self.spinUntil(self.next_present_ns);
                },
            }
            now = nowNs(self.io);
        }

        while (self.next_present_ns <= now) {
            self.next_present_ns += period_ns;
        }
    }

    fn passiveSleep(self: *FrameClock, duration_ns: i64) void {
        if (duration_ns <= 0) return;
        std.Io.sleep(self.io, .fromNanoseconds(duration_ns), .awake) catch {};
    }

    fn spinUntil(self: *FrameClock, deadline_ns: i64) void {
        while (nowNs(self.io) < deadline_ns) {
            std.atomic.spinLoopHint();
        }
    }

    fn resolveTarget(self: *FrameClock) void {
        self.resolved = resolveFrameTarget(self.target, self.display_hz, self.display_snap_tolerance_ratio);
    }

    fn resyncDeadline(self: *FrameClock) void {
        const now = nowNs(self.io);
        self.next_present_ns = if (self.resolved.effective_hz > 0) now + hzToNs(self.resolved.effective_hz) else 0;
    }

    fn averageSampleNs(self: *const FrameClock) f64 {
        if (self.sample_count == 0) return 0;
        var sum: i128 = 0;
        var i: usize = 0;
        while (i < self.sample_count) : (i += 1) {
            sum += self.samples[i];
        }
        return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(self.sample_count));
    }
};

pub fn resolveFrameTarget(target: FrameTarget, display_hz: f64, snap_tolerance_ratio: f64) ResolvedTarget {
    const safe_display = if (validPositive(display_hz)) display_hz else 0;
    const tolerance = if (validPositive(snap_tolerance_ratio)) snap_tolerance_ratio else 0.005;
    const requested = requestedHz(target, safe_display);
    if (requested <= 0) return .{ .display_hz = safe_display };

    var result = ResolvedTarget{
        .requested_hz = requested,
        .target_hz = requested,
        .effective_hz = requested,
        .repeat_count = 1,
        .display_hz = safe_display,
    };

    if (safe_display <= 0) return result;

    if (nearRatio(requested, safe_display, tolerance)) {
        result.target_hz = safe_display;
        result.effective_hz = safe_display;
        return result;
    }

    var divisor: u32 = 2;
    while (divisor <= max_refresh_multiple) : (divisor += 1) {
        const divided = safe_display / @as(f64, @floatFromInt(divisor));
        if (nearRatio(requested, divided, tolerance)) {
            result.target_hz = divided;
            result.effective_hz = divided;
            result.repeat_count = divisor;
            return result;
        }
    }

    var multiple: u32 = 2;
    while (multiple <= max_refresh_multiple) : (multiple += 1) {
        const multiplied = safe_display * @as(f64, @floatFromInt(multiple));
        if (nearRatio(requested, multiplied, tolerance)) {
            result.target_hz = multiplied;
            result.effective_hz = multiplied;
            return result;
        }
    }

    return result;
}

fn requestedHz(target: FrameTarget, display_hz: f64) f64 {
    return switch (target) {
        .none => 0,
        .display => display_hz,
        .hz => |hz| if (validPositive(hz)) hz else 0,
        .refresh_fraction => |fraction| blk: {
            if (display_hz <= 0 or fraction.denominator == 0) break :blk 0;
            break :blk display_hz * @as(f64, @floatFromInt(fraction.numerator)) / @as(f64, @floatFromInt(fraction.denominator));
        },
    };
}

fn nearestRefreshMultiple(sample_ns: i64, period_ns: i64) u32 {
    if (period_ns <= 0) return 1;
    const ratio = @as(f64, @floatFromInt(sample_ns)) / @as(f64, @floatFromInt(period_ns));
    const nearest: u32 = @intFromFloat(@max(1, @round(ratio)));
    return @min(nearest, max_refresh_multiple);
}

fn nearRatio(a: f64, b: f64, tolerance_ratio: f64) bool {
    if (!validPositive(a) or !validPositive(b)) return false;
    const denom = @max(@abs(a), @abs(b));
    return @abs(a - b) / denom <= tolerance_ratio;
}

fn refreshRateHz(rate: wiox.display.RefreshRate) f64 {
    if (rate.numerator > 0 and rate.denominator > 0) {
        return @as(f64, @floatFromInt(rate.numerator)) / @as(f64, @floatFromInt(rate.denominator));
    }
    return if (validPositive(rate.hz)) rate.hz else 0;
}

fn nowNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn hzToNs(hz: f64) i64 {
    const safe_hz = if (validPositive(hz)) hz else default_hz;
    return @max(roundToI64(@as(f64, std.time.ns_per_s) / safe_hz), 1);
}

fn nsToSeconds(ns: i64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_s);
}

fn secondsToNs(seconds: f64) i64 {
    if (!validPositive(seconds)) return hzToNs(default_hz);
    return roundToI64(seconds * @as(f64, std.time.ns_per_s));
}

fn roundToI64(value: f64) i64 {
    return @intFromFloat(@round(value));
}

fn clampI64(value: i64, min_value: i64, max_value: i64) i64 {
    const lo = @min(min_value, max_value);
    const hi = @max(min_value, max_value);
    return std.math.clamp(value, lo, hi);
}

fn validPositive(value: f64) bool {
    return std.math.isFinite(value) and value > 0;
}

test "sokol ema resets on large timing discontinuity" {
    var clock = FrameClock.init(std.testing.io, .{ .target = .none });
    clock.beginFrameWithDelta(hzToNs(60));
    try std.testing.expectEqual(hzToNs(60), clock.raw_frame_ns);
    clock.beginFrameWithDelta(hzToNs(30));
    try std.testing.expectEqual(hzToNs(30), clock.smooth_frame_ns);
}

test "sokol ema blends small timing changes" {
    var clock = FrameClock.init(std.testing.io, .{ .target = .none });
    clock.smooth_frame_ns = 1 * std.time.ns_per_ms;
    clock.ema_ns = @floatFromInt(1 * std.time.ns_per_ms);
    clock.beginFrameWithDelta(1 * std.time.ns_per_ms + 1000);
    try std.testing.expectEqual(@as(i64, 1 * std.time.ns_per_ms + 1000), clock.raw_frame_ns);
    try std.testing.expectEqual(@as(i64, 1 * std.time.ns_per_ms + 25), clock.smooth_frame_ns);
}

test "target resolution snaps requested hz to close display hz" {
    const resolved = resolveFrameTarget(.{ .hz = 60.0 }, 59.95, 0.005);
    try std.testing.expectApproxEqAbs(@as(f64, 59.95), resolved.effective_hz, 0.0001);
    try std.testing.expectEqual(@as(u32, 1), resolved.repeat_count);
}

test "target resolution maps 60hz request to every other 120hz display refresh" {
    const resolved = resolveFrameTarget(.{ .hz = 60.0 }, 119.92, 0.005);
    try std.testing.expectApproxEqAbs(@as(f64, 59.96), resolved.effective_hz, 0.0001);
    try std.testing.expectEqual(@as(u32, 2), resolved.repeat_count);
}

test "target resolution keeps requested rate without known display" {
    const resolved = resolveFrameTarget(.{ .hz = 75.0 }, 0, 0.005);
    try std.testing.expectApproxEqAbs(@as(f64, 75.0), resolved.effective_hz, 0.0001);
    try std.testing.expectEqual(@as(u32, 1), resolved.repeat_count);
}

test "vsync classifier recognizes display period samples" {
    var clock = FrameClock.init(std.testing.io, .{ .target = .none, .smoothing = .none, .vsync_probe_frames = 16 });
    try std.testing.expect(clock.setDisplayRefreshRate(.{ .hz = 120.0 }));
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        clock.beginFrameWithDelta(hzToNs(120));
    }
    clock.classifyVsync();
    try std.testing.expectEqual(VsyncState.likely_on, clock.vsyncState());
    try std.testing.expectEqual(@as(u32, 1), clock.observed_divisor);
}

test "vsync classifier recognizes doubled display period samples" {
    var clock = FrameClock.init(std.testing.io, .{ .target = .none, .smoothing = .none, .vsync_probe_frames = 16 });
    try std.testing.expect(clock.setDisplayRefreshRate(.{ .hz = 120.0 }));
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        clock.beginFrameWithDelta(hzToNs(60));
    }
    clock.classifyVsync();
    try std.testing.expectEqual(VsyncState.likely_on, clock.vsyncState());
    try std.testing.expectEqual(@as(u32, 2), clock.observed_divisor);
}

test "vsync classifier marks free running samples as likely off" {
    var clock = FrameClock.init(std.testing.io, .{ .target = .none, .smoothing = .none, .vsync_probe_frames = 16 });
    try std.testing.expect(clock.setDisplayRefreshRate(.{ .hz = 60.0 }));
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        clock.beginFrameWithDelta(1 * std.time.ns_per_ms);
    }
    clock.classifyVsync();
    try std.testing.expectEqual(VsyncState.likely_off, clock.vsyncState());
}

test "vsync classifier can detect obvious free running before full probe" {
    var clock = FrameClock.init(std.testing.io, .{ .target = .none, .smoothing = .none, .vsync_probe_frames = 120 });
    try std.testing.expect(clock.setDisplayRefreshRate(.{ .hz = 60.0 }));
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        clock.beginFrameWithDelta(1 * std.time.ns_per_ms);
    }
    clock.classifyVsync();
    try std.testing.expectEqual(VsyncState.likely_off, clock.vsyncState());
}

test "display link frame bypasses ema filtering" {
    var clock = FrameClock.init(std.testing.io, .{ .target = .none });
    clock.smooth_frame_ns = hzToNs(60);
    clock.ema_ns = @floatFromInt(hzToNs(60));
    clock.beginFrameWithDisplayLink(.{
        .timestamp_s = 1.0,
        .duration_s = 1.0 / 120.0,
    });
    try std.testing.expectEqual(hzToNs(120), clock.raw_frame_ns);
    try std.testing.expectEqual(hzToNs(120), clock.smooth_frame_ns);
    try std.testing.expectEqual(VsyncState.likely_on, clock.vsyncState());
}

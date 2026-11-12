//! The okorec window (raylib): live status, replay/record buttons.
//! Runs on the main thread; capture and audio have their own.
const std = @import("std");
const rl = @import("raylib");
const util = @import("util.zig");
const App = @import("main.zig").App;

const width = 560;
const height = 368;

const bg = rl.Color{ .r = 18, .g = 20, .b = 24, .a = 255 };
const panel = rl.Color{ .r = 30, .g = 33, .b = 40, .a = 255 };
const panel_hi = rl.Color{ .r = 44, .g = 49, .b = 60, .a = 255 };
const fg = rl.Color{ .r = 226, .g = 229, .b = 235, .a = 255 };
const dim = rl.Color{ .r = 138, .g = 145, .b = 160, .a = 255 };
const accent = rl.Color{ .r = 86, .g = 196, .b = 138, .a = 255 };
const red = rl.Color{ .r = 232, .g = 84, .b = 84, .a = 255 };

var font: rl.Font = undefined;
var mono: rl.Font = undefined;

fn loadFont(paths: []const [:0]const u8) rl.Font {
    for (paths) |p| {
        if (!rl.FileExists(p.ptr)) continue;
        const f = rl.LoadFontEx(p.ptr, 40, null, 0);
        if (f.texture.id != 0) {
            rl.SetTextureFilter(f.texture, rl.TEXTURE_FILTER_BILINEAR);
            return f;
        }
    }
    return rl.GetFontDefault();
}

fn text(f: rl.Font, comptime fmt: []const u8, args: anytype, x: f32, y: f32, size: f32, color: rl.Color) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    rl.DrawTextEx(f, s.ptr, .{ .x = x, .y = y }, size, 0, color);
}

fn button(label: [:0]const u8, hint: [:0]const u8, rect: rl.Rectangle, color: rl.Color) bool {
    const hover = rl.CheckCollisionPointRec(rl.GetMousePosition(), rect);
    rl.DrawRectangleRounded(rect, 0.25, 8, if (hover) panel_hi else panel);
    rl.DrawRectangleRoundedLinesEx(rect, 0.25, 8, 1.5, color);
    text(font, "{s}", .{label}, rect.x + 16, rect.y + 10, 20, fg);
    text(font, "{s}", .{hint}, rect.x + 16, rect.y + 36, 14, dim);
    return hover and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT);
}

/// Small toggle used for the frame-rate choices.
fn chip(comptime fmt: []const u8, args: anytype, rect: rl.Rectangle, selected: bool) bool {
    const hover = rl.CheckCollisionPointRec(rl.GetMousePosition(), rect);
    rl.DrawRectangleRounded(rect, 0.4, 8, if (selected) accent else if (hover) panel_hi else panel);
    text(mono, fmt, args, rect.x + 12, rect.y + 5, 16, if (selected) bg else fg);
    return hover and !selected and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT);
}

const fps_choices = [_]u32{ 30, 60, 120, 144, 240 };

/// Per-second rates derived from the running counters.
const Rates = struct {
    last_ns: i64 = 0,
    last_frames: u64 = 0,
    last_bytes: [2]u64 = .{ 0, 0 },
    fps: f32 = 0,
    video_mbps: f32 = 0,
    audio_kbps: f32 = 0,
    history: [120]f32 = @splat(0),
    head: usize = 0,

    fn update(self: *Rates, app: *App, stats: anytype) void {
        const now = util.nowNs();
        if (now - self.last_ns < std.time.ns_per_s / 2) return;
        const dt = @as(f32, @floatFromInt(now - self.last_ns)) / 1e9;
        const frames = app.pipe.frames.load(.monotonic);
        if (self.last_ns != 0) {
            self.fps = @as(f32, @floatFromInt(frames - self.last_frames)) / dt;
            self.video_mbps = @as(f32, @floatFromInt(stats.total_bytes[0] - self.last_bytes[0])) * 8 / 1e6 / dt;
            self.audio_kbps = @as(f32, @floatFromInt(stats.total_bytes[1] - self.last_bytes[1])) * 8 / 1e3 / dt;
            self.history[self.head] = self.video_mbps;
            self.head = (self.head + 1) % self.history.len;
        }
        self.last_ns = now;
        self.last_frames = frames;
        self.last_bytes = stats.total_bytes;
    }
};

pub fn run(app: *App, sfd: i32) void {
    rl.SetTraceLogLevel(rl.LOG_ERROR);
    rl.SetConfigFlags(rl.FLAG_MSAA_4X_HINT);
    rl.InitWindow(width, height, "OkoRec");
    defer rl.CloseWindow();
    rl.SetExitKey(0);
    // Debian/Ubuntu, Arch, Fedora locations; raylib's built-in font otherwise.
    font = loadFont(&.{
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/liberation-sans-fonts/LiberationSans-Regular.ttf",
    });
    mono = loadFont(&.{
        "/usr/share/fonts/truetype/JetBrainsMonoNLNerdFont-Medium.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
        "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
        "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
        "/usr/share/fonts/liberation-mono-fonts/LiberationMono-Regular.ttf",
    });

    var rates = Rates{};
    var focused = true;
    rl.SetTargetFPS(30);
    while (!rl.WindowShouldClose()) {
        if (app.handleSignal(sfd) == .quit) break;
        // Nobody is looking: draw rarely, the recorder itself is unaffected.
        const now_focused = rl.IsWindowFocused();
        if (now_focused != focused) {
            focused = now_focused;
            rl.SetTargetFPS(if (focused) 30 else 8);
        }

        const stats = app.ring.stats();
        rates.update(app, stats);
        const recording = app.recorder.active.load(.acquire);
        const capturing = app.pipe.frames.load(.monotonic) > 0;

        rl.BeginDrawing();
        rl.ClearBackground(bg);

        // Header: state + what is being captured.
        const blink = @mod(rl.GetTime(), 1.0) < 0.6;
        rl.DrawCircle(26, 28, 8, if (recording) (if (blink) red else panel_hi) else if (capturing) accent else dim);
        text(font, "{s}", .{if (recording) "Recording" else if (capturing) "Replay buffer running" else "Starting capture..."}, 44, 16, 22, fg);
        if (capturing) {
            const hdr = if (app.kms) |k| k.transfer == .pq else false;
            text(font, "{d}x{d}  {s}{s}", .{
                app.pipe.width,
                app.pipe.height,
                if (app.kms != null) "KMS" else "portal",
                if (hdr) "  HDR > SDR" else "",
            }, 330, 20, 16, dim);
        }

        // Numbers.
        const y0: f32 = 62;
        const held = @as(f32, @floatFromInt(stats.span_ns)) / 1e9;
        text(font, "Buffer", .{}, 24, y0, 15, dim);
        text(mono, "{d:.0} / {d} s   {d:.1} MB", .{ @min(held, @as(f32, @floatFromInt(app.cfg.seconds))), app.cfg.seconds, @as(f32, @floatFromInt(stats.bytes)) / 1e6 }, 100, y0 - 2, 17, fg);
        text(font, "Video", .{}, 24, y0 + 26, 15, dim);
        text(mono, "{d:.1} fps   {d:.1} Mb/s", .{ rates.fps, rates.video_mbps }, 100, y0 + 24, 17, fg);
        text(font, "Audio", .{}, 24, y0 + 52, 15, dim);
        if (app.audio) |a| {
            text(mono, "{d:.0} kb/s", .{rates.audio_kbps}, 100, y0 + 50, 17, fg);
            const level = std.math.clamp(a.peak.load(.monotonic), 0, 1);
            rl.DrawRectangleRounded(.{ .x = 200, .y = y0 + 56, .width = 110, .height = 8 }, 1, 4, panel);
            if (level > 0.002) rl.DrawRectangleRounded(.{ .x = 200, .y = y0 + 56, .width = 110 * @sqrt(level), .height = 8 }, 1, 4, accent);
        } else text(mono, "off", .{}, 100, y0 + 50, 17, dim);

        // Video bitrate over the last minute.
        const gx: f32 = 330;
        const gy: f32 = y0;
        const gw: f32 = 206;
        const gh: f32 = 70;
        rl.DrawRectangleRounded(.{ .x = gx, .y = gy, .width = gw, .height = gh }, 0.1, 4, panel);
        var peak: f32 = 1;
        for (rates.history) |v| peak = @max(peak, v);
        const bw = gw / @as(f32, @floatFromInt(rates.history.len));
        for (0..rates.history.len) |i| {
            const v = rates.history[(rates.head + i) % rates.history.len];
            const h = (gh - 8) * v / peak;
            if (h >= 1) rl.DrawRectangleRec(.{ .x = gx + bw * @as(f32, @floatFromInt(i)), .y = gy + gh - 4 - h, .width = @max(bw - 0.5, 1), .height = h }, accent);
        }
        text(font, "{d:.0} Mb/s", .{peak}, gx + 6, gy + 4, 12, dim);

        // Capture rate: applies immediately and is remembered.
        text(font, "Rate", .{}, 24, 148, 15, dim);
        const current = app.fps();
        var custom = true;
        for (fps_choices, 0..) |f, i| {
            if (f == current) custom = false;
            if (chip("{d: >3}", .{f}, .{ .x = 100 + 62 * @as(f32, @floatFromInt(i)), .y = 142, .width = 54, .height = 28 }, f == current))
                app.setFps(f);
        }
        // A rate from --fps that isn't one of the presets.
        if (custom) _ = chip("{d: >3}", .{current}, .{ .x = 100 + 62 * fps_choices.len, .y = 142, .width = 54, .height = 28 }, true);
        text(font, "fps", .{}, 100 + 62 * @as(f32, @floatFromInt(fps_choices.len + @intFromBool(custom))), 148, 15, dim);

        // Actions.
        if (button("Save replay", "Super+F10  -  last seconds to a file", .{ .x = 24, .y = 190, .width = 250, .height = 64 }, accent))
            app.saveReplay();
        var rec_hint: [96]u8 = undefined;
        const hint: [:0]const u8 = if (recording) blk: {
            const secs: u64 = @intCast(@divTrunc(util.nowNs() - app.recorder.start_ns, std.time.ns_per_s));
            break :blk std.fmt.bufPrintZ(&rec_hint, "{d:0>2}:{d:0>2}   {d:.1} MB", .{ secs / 60, secs % 60, @as(f32, @floatFromInt(app.recorder.bytes.load(.monotonic))) / 1e6 }) catch "";
        } else "Super+F9  -  record until stopped";
        if (button(if (recording) "Stop recording" else "Start recording", hint, .{ .x = 286, .y = 190, .width = 250, .height = 64 }, if (recording) red else dim))
            app.toggleRecording();

        // Last event, wrapped over two lines.
        const msg = app.message();
        if (msg.len > 0) {
            const split: usize = @min(msg.len, 74);
            text(font, "{s}", .{msg[0..split]}, 24, 272, 14, dim);
            if (msg.len > split) text(font, "{s}", .{msg[split..@min(msg.len, 2 * split)]}, 24, 290, 14, dim);
        }
        text(font, "Clips go to {s}", .{app.cfg.dir}, 24, height - 28, 13, dim);

        rl.EndDrawing();
    }
}

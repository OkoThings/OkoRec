//! okorec: GPU screen recorder with an instant-replay buffer.
//!
//!   okorec [options]     run the recorder (window unless --headless)
//!   okorec save          save the replay buffer of the running instance
//!   okorec record        start/stop recording to disk in the running instance
//!   okorec fps N         change the capture rate, live, and remember it
//!   okorec probe         test the GPU encode path
const std = @import("std");
const linux = std.os.linux;
const c = @import("c.zig").c;
const util = @import("util.zig");
const egl = @import("egl.zig");
const cuda_mod = @import("cuda.zig");
const nvenc = @import("nvenc.zig");
const portal = @import("portal.zig");
const mkv = @import("mkv.zig");
const notify = @import("notify.zig");
const sound = @import("sound.zig");
const ui = @import("ui.zig");
const Ring = @import("ring.zig").Ring;
const Pipeline = @import("pipeline.zig").Pipeline;
const Capture = @import("capture.zig").Capture;
const KmsCapture = @import("kms_capture.zig").KmsCapture;
const Audio = @import("audio.zig").Audio;
const Recorder = @import("record.zig").Recorder;

const gpa = std.heap.c_allocator;

pub const Config = struct {
    fps: u32 = 60,
    /// Whether --fps was given (otherwise the rate last picked in the window is used).
    fps_given: bool = false,
    seconds: u32 = 30,
    cq: u8 = 23,
    dir: []const u8 = "",
    source: enum { kms, portal } = .kms,
    /// Portal only: DMA-BUF frames instead of shared memory.
    zero_copy: bool = false,
    /// KMS only: override HDR detection (null = automatic).
    hdr: ?egl.Transfer = null,
    sdr_white: f32 = 203,
    audio: bool = true,
    /// Play a short sound when a clip is saved or a recording starts/stops.
    sound: bool = true,
    headless: bool = false,
    debug: bool = false,
};

/// Everything the control thread (signals or the window) works with.
pub const App = struct {
    cfg: Config,
    ring: Ring,
    pipe: *Pipeline,
    kms: ?*KmsCapture = null,
    audio: ?*Audio = null,
    recorder: Recorder,
    /// Last thing that happened, shown in the window.
    message_buf: [700]u8 = undefined,
    message_len: usize = 0,
    message_ns: i64 = 0,

    pub fn message(self: *const App) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    fn say(self: *App, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.message_buf, fmt, args) catch "";
        self.message_len = text.len;
        self.message_ns = util.nowNs();
        util.log("{s}\n", .{text});
    }

    fn clipPath(self: *App, buf: []u8, kind: []const u8) ![:0]u8 {
        util.mkdirAll(self.cfg.dir);
        var now = c.time(null);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&now, &tm);
        var stamp: [32]u8 = undefined;
        const n = c.strftime(&stamp, stamp.len, "%Y%m%d-%H%M%S", &tm);
        return std.fmt.bufPrintZ(buf, "{s}/{s}-{s}.mkv", .{ self.cfg.dir, kind, stamp[0..n] });
    }

    fn opusHead(self: *App) ?[]const u8 {
        const a = self.audio orelse return null;
        return if (a.ready.load(.acquire)) &a.head else null;
    }

    fn cue(self: *App, which: sound.Cue) void {
        if (self.cfg.sound) sound.play(which);
    }

    pub fn fps(self: *const App) u32 {
        return self.pipe.fps.load(.monotonic);
    }

    /// Changes the capture rate on the fly and remembers it for next time.
    pub fn setFps(self: *App, value: u32) void {
        if (value == self.fps()) return;
        self.pipe.fps.store(value, .monotonic);
        self.say("Capturing at {d} fps", .{value});
        storeFps(value);
    }

    pub fn saveReplay(self: *App) void {
        self.writeReplay() catch |e| {
            self.cue(.failed);
            self.say("Replay not saved: {s}", .{@errorName(e)});
            notify.send("Replay not saved", @errorName(e));
        };
    }

    fn writeReplay(self: *App) !void {
        const t0 = util.nowNs();
        const snap = try self.ring.snapshot();
        defer self.ring.release(snap);
        // Start at the first video keyframe.
        var first: usize = 0;
        while (first < snap.len and !(snap[first].track == 0 and snap[first].keyframe)) first += 1;
        const packets = snap[first..];
        if (packets.len == 0) return error.NothingRecordedYet;

        var path_buf: [600]u8 = undefined;
        const path = try self.clipPath(&path_buf, "replay");
        var mux = try mkv.Muxer.begin(gpa, path, .{ .width = self.pipe.width, .height = self.pipe.height, .fps = self.fps() }, packets[0], self.opusHead());
        try mux.writeGops(packets);
        const bytes = mux.pos;
        try mux.finish();

        var last_video = packets[0].pts_ns;
        for (packets) |p| {
            if (p.track == 0) last_video = p.pts_ns;
        }
        const secs = @as(f64, @floatFromInt(last_video - packets[0].pts_ns)) / 1e9;
        const mb = @as(f64, @floatFromInt(bytes)) / 1e6;
        self.cue(.saved);
        self.say("Saved {s} ({d:.0} s, {d:.1} MB, {d} ms)", .{ path, secs, mb, @divTrunc(util.nowNs() - t0, std.time.ns_per_ms) });
        var body: [700]u8 = undefined;
        notify.send("Replay saved", std.fmt.bufPrint(&body, "{d:.0} s, {d:.1} MB\n{s}", .{ secs, mb, path }) catch "");
    }

    pub fn toggleRecording(self: *App) void {
        if (self.recorder.active.load(.acquire)) {
            self.recorder.stop();
            self.cue(.saved);
            self.say("Recording stopped: {s}", .{self.recorder.path()});
            notify.send("Recording stopped", self.recorder.path());
            return;
        }
        var path_buf: [600]u8 = undefined;
        const path = self.clipPath(&path_buf, "recording") catch return;
        self.recorder.start(path) catch |e| {
            self.cue(.failed);
            self.say("Recording not started: {s}", .{@errorName(e)});
            return;
        };
        self.cue(.started);
        self.say("Recording to {s}", .{path});
        notify.send("Recording started", path);
    }

    pub const Signal = enum { none, quit };

    /// Handles one pending signal from the signalfd, if any.
    pub fn handleSignal(self: *App, sfd: i32) Signal {
        var info: linux.signalfd_siginfo = undefined;
        const rc = linux.read(sfd, @ptrCast(&info), @sizeOf(linux.signalfd_siginfo));
        if (util.isErr(rc) or rc != @sizeOf(linux.signalfd_siginfo)) return .none;
        if (info.signo == @intFromEnum(linux.SIG.USR1)) {
            self.saveReplay();
            return .none;
        }
        if (info.signo == @intFromEnum(linux.SIG.HUP)) {
            if (storedFps()) |v| self.setFps(v);
            return .none;
        }
        if (info.signo == @intFromEnum(linux.SIG.USR2)) {
            self.toggleRecording();
            return .none;
        }
        return .quit;
    }
};

/// The capture rate last chosen in the window or with `okorec fps`.
fn storedFps() ?u32 {
    var pbuf: [512]u8 = undefined;
    var fbuf: [16]u8 = undefined;
    const text = util.readFile(util.statePath(&pbuf, "fps") orelse return null, &fbuf) orelse return null;
    const v = std.fmt.parseInt(u32, std.mem.trim(u8, text, " \n"), 10) catch return null;
    return if (v > 0 and v <= 480) v else null;
}

fn storeFps(value: u32) void {
    var pbuf: [512]u8 = undefined;
    var nbuf: [16]u8 = undefined;
    const p = util.statePath(&pbuf, "fps") orelse return;
    util.writeFile(p, std.fmt.bufPrint(&nbuf, "{d}\n", .{value}) catch return) catch {};
}

/// `okorec fps N`: remember the rate and tell a running instance, if any.
fn changeFps(value: u32) !void {
    storeFps(value);
    signalRunning(.HUP) catch util.log("okorec: not running; {d} fps will be used at the next start\n", .{value});
}

/// Where the KMS helper lives: $OKOREC_KMS_HELPER, else next to this
/// executable (packaged installs), else ~/.local/bin.
fn findHelper(buf: []u8) ![:0]u8 {
    if (util.env("OKOREC_KMS_HELPER")) |h| return std.fmt.bufPrintZ(buf, "{s}", .{h});
    var exe_buf: [400]u8 = undefined;
    const n = linux.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
    if (!util.isErr(n)) {
        if (std.mem.lastIndexOfScalar(u8, exe_buf[0..n], '/')) |slash| {
            const p = try std.fmt.bufPrintZ(buf, "{s}/okorec-kms", .{exe_buf[0..slash]});
            if (!util.isErr(linux.access(p.ptr, linux.X_OK))) return p;
        }
    }
    return std.fmt.bufPrintZ(buf, "{s}/.local/bin/okorec-kms", .{util.env("HOME") orelse ""});
}

fn pidPath(buf: []u8) [:0]u8 {
    const dir = util.env("XDG_RUNTIME_DIR") orelse "/tmp";
    return std.fmt.bufPrintZ(buf, "{s}/okorec.pid", .{dir}) catch unreachable;
}

/// `okorec probe`: bring up the whole GPU path without capturing anything.
fn probe() !void {
    var gpu = try egl.Gpu.init();
    gpu.describe();
    var mods: [64]u64 = undefined;
    util.log("importable XRGB8888 modifiers: {d}\n", .{gpu.modifiers(egl.DRM_FORMAT_XRGB8888, &mods).len});
    const target = try gpu.createTarget(1920, 1080);
    var cuda = try cuda_mod.Cuda.init();
    var bridge = try cuda_mod.Bridge.init(&cuda, target.tex, egl.GL_TEXTURE_2D, 1920, 1080);
    var enc = try nvenc.Encoder.init(cuda.ctx, bridge.dev_ptr, bridge.pitch, .{ .width = 1920, .height = 1080, .fps = 60, .cq = 23 });
    const t0 = util.nowNs();
    const n = 300;
    for (0..n) |i| {
        try bridge.pull();
        _ = (try enc.encode(i, i == 0)) orelse continue;
        enc.release();
    }
    const ms = @as(f64, @floatFromInt(util.nowNs() - t0)) / 1e6 / n;
    util.log("nvenc ok: 1080p HEVC at {d:.2} ms/frame\n", .{ms});
}

/// `okorec save` / `okorec record`: signal the running instance.
fn signalRunning(sig: linux.SIG) !void {
    var pbuf: [256]u8 = undefined;
    var buf: [32]u8 = undefined;
    const text = util.readFile(pidPath(&pbuf), &buf) orelse return error.NotRunning;
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, text, " \n"), 10) catch return error.NotRunning;
    if (util.isErr(linux.kill(pid, sig))) return error.NotRunning;
}

/// Set when capture dies on its own, so the process exits non-zero.
var capture_failed: std.atomic.Value(bool) = .init(false);

fn portalThread(cap: *Capture, pw_fd: i32, node_id: u32) void {
    cap.run(pw_fd, node_id) catch |e| {
        capture_failed.store(true, .release);
        util.log("capture stopped: {s}\n", .{@errorName(e)});
    };
    // Wake the main thread so the process exits.
    _ = linux.kill(linux.getpid(), .TERM);
}

fn kmsThread(cap: *KmsCapture) void {
    cap.run() catch |e| {
        capture_failed.store(true, .release);
        switch (e) {
            error.HelperLacksCapSysAdmin => util.log(
                \\capture stopped: {s} may not read the screen yet. Grant it once with
                \\  sudo setcap cap_sys_admin+ep {s}
                \\or run with --portal to capture through the desktop portal instead.
                \\
            , .{ cap.helper_path, cap.helper_path }),
            else => util.log("capture stopped: {s}\n", .{@errorName(e)}),
        }
    };
    _ = linux.kill(linux.getpid(), .TERM);
}

fn audioThread(audio: *Audio) void {
    audio.run() catch |e| util.log("audio stopped: {s} (recording continues without sound)\n", .{@errorName(e)});
}

fn run(cfg: Config) !void {
    // Signals are handled synchronously through a signalfd on this thread;
    // block them before any other thread exists.
    var set = linux.sigemptyset();
    for ([_]linux.SIG{ .INT, .TERM, .HUP, .USR1, .USR2 }) |sig| linux.sigaddset(&set, sig);
    _ = linux.sigprocmask(linux.SIG.BLOCK, &set, null);
    const sfd: i32 = @intCast(linux.signalfd(-1, &set, linux.SFD.CLOEXEC | @as(u32, if (cfg.headless) 0 else linux.SFD.NONBLOCK)));

    // One instance per session: `okorec save` and the shortcuts address it
    // through the pidfile.
    var pid_buf: [256]u8 = undefined;
    var old_buf: [32]u8 = undefined;
    if (util.readFile(pidPath(&pid_buf), &old_buf)) |text| {
        if (std.fmt.parseInt(i32, std.mem.trim(u8, text, " \n"), 10)) |old| {
            if (old > 0 and !util.isErr(linux.kill(old, @enumFromInt(0)))) return error.AlreadyRunning;
        } else |_| {}
    }

    const pipe = try gpa.create(Pipeline);
    const app = try gpa.create(App);
    app.* = .{
        .cfg = cfg,
        .ring = Ring.init(gpa, cfg.seconds),
        .pipe = pipe,
        .recorder = .{ .gpa = gpa, .ring = &app.ring, .pipe = pipe, .audio = null },
    };
    pipe.* = .{ .gpa = gpa, .opt = .{ .cq = cfg.cq, .debug = cfg.debug }, .ring = &app.ring, .fps = .init(cfg.fps) };

    var session: ?portal.Session = null;
    var portal_cap: ?*Capture = null;
    var helper_buf: [512]u8 = undefined;
    switch (cfg.source) {
        .portal => {
            session = try portal.open();
            const cap = try gpa.create(Capture);
            cap.* = .{ .pipe = pipe, .zero_copy = cfg.zero_copy };
            portal_cap = cap;
            (try std.Thread.spawn(.{}, portalThread, .{ cap, session.?.pw_fd, session.?.node_id })).detach();
        },
        .kms => {
            const helper = try findHelper(&helper_buf);
            const cap = try gpa.create(KmsCapture);
            cap.* = .{ .pipe = pipe, .helper_path = helper, .force_transfer = cfg.hdr, .sdr_white = cfg.sdr_white };
            app.kms = cap;
            (try std.Thread.spawn(.{}, kmsThread, .{cap})).detach();
        },
    }
    if (cfg.audio) {
        const audio = try gpa.create(Audio);
        audio.* = .{ .gpa = gpa, .ring = &app.ring };
        app.audio = audio;
        app.recorder.audio = audio;
        (try std.Thread.spawn(.{}, audioThread, .{audio})).detach();
    }

    var pbuf: [256]u8 = undefined;
    var nbuf: [16]u8 = undefined;
    const pid_path = pidPath(&pbuf);
    try util.writeFile(pid_path, try std.fmt.bufPrint(&nbuf, "{d}\n", .{linux.getpid()}));
    util.log("okorec: keeping the last {d} s. `okorec save` saves a clip, `okorec record` toggles recording, Ctrl-C quits.\n", .{cfg.seconds});

    if (cfg.headless) {
        while (app.handleSignal(sfd) != .quit) {}
    } else {
        ui.run(app, sfd);
    }

    // Let an active recording finalise its file before we go.
    app.recorder.stop();
    var waited: u32 = 0;
    while (app.recorder.busy.load(.acquire) and waited < 50) : (waited += 1) {
        const ts: linux.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }
    if (portal_cap) |cap| cap.quit();
    if (app.kms) |cap| cap.quit();
    if (app.audio) |a| a.quit();
    _ = linux.unlink(pid_path);
    if (session) |*s| s.close();
    if (capture_failed.load(.acquire)) return error.CaptureFailed;
}

pub fn main(init: std.process.Init.Minimal) void {
    var cfg = Config{};
    var dir_buf: [512]u8 = undefined;
    cfg.dir = std.fmt.bufPrint(&dir_buf, "{s}/Videos/okorec", .{util.env("HOME") orelse "/tmp"}) catch "/tmp";

    var cmd: enum { run, save, record, fps, probe, version } = .run;
    var args = init.args.iterate();
    _ = args.skip();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "save")) {
            cmd = .save;
        } else if (std.mem.eql(u8, a, "record")) {
            cmd = .record;
        } else if (std.mem.eql(u8, a, "fps")) {
            cmd = .fps;
            cfg.fps = std.fmt.parseInt(u32, args.next() orelse "", 10) catch usage();
            cfg.fps_given = true;
        } else if (std.mem.eql(u8, a, "--version")) {
            cmd = .version;
        } else if (std.mem.eql(u8, a, "probe")) {
            cmd = .probe;
        } else if (std.mem.eql(u8, a, "--fps")) {
            cfg.fps = std.fmt.parseInt(u32, args.next() orelse "", 10) catch usage();
            cfg.fps_given = true;
        } else if (std.mem.eql(u8, a, "--seconds")) {
            cfg.seconds = std.fmt.parseInt(u32, args.next() orelse "", 10) catch usage();
        } else if (std.mem.eql(u8, a, "--cq")) {
            cfg.cq = std.fmt.parseInt(u8, args.next() orelse "", 10) catch usage();
        } else if (std.mem.eql(u8, a, "--portal")) {
            cfg.source = .portal;
        } else if (std.mem.eql(u8, a, "--zero-copy")) {
            cfg.zero_copy = true;
        } else if (std.mem.eql(u8, a, "--hdr")) {
            const v = args.next() orelse usage();
            cfg.hdr = if (std.mem.eql(u8, v, "on")) .pq else if (std.mem.eql(u8, v, "off")) .srgb else if (std.mem.eql(u8, v, "auto")) null else usage();
        } else if (std.mem.eql(u8, a, "--sdr-white")) {
            cfg.sdr_white = std.fmt.parseFloat(f32, args.next() orelse "") catch usage();
        } else if (std.mem.eql(u8, a, "--no-audio")) {
            cfg.audio = false;
        } else if (std.mem.eql(u8, a, "--no-sound")) {
            cfg.sound = false;
        } else if (std.mem.eql(u8, a, "--headless")) {
            cfg.headless = true;
        } else if (std.mem.eql(u8, a, "--debug")) {
            cfg.debug = true;
        } else if (std.mem.eql(u8, a, "--dir")) {
            cfg.dir = args.next() orelse usage();
        } else usage();
    }
    if (!cfg.fps_given) cfg.fps = storedFps() orelse cfg.fps;
    if (cfg.fps == 0 or cfg.fps > 480 or cfg.seconds == 0 or cfg.cq > 51) usage();

    const result = switch (cmd) {
        .run => run(cfg),
        .save => signalRunning(.USR1),
        .record => signalRunning(.USR2),
        .fps => changeFps(cfg.fps),
        .probe => probe(),
        .version => util.writeAll(1, "okorec " ++ @import("build_options").version ++ "\n"),
    };
    result catch |e| {
        util.log("okorec: {s}\n", .{@errorName(e)});
        linux.exit_group(1);
    };
    // NVIDIA's libraries can hang in their exit handlers; skip them.
    linux.exit_group(0);
}

fn usage() noreturn {
    util.log(
        \\usage: okorec [--fps N] [--seconds N] [--cq 0-51] [--dir PATH]
        \\            [--headless] [--no-audio] [--no-sound] [--debug]
        \\            [--hdr auto|on|off] [--sdr-white NITS]   KMS capture (default)
        \\            [--portal [--zero-copy]]                 capture through the desktop portal instead
        \\       okorec save      save the replay buffer of the running instance
        \\       okorec record    start/stop recording to disk in the running instance
        \\       okorec fps N     change the capture rate (also of the running instance) and remember it
        \\       okorec --version
        \\       okorec probe     check the GPU encode path
        \\
    , .{});
    linux.exit_group(2);
}

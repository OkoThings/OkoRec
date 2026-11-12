//! The part every capture source shares: a GL "target" texture holding the
//! current frame in sRGB, bridged through CUDA into NVENC, with the encoded
//! packets going into the replay ring. Runs entirely on the capture thread.
const std = @import("std");
const egl = @import("egl.zig");
const cuda_mod = @import("cuda.zig");
const nvenc = @import("nvenc.zig");
const hevc = @import("hevc.zig");
const Ring = @import("ring.zig").Ring;
const util = @import("util.zig");

pub const Options = struct {
    cq: u8 = 23,
    /// Maximum distance between keyframes.
    gop_ns: i64 = 2 * std.time.ns_per_s,
    debug: bool = false,
};

pub const Pipeline = struct {
    gpa: std.mem.Allocator,
    opt: Options,
    ring: *Ring,

    gpu: egl.Gpu = undefined,
    cuda: cuda_mod.Cuda = undefined,
    width: u32 = 0,
    height: u32 = 0,
    /// Scratch texture a source binds its incoming DMA-BUF to.
    source: egl.Imported = undefined,
    target: egl.Imported = undefined,
    bridge: cuda_mod.Bridge = undefined,
    enc: ?nvenc.Encoder = null,
    last_idr: i64 = 0,
    frames: std.atomic.Value(u64) = .init(0),
    /// Set by other threads to make the next frame a keyframe.
    want_idr: std.atomic.Value(bool) = .init(false),
    /// Capture rate. Sources re-read it on every frame, so it can be changed
    /// while running; the encoder keeps the rate it was created with, which
    /// only feeds its (unused, we run constant-quality) bitrate budgeting.
    fps: std.atomic.Value(u32) = .init(60),

    /// Creates the GL and CUDA contexts on the calling thread.
    pub fn init(self: *Pipeline) !void {
        // Seen once in ~20 starts: eglMakeCurrent fails while the window's own
        // GL context is being created on the main thread. Try again shortly.
        var attempt: u32 = 0;
        self.gpu = while (true) : (attempt += 1) {
            break egl.Gpu.init() catch |e| {
                if (attempt >= 4) return e;
                util.log("gpu: {s}, retrying\n", .{@errorName(e)});
                const ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 150 * std.time.ns_per_ms };
                _ = std.os.linux.nanosleep(&ts, null);
                continue;
            };
        };
        self.cuda = try cuda_mod.Cuda.init();
        self.source = self.gpu.createSource();
    }

    pub fn ready(self: *const Pipeline) bool {
        return self.enc != null;
    }

    /// Sets the frame size; the first call creates the encoder.
    pub fn configure(self: *Pipeline, width: u32, height: u32) !void {
        if (self.enc != null) {
            if (width != self.width or height != self.height) return error.ResolutionChangeUnsupported;
            return;
        }
        self.width = width;
        self.height = height;
        self.target = try self.gpu.createTarget(width, height);
        self.bridge = try cuda_mod.Bridge.init(&self.cuda, self.target.tex, egl.GL_TEXTURE_2D, width, height);
        self.enc = try nvenc.Encoder.init(self.cuda.ctx, self.bridge.dev_ptr, self.bridge.pitch, .{
            .width = width,
            .height = height,
            .fps = self.fps.load(.monotonic),
            .cq = self.opt.cq,
        });
    }

    /// Encodes whatever is in the target texture as the frame for `now`.
    pub fn encodeTarget(self: *Pipeline, now: i64) !void {
        if (self.opt.debug and self.frames.load(.monotonic) % 120 == 5)
            util.log("debug: brightest sampled pixel {any}\n", .{self.gpu.peek(self.target, self.width, self.height)});
        try self.bridge.pull();
        const enc = &self.enc.?;
        const force_idr = self.want_idr.swap(false, .acq_rel) or self.last_idr == 0 or now - self.last_idr >= self.opt.gop_ns;
        const pkt = (try enc.encode(@intCast(now), force_idr)) orelse return;
        defer enc.release();
        const data = try hevc.toLengthPrefixed(self.gpa, pkt.data);
        if (pkt.keyframe) self.last_idr = now;
        try self.ring.push(data, now, pkt.keyframe, 0);
        _ = self.frames.fetchAdd(1, .monotonic);
    }
};

//! Portal capture source: asks GNOME for a screencast through
//! xdg-desktop-portal and receives frames over PipeWire, either as DMA-BUFs
//! (zero-copy) or as shared memory. Needs no privileges; the alternative is
//! kms_capture.zig.
const std = @import("std");
const c = @import("c.zig").c;
const pod = @import("pod.zig");
const egl = @import("egl.zig");
const Pipeline = @import("pipeline.zig").Pipeline;
const util = @import("util.zig");

fn u(x: anytype) u32 {
    return @intCast(x);
}

pub const Capture = struct {
    pipe: *Pipeline,
    /// Take frames as DMA-BUFs (no CPU copy). GNOME 48 delivers unconverted,
    /// far-too-dark pixels on that path while the monitor is in HDR mode.
    zero_copy: bool = false,

    loop: std.atomic.Value(?*c.pw_main_loop) = .init(null),
    stream: ?*c.pw_stream = null,
    hook: c.spa_hook = std.mem.zeroes(c.spa_hook),
    events: c.pw_stream_events = std.mem.zeroes(c.pw_stream_events),
    pod_buf: [4096]u8 align(8) = undefined,

    mods: [64]u64 = undefined,
    n_mods: usize = 0,

    fourcc: u32 = 0,
    modifier: u64 = egl.DRM_FORMAT_MOD_INVALID,
    next_due: i64 = 0,
    failed: bool = false,
    /// CPU-copied frames instead of DMA-BUFs.
    shm: bool = false,

    /// Blocks until `quit` is called or the stream dies.
    pub fn run(self: *Capture, pw_fd: i32, node_id: u32) !void {
        try self.pipe.init();
        self.n_mods = self.pipe.gpu.modifiers(egl.DRM_FORMAT_XRGB8888, &self.mods).len;
        if (self.n_mods == 0) {
            self.mods[0] = egl.DRM_FORMAT_MOD_INVALID;
            self.n_mods = 1;
        }
        self.shm = !self.zero_copy;

        @import("c.zig").pw_init(null, null);
        const loop = c.pw_main_loop_new(null) orelse return error.PipeWireLoop;
        const ctx = c.pw_context_new(c.pw_main_loop_get_loop(loop), null, 0) orelse return error.PipeWireContext;
        const core = c.pw_context_connect_fd(ctx, pw_fd, null, 0) orelse return error.PipeWireConnect;
        const props = c.pw_properties_new(
            c.PW_KEY_MEDIA_TYPE,
            "Video",
            c.PW_KEY_MEDIA_CATEGORY,
            "Capture",
            c.PW_KEY_MEDIA_ROLE,
            "Screen",
            @as(?[*:0]const u8, null),
        );
        self.stream = c.pw_stream_new(core, "okorec", props) orelse return error.PipeWireStream;

        self.events.version = c.PW_VERSION_STREAM_EVENTS;
        self.events.state_changed = onStateChanged;
        self.events.param_changed = onParamChanged;
        self.events.process = onProcess;
        c.pw_stream_add_listener(self.stream, &self.hook, &self.events, self);

        var b = pod.Builder{ .buf = &self.pod_buf };
        var params = [_][*c]const c.struct_spa_pod{
            @ptrCast(@alignCast(b.ptr(self.putFormat(&b, c.SPA_VIDEO_FORMAT_BGRx, null)))),
            @ptrCast(@alignCast(b.ptr(self.putFormat(&b, c.SPA_VIDEO_FORMAT_BGRA, null)))),
        };
        if (c.pw_stream_connect(self.stream, c.PW_DIRECTION_INPUT, node_id, c.PW_STREAM_FLAG_AUTOCONNECT | c.PW_STREAM_FLAG_MAP_BUFFERS, &params, params.len) < 0)
            return error.PipeWireStreamConnect;

        self.loop.store(loop, .release);
        _ = c.pw_main_loop_run(loop);
        if (self.failed) return error.CaptureFailed;
    }

    /// Safe to call from any thread.
    pub fn quit(self: *Capture) void {
        if (self.loop.load(.acquire)) |loop| _ = c.pw_main_loop_quit(loop);
    }

    fn fail(self: *Capture, err: anyerror) void {
        util.log("capture: {s}\n", .{@errorName(err)});
        self.failed = true;
        self.quit();
    }

    /// Appends an EnumFormat object. With `fixed` null it offers every
    /// modifier we can import and lets the compositor choose.
    fn putFormat(self: *Capture, b: *pod.Builder, spa_format: c_uint, fixed: ?u64) usize {
        const o = b.object(c.SPA_TYPE_OBJECT_Format, c.SPA_PARAM_EnumFormat);
        b.prop(c.SPA_FORMAT_mediaType, 0);
        b.id(c.SPA_MEDIA_TYPE_video);
        b.prop(c.SPA_FORMAT_mediaSubtype, 0);
        b.id(c.SPA_MEDIA_SUBTYPE_raw);
        b.prop(c.SPA_FORMAT_VIDEO_format, 0);
        b.id(spa_format);
        if (self.shm) {
            // No modifier property = shared-memory buffers.
        } else if (fixed) |m| {
            b.prop(c.SPA_FORMAT_VIDEO_modifier, c.SPA_POD_PROP_FLAG_MANDATORY);
            b.long(m);
        } else {
            b.prop(c.SPA_FORMAT_VIDEO_modifier, c.SPA_POD_PROP_FLAG_MANDATORY | c.SPA_POD_PROP_FLAG_DONT_FIXATE);
            const ch = b.choice(.enumeration, pod.T.Long, 8);
            b.raw64(self.mods[0]);
            for (self.mods[0..self.n_mods]) |m| b.raw64(m);
            b.end(ch);
        }
        b.prop(c.SPA_FORMAT_VIDEO_size, 0);
        {
            const ch = b.choice(.range, pod.T.Rectangle, 8);
            for ([_]u32{ 1920, 1080, 1, 1, 16384, 16384 }) |v| b.raw32(v);
            b.end(ch);
        }
        b.prop(c.SPA_FORMAT_VIDEO_framerate, 0);
        b.pair(pod.T.Fraction, 0, 1); // variable: frames arrive on damage
        b.prop(c.SPA_FORMAT_VIDEO_maxFramerate, 0);
        {
            const ch = b.choice(.range, pod.T.Fraction, 8);
            for ([_]u32{ self.pipe.fps.load(.monotonic), 1, 1, 1, self.pipe.fps.load(.monotonic), 1 }) |v| b.raw32(v);
            b.end(ch);
        }
        b.end(o);
        return o;
    }

    fn onStateChanged(data: ?*anyopaque, old: c.enum_pw_stream_state, state: c.enum_pw_stream_state, err: [*c]const u8) callconv(.c) void {
        const self: *Capture = @ptrCast(@alignCast(data));
        _ = old;
        if (state == c.PW_STREAM_STATE_ERROR) {
            util.log("capture: stream error: {s}\n", .{if (err != null) std.mem.span(err) else "?"});
            self.fail(error.StreamError);
        } else if (state == c.PW_STREAM_STATE_UNCONNECTED and self.pipe.ready()) {
            self.fail(error.StreamDisconnected);
        }
    }

    fn onParamChanged(data: ?*anyopaque, id: u32, param: [*c]const c.struct_spa_pod) callconv(.c) void {
        const self: *Capture = @ptrCast(@alignCast(data));
        if (param == null or id != c.SPA_PARAM_Format) return;
        self.formatChanged(@ptrCast(param)) catch |e| self.fail(e);
    }

    fn formatChanged(self: *Capture, p: [*]const u8) !void {
        const find = pod.ObjectIter.find;
        const fmt = (find(p, c.SPA_FORMAT_VIDEO_format) orelse return error.BadFormat).asU32();
        const size = (find(p, c.SPA_FORMAT_VIDEO_size) orelse return error.BadFormat).asPair();
        const no_mod = pod.Prop{ .key = 0, .flags = 0, .type = pod.T.Long, .body = &std.mem.toBytes(egl.DRM_FORMAT_MOD_INVALID) };
        const mod_prop = find(p, c.SPA_FORMAT_VIDEO_modifier) orelse if (self.shm) no_mod else return error.CompositorOfferedNoDmabuf;

        var b = pod.Builder{ .buf = &self.pod_buf };
        if (mod_prop.flags & c.SPA_POD_PROP_FLAG_DONT_FIXATE != 0) {
            // The compositor left the choice to us: pin one modifier and
            // renegotiate. Any of the remaining alternatives is importable.
            const alts = mod_prop.alternatives();
            const chosen = if (mod_prop.type == pod.T.Choice and alts.data.len >= 8)
                std.mem.readInt(u64, alts.data[0..8], .little)
            else
                mod_prop.asU64();
            var params = [_][*c]const c.struct_spa_pod{
                @ptrCast(@alignCast(b.ptr(self.putFormat(&b, fmt, chosen)))),
                @ptrCast(@alignCast(b.ptr(self.putFormat(&b, c.SPA_VIDEO_FORMAT_BGRx, null)))),
                @ptrCast(@alignCast(b.ptr(self.putFormat(&b, c.SPA_VIDEO_FORMAT_BGRA, null)))),
            };
            _ = c.pw_stream_update_params(self.stream, &params, params.len);
            return;
        }

        const fourcc: u32 = switch (fmt) {
            c.SPA_VIDEO_FORMAT_BGRx => egl.DRM_FORMAT_XRGB8888,
            c.SPA_VIDEO_FORMAT_BGRA => egl.DRM_FORMAT_ARGB8888,
            else => return error.UnexpectedPixelFormat,
        };
        self.fourcc = fourcc;
        self.modifier = mod_prop.asU64();
        const first = !self.pipe.ready();
        try self.pipe.configure(size[0], size[1]);
        if (first) util.log("capture: {d}x{d} via portal, {s}, up to {d} fps\n", .{ size[0], size[1], if (self.shm) "shared-memory frames" else "zero-copy DMA-BUF frames", self.pipe.fps.load(.monotonic) });

        // Tell the compositor we want DMA-BUFs and a header per buffer.
        const bo = b.object(c.SPA_TYPE_OBJECT_ParamBuffers, c.SPA_PARAM_Buffers);
        b.prop(c.SPA_PARAM_BUFFERS_dataType, 0);
        b.int(if (self.shm) (1 << c.SPA_DATA_MemFd) | (1 << c.SPA_DATA_MemPtr) else 1 << c.SPA_DATA_DmaBuf);
        b.end(bo);
        const mo = b.object(c.SPA_TYPE_OBJECT_ParamMeta, c.SPA_PARAM_Meta);
        b.prop(c.SPA_PARAM_META_type, 0);
        b.id(c.SPA_META_Header);
        b.prop(c.SPA_PARAM_META_size, 0);
        b.int(@sizeOf(c.struct_spa_meta_header));
        b.end(mo);
        var params = [_][*c]const c.struct_spa_pod{
            @ptrCast(@alignCast(b.ptr(bo))),
            @ptrCast(@alignCast(b.ptr(mo))),
        };
        _ = c.pw_stream_update_params(self.stream, &params, params.len);
    }

    fn onProcess(data: ?*anyopaque) callconv(.c) void {
        const self: *Capture = @ptrCast(@alignCast(data));
        // Only the newest queued frame matters; hand older ones straight back.
        var newest: [*c]c.struct_pw_buffer = null;
        while (true) {
            const pb = c.pw_stream_dequeue_buffer(self.stream);
            if (pb == null) break;
            if (newest != null) _ = c.pw_stream_queue_buffer(self.stream, newest);
            newest = pb;
        }
        if (newest == null) return;
        defer _ = c.pw_stream_queue_buffer(self.stream, newest);
        if (newest.*.buffer == null) return;
        self.frame(newest.*.buffer) catch |e| self.fail(e);
    }

    fn frame(self: *Capture, sb: *c.struct_spa_buffer) !void {
        const pipe = self.pipe;
        if (!pipe.ready() or sb.n_datas == 0) return;
        const d = &sb.datas[0];
        if (!self.shm and d.type != u(c.SPA_DATA_DmaBuf)) return error.NotADmabuf;
        if (d.chunk.*.flags & @as(i32, @intCast(c.SPA_CHUNK_FLAG_CORRUPTED)) != 0) return;

        // Pace to the target rate in case the compositor sends faster.
        const now = util.nowNs();
        const interval = @divTrunc(std.time.ns_per_s, @as(i64, pipe.fps.load(.monotonic)));
        if (now < self.next_due - 2 * std.time.ns_per_ms) return;
        self.next_due = if (now > self.next_due + interval) now + interval else self.next_due + interval;

        if (self.shm) {
            pipe.gpu.upload(pipe.target, d.data orelse return, pipe.width, pipe.height, @intCast(d.chunk.*.stride));
        } else {
            try pipe.gpu.bindDmabuf(&pipe.source, @intCast(d.fd), pipe.width, pipe.height, self.fourcc, @intCast(d.chunk.*.stride), d.chunk.*.offset, self.modifier);
            pipe.gpu.blit(pipe.source, pipe.target, pipe.width, pipe.height);
        }
        try pipe.encodeTarget(now);
    }
};

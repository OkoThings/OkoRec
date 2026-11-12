//! Audio capture through PipeWire, encoded to Opus in 20 ms frames and
//! pushed into the replay ring. Two instances exist: desktop audio (the
//! default output's monitor, ring track 1, always on) and the microphone
//! (default input, ring track 2), which the user switches on and off.
//! Each runs on its own thread.
const std = @import("std");
const c = @import("c.zig").c;
const pod = @import("pod.zig");
const Ring = @import("ring.zig").Ring;
const mkv = @import("mkv.zig");
const util = @import("util.zig");

extern fn opus_encoder_create(fs: i32, channels: c_int, application: c_int, err: *c_int) ?*anyopaque;
extern fn opus_encode_float(st: ?*anyopaque, pcm: [*]const f32, frame_size: c_int, data: [*]u8, max_bytes: i32) i32;
extern fn opus_encoder_ctl(st: ?*anyopaque, request: c_int, ...) c_int;

const rate = 48000;
/// Samples per channel in one Opus frame (20 ms).
const frame = 960;

pub const Source = enum { desktop, mic };

pub const Audio = struct {
    gpa: std.mem.Allocator,
    ring: *Ring,
    source: Source = .desktop,

    /// Mic only: whether the stream should be open. The thread opens and
    /// closes it to follow this, so the system shows the mic as in use only
    /// while it is switched on.
    enabled: std.atomic.Value(bool) = .init(true),
    /// Guards `loop` against being destroyed while another thread quits it.
    loop_mutex: util.Mutex = .{},
    loop: ?*c.pw_main_loop = null,
    stream: ?*c.pw_stream = null,
    hook: c.spa_hook = std.mem.zeroes(c.spa_hook),
    events: c.pw_stream_events = std.mem.zeroes(c.pw_stream_events),
    pod_buf: [512]u8 align(8) = undefined,

    enc: ?*anyopaque = null,
    /// "OpusHead" identification header, the MKV track's codec private data.
    head: [19]u8 = undefined,
    /// True once the encoder exists and `head` is valid.
    ready: std.atomic.Value(bool) = .init(false),
    fifo: [frame * 2 * 2]f32 = undefined,
    fifo_len: usize = 0,
    /// Capture time of the first sample since the last (re)start, and how
    /// many samples have arrived / been encoded since then.
    anchor_ns: i64 = 0,
    received: u64 = 0,
    encoded: u64 = 0,
    /// Recent peak level (0..1), for the UI meter.
    peak: std.atomic.Value(f32) = .init(0),

    fn channelCount(self: *const Audio) u32 {
        return if (self.source == .mic) 1 else 2;
    }

    /// Ring track the packets go to.
    pub fn track(self: *const Audio) u8 {
        return if (self.source == .mic) 2 else 1;
    }

    /// The MKV track description, once the encoder exists.
    pub fn trackInfo(self: *const Audio) ?mkv.AudioTrack {
        if (!self.ready.load(.acquire)) return null;
        return .{ .track = self.track(), .head = &self.head, .name = if (self.source == .mic) "Microphone" else "Desktop" };
    }

    fn initEncoder(self: *Audio) !void {
        var err: c_int = 0;
        const ch = self.channelCount();
        // Voice gets the speech-tuned mode (VOIP), the desktop the music one.
        const app: c_int = if (self.source == .mic) 2048 else 2049;
        self.enc = opus_encoder_create(rate, @intCast(ch), app, &err) orelse return error.OpusInitFailed;
        _ = opus_encoder_ctl(self.enc, 4002, @as(i32, if (self.source == .mic) 64_000 else 160_000)); // SET_BITRATE
        var lookahead: i32 = 0;
        _ = opus_encoder_ctl(self.enc, 4027, &lookahead); // GET_LOOKAHEAD
        @memcpy(self.head[0..8], "OpusHead");
        self.head[8] = 1;
        self.head[9] = @intCast(ch);
        std.mem.writeInt(u16, self.head[10..12], @intCast(lookahead), .little);
        std.mem.writeInt(u32, self.head[12..16], rate, .little);
        std.mem.writeInt(u16, self.head[16..18], 0, .little);
        self.head[18] = 0;
        self.ready.store(true, .release);
    }

    /// Desktop audio: blocks until `quit`.
    pub fn run(self: *Audio) !void {
        try self.initEncoder();
        @import("c.zig").pw_init(null, null);
        try self.session();
    }

    /// Microphone: never returns; opens the stream while `enabled` is set.
    pub fn serve(self: *Audio) void {
        self.initEncoder() catch |e| {
            util.log("microphone unavailable: {s}\n", .{@errorName(e)});
            return;
        };
        @import("c.zig").pw_init(null, null);
        while (true) {
            if (!self.enabled.load(.acquire)) {
                const ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
                _ = std.os.linux.nanosleep(&ts, null);
                continue;
            }
            _ = opus_encoder_ctl(self.enc, 4028); // RESET_STATE
            self.anchor_ns = 0;
            self.session() catch |e| {
                util.log("microphone: {s}\n", .{@errorName(e)});
                const ts: std.os.linux.timespec = .{ .sec = 2, .nsec = 0 };
                _ = std.os.linux.nanosleep(&ts, null);
            };
            self.peak.store(0, .monotonic);
        }
    }

    /// Switches the microphone stream on or off.
    pub fn setEnabled(self: *Audio, on: bool) void {
        self.enabled.store(on, .release);
        if (!on) self.quit();
    }

    /// One PipeWire connection, torn down when its loop is quit.
    fn session(self: *Audio) !void {
        const loop = c.pw_main_loop_new(null) orelse return error.PipeWireLoop;
        defer {
            self.loop_mutex.lock();
            self.loop = null;
            self.loop_mutex.unlock();
            c.pw_main_loop_destroy(loop);
        }
        const ctx = c.pw_context_new(c.pw_main_loop_get_loop(loop), null, 0) orelse return error.PipeWireContext;
        defer c.pw_context_destroy(ctx);
        const core = c.pw_context_connect(ctx, null, 0) orelse return error.PipeWireConnect;
        defer _ = c.pw_core_disconnect(core);
        const props = if (self.source == .mic)
            c.pw_properties_new(
                c.PW_KEY_MEDIA_TYPE,
                "Audio",
                c.PW_KEY_MEDIA_CATEGORY,
                "Capture",
                c.PW_KEY_MEDIA_ROLE,
                "Communication",
                @as(?[*:0]const u8, null),
            )
        else
            c.pw_properties_new(
                c.PW_KEY_MEDIA_TYPE,
                "Audio",
                c.PW_KEY_MEDIA_CATEGORY,
                "Capture",
                c.PW_KEY_MEDIA_ROLE,
                "Music",
                c.PW_KEY_STREAM_CAPTURE_SINK,
                "true",
                @as(?[*:0]const u8, null),
            );
        const stream = c.pw_stream_new(core, if (self.source == .mic) "okorec microphone" else "okorec audio", props) orelse return error.PipeWireStream;
        self.stream = stream;
        defer {
            c.pw_stream_destroy(stream);
            self.stream = null;
        }
        self.hook = std.mem.zeroes(c.spa_hook);
        self.events.version = c.PW_VERSION_STREAM_EVENTS;
        self.events.process = onProcess;
        c.pw_stream_add_listener(stream, &self.hook, &self.events, self);

        var b = pod.Builder{ .buf = &self.pod_buf };
        const o = b.object(c.SPA_TYPE_OBJECT_Format, c.SPA_PARAM_EnumFormat);
        b.prop(c.SPA_FORMAT_mediaType, 0);
        b.id(c.SPA_MEDIA_TYPE_audio);
        b.prop(c.SPA_FORMAT_mediaSubtype, 0);
        b.id(c.SPA_MEDIA_SUBTYPE_raw);
        b.prop(c.SPA_FORMAT_AUDIO_format, 0);
        b.id(c.SPA_AUDIO_FORMAT_F32_LE);
        b.prop(c.SPA_FORMAT_AUDIO_rate, 0);
        b.int(rate);
        b.prop(c.SPA_FORMAT_AUDIO_channels, 0);
        b.int(@intCast(self.channelCount()));
        b.prop(c.SPA_FORMAT_AUDIO_position, 0);
        if (self.source == .mic) b.idArray(&.{c.SPA_AUDIO_CHANNEL_MONO}) else b.idArray(&.{ c.SPA_AUDIO_CHANNEL_FL, c.SPA_AUDIO_CHANNEL_FR });
        b.end(o);
        var params = [_][*c]const c.struct_spa_pod{@ptrCast(@alignCast(b.ptr(o)))};
        if (c.pw_stream_connect(stream, c.PW_DIRECTION_INPUT, 0xffffffff, c.PW_STREAM_FLAG_AUTOCONNECT | c.PW_STREAM_FLAG_MAP_BUFFERS, &params, params.len) < 0)
            return error.PipeWireStreamConnect;

        self.loop_mutex.lock();
        self.loop = loop;
        self.loop_mutex.unlock();
        // Switched off while connecting.
        if (self.source == .mic and !self.enabled.load(.acquire)) return;
        _ = c.pw_main_loop_run(loop);
    }

    pub fn quit(self: *Audio) void {
        self.loop_mutex.lock();
        defer self.loop_mutex.unlock();
        if (self.loop) |loop| _ = c.pw_main_loop_quit(loop);
    }

    fn onProcess(data: ?*anyopaque) callconv(.c) void {
        const self: *Audio = @ptrCast(@alignCast(data));
        while (true) {
            const pb = c.pw_stream_dequeue_buffer(self.stream);
            if (pb == null) break;
            defer _ = c.pw_stream_queue_buffer(self.stream, pb);
            const sb = pb.*.buffer;
            if (sb == null or sb.*.n_datas == 0) continue;
            const d = &sb.*.datas[0];
            const base: [*]const u8 = @ptrCast(d.data orelse continue);
            const n = d.chunk.*.size / @sizeOf(f32);
            const samples: [*]const f32 = @ptrCast(@alignCast(base + d.chunk.*.offset));
            self.feed(samples[0..n]) catch |e| util.log("audio: {s}\n", .{@errorName(e)});
        }
    }

    fn nsOf(samples_per_channel: u64) i64 {
        return @intCast(samples_per_channel * std.time.ns_per_s / rate);
    }

    /// Takes interleaved stereo samples that have just arrived.
    fn feed(self: *Audio, samples: []const f32) !void {
        const channels = self.channelCount();
        const frames_in = samples.len / channels;
        if (frames_in == 0) return;
        var peak: f32 = 0;
        for (samples) |v| peak = @max(peak, @abs(v));
        self.peak.store(@max(peak, self.peak.load(.monotonic) * 0.9), .monotonic);

        // The stream pauses when nothing plays; after a gap, restart the
        // timeline from the wall clock instead of gluing the pieces together.
        const start_ns = util.nowNs() - nsOf(frames_in);
        const expected = self.anchor_ns + nsOf(self.received);
        if (self.anchor_ns == 0 or @abs(start_ns - expected) > 100 * std.time.ns_per_ms) {
            self.anchor_ns = start_ns;
            self.received = 0;
            self.encoded = 0;
            self.fifo_len = 0;
        }
        self.received += frames_in;

        var rest = samples[0 .. frames_in * channels];
        while (rest.len > 0) {
            const n = @min(rest.len, self.fifo.len - self.fifo_len);
            @memcpy(self.fifo[self.fifo_len..][0..n], rest[0..n]);
            self.fifo_len += n;
            rest = rest[n..];
            var off: usize = 0;
            while (self.fifo_len - off >= frame * channels) : (off += frame * channels) {
                var out: [1500]u8 = undefined;
                const len = opus_encode_float(self.enc, self.fifo[off..].ptr, frame, &out, out.len);
                if (len < 0) return error.OpusEncodeFailed;
                const pts = self.anchor_ns + nsOf(self.encoded);
                self.encoded += frame;
                try self.ring.push(try self.gpa.dupe(u8, out[0..@intCast(len)]), pts, false, self.track());
            }
            std.mem.copyForwards(f32, self.fifo[0 .. self.fifo_len - off], self.fifo[off..self.fifo_len]);
            self.fifo_len -= off;
        }
    }
};

//! Desktop audio: captures what the default output device is playing
//! (PipeWire sink monitor), encodes it to Opus in 20 ms frames and pushes
//! the packets into the replay ring as track 1. Runs on its own thread.
const std = @import("std");
const c = @import("c.zig").c;
const pod = @import("pod.zig");
const Ring = @import("ring.zig").Ring;
const util = @import("util.zig");

extern fn opus_encoder_create(fs: i32, channels: c_int, application: c_int, err: *c_int) ?*anyopaque;
extern fn opus_encode_float(st: ?*anyopaque, pcm: [*]const f32, frame_size: c_int, data: [*]u8, max_bytes: i32) i32;
extern fn opus_encoder_ctl(st: ?*anyopaque, request: c_int, ...) c_int;

const rate = 48000;
const channels = 2;
/// Samples per channel in one Opus frame (20 ms).
const frame = 960;

pub const Audio = struct {
    gpa: std.mem.Allocator,
    ring: *Ring,
    bitrate: i32 = 160_000,

    loop: std.atomic.Value(?*c.pw_main_loop) = .init(null),
    stream: ?*c.pw_stream = null,
    hook: c.spa_hook = std.mem.zeroes(c.spa_hook),
    events: c.pw_stream_events = std.mem.zeroes(c.pw_stream_events),
    pod_buf: [512]u8 align(8) = undefined,

    enc: ?*anyopaque = null,
    /// "OpusHead" identification header, the MKV track's codec private data.
    head: [19]u8 = undefined,
    /// True once the encoder exists and `head` is valid.
    ready: std.atomic.Value(bool) = .init(false),
    fifo: [frame * channels * 2]f32 = undefined,
    fifo_len: usize = 0,
    /// Capture time of the first sample since the last (re)start, and how
    /// many samples have arrived / been encoded since then.
    anchor_ns: i64 = 0,
    received: u64 = 0,
    encoded: u64 = 0,
    /// Recent peak level (0..1), for the UI meter.
    peak: std.atomic.Value(f32) = .init(0),

    /// Blocks until `quit`.
    pub fn run(self: *Audio) !void {
        var err: c_int = 0;
        self.enc = opus_encoder_create(rate, channels, 2049, &err) orelse return error.OpusInitFailed; // APPLICATION_AUDIO
        _ = opus_encoder_ctl(self.enc, 4002, self.bitrate); // SET_BITRATE
        var lookahead: i32 = 0;
        _ = opus_encoder_ctl(self.enc, 4027, &lookahead); // GET_LOOKAHEAD
        @memcpy(self.head[0..8], "OpusHead");
        self.head[8] = 1;
        self.head[9] = channels;
        std.mem.writeInt(u16, self.head[10..12], @intCast(lookahead), .little);
        std.mem.writeInt(u32, self.head[12..16], rate, .little);
        std.mem.writeInt(u16, self.head[16..18], 0, .little);
        self.head[18] = 0;
        self.ready.store(true, .release);

        @import("c.zig").pw_init(null, null);
        const loop = c.pw_main_loop_new(null) orelse return error.PipeWireLoop;
        const ctx = c.pw_context_new(c.pw_main_loop_get_loop(loop), null, 0) orelse return error.PipeWireContext;
        const core = c.pw_context_connect(ctx, null, 0) orelse return error.PipeWireConnect;
        const props = c.pw_properties_new(
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
        self.stream = c.pw_stream_new(core, "okorec audio", props) orelse return error.PipeWireStream;
        self.events.version = c.PW_VERSION_STREAM_EVENTS;
        self.events.process = onProcess;
        c.pw_stream_add_listener(self.stream, &self.hook, &self.events, self);

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
        b.int(channels);
        b.prop(c.SPA_FORMAT_AUDIO_position, 0);
        b.idArray(&.{ c.SPA_AUDIO_CHANNEL_FL, c.SPA_AUDIO_CHANNEL_FR });
        b.end(o);
        var params = [_][*c]const c.struct_spa_pod{@ptrCast(@alignCast(b.ptr(o)))};
        if (c.pw_stream_connect(self.stream, c.PW_DIRECTION_INPUT, 0xffffffff, c.PW_STREAM_FLAG_AUTOCONNECT | c.PW_STREAM_FLAG_MAP_BUFFERS, &params, params.len) < 0)
            return error.PipeWireStreamConnect;

        self.loop.store(loop, .release);
        _ = c.pw_main_loop_run(loop);
    }

    pub fn quit(self: *Audio) void {
        if (self.loop.load(.acquire)) |loop| _ = c.pw_main_loop_quit(loop);
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
                try self.ring.push(try self.gpa.dupe(u8, out[0..@intCast(len)]), pts, false, 1);
            }
            std.mem.copyForwards(f32, self.fifo[0 .. self.fifo_len - off], self.fifo[off..self.fifo_len]);
            self.fifo_len -= off;
        }
    }
};

//! Minimal Matroska writer: HEVC video plus optional Opus audio, one cluster per GOP,
//! with duration and a seek index (Cues) patched in at the end.
const std = @import("std");
const linux = std.os.linux;
const util = @import("util.zig");
const Packet = @import("ring.zig").Packet;
const hevc = @import("hevc.zig");

/// Matroska timestamps are in units of this many nanoseconds (0.1 ms, fine
/// enough for 240 fps; block offsets within a cluster then span +-3.2 s).
const tick_ns = 100_000;

/// Fixed-capacity EBML element builder.
fn Ebml(comptime cap: usize) type {
    return struct {
        buf: [cap]u8 = undefined,
        len: usize = 0,
        const Self = @This();

        fn raw(e: *Self, data: []const u8) void {
            @memcpy(e.buf[e.len..][0..data.len], data);
            e.len += data.len;
        }
        fn id(e: *Self, v: u32) void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, .big);
            var i: usize = 0;
            while (b[i] == 0) i += 1;
            e.raw(b[i..]);
        }
        /// 8-byte size field (always, to keep offsets predictable).
        fn size8(e: *Self, v: u64) void {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, v | (1 << 56), .big);
            e.raw(&b);
        }
        fn size(e: *Self, v: u64) void {
            if (v < 127) e.raw(&.{@as(u8, @intCast(v)) | 0x80}) else e.size8(v);
        }
        fn uint(e: *Self, elem: u32, v: u64) void {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, v, .big);
            var i: usize = 0;
            while (i < 7 and b[i] == 0) i += 1;
            e.id(elem);
            e.size(8 - i);
            e.raw(b[i..]);
        }
        /// Unsigned int in a fixed 8 bytes, so it can be patched in place.
        /// Returns the offset of the value within the buffer.
        fn uint8(e: *Self, elem: u32, v: u64) usize {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, v, .big);
            e.id(elem);
            e.size(8);
            e.raw(&b);
            return e.len - 8;
        }
        fn float(e: *Self, elem: u32, v: f64) usize {
            return e.uint8(elem, @bitCast(v));
        }
        fn str(e: *Self, elem: u32, s: []const u8) void {
            e.id(elem);
            e.size(s.len);
            e.raw(s);
        }
        /// Opens a master element; close with `end`.
        fn begin(e: *Self, elem: u32) usize {
            e.id(elem);
            e.size8(0);
            return e.len;
        }
        fn end(e: *Self, at: usize) void {
            std.mem.writeInt(u64, e.buf[at - 8 ..][0..8], (e.len - at) | (1 << 56), .big);
        }
        fn bytes(e: *Self) []const u8 {
            return e.buf[0..e.len];
        }
    };
}

const Cue = struct { ts: u64, pos: u64 };
/// Encoded size of one CuePoint as written by `finish`.
const cue_size = 41;

pub const Muxer = struct {
    gpa: std.mem.Allocator,
    fd: i32,
    pos: u64 = 0,
    /// File offset where the Segment's contents start (Cue/Seek positions
    /// are relative to it).
    segment_start: u64 = 0,
    duration_at: u64 = 0,
    cues_pos_at: u64 = 0,
    base_ns: i64 = 0,
    end_ts: u64 = 0,
    frame_ticks: u64,
    /// Opus pre-skip, in ticks; audio block timestamps include it.
    audio_delay_ticks: u64 = 0,
    cues: std.ArrayList(Cue) = .empty,

    fn write(self: *Muxer, data: []const u8) !void {
        try util.writeAll(self.fd, data);
        self.pos += data.len;
    }

    pub const Video = struct { width: u32, height: u32, fps: u32 };

    /// `first_key` is the keyframe packet the file will start with (its
    /// parameter sets go into the header). `opus_head` adds an audio track.
    pub fn begin(gpa: std.mem.Allocator, path: [*:0]const u8, video: Video, first_key: *const Packet, opus_head: ?[]const u8) !Muxer {
        const ps = hevc.ParamSets.find(first_key.data) orelse return error.NoParameterSets;
        var hv_buf: [1024]u8 = undefined;
        const hvcc = try hevc.buildHvcC(ps, &hv_buf);
        const width = video.width;
        const height = video.height;

        const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
        if (util.isErr(rc)) return error.OpenFailed;
        var self = Muxer{ .gpa = gpa, .fd = @intCast(rc), .base_ns = first_key.pts_ns, .frame_ticks = std.time.ns_per_s / tick_ns / @max(video.fps, 1) };

        var e = Ebml(4096){};
        const head = e.begin(0x1A45DFA3);
        e.uint(0x4286, 1); // EBMLVersion
        e.uint(0x42F7, 1); // EBMLReadVersion
        e.uint(0x42F2, 4); // EBMLMaxIDLength
        e.uint(0x42F3, 8); // EBMLMaxSizeLength
        e.str(0x4282, "matroska");
        e.uint(0x4287, 4); // DocTypeVersion
        e.uint(0x4285, 2); // DocTypeReadVersion
        e.end(head);

        e.id(0x18538067); // Segment, size unknown until finish()
        e.raw(&.{ 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
        self.segment_start = e.len;

        // SeekHead pointing at the Cues we append at the very end.
        const seek_head = e.begin(0x114D9B74);
        const seek = e.begin(0x4DBB);
        e.id(0x53AB); // SeekID
        e.size(4);
        e.raw(&.{ 0x1C, 0x53, 0xBB, 0x6B });
        self.cues_pos_at = e.uint8(0x53AC, 0); // SeekPosition
        e.end(seek);
        e.end(seek_head);

        const info = e.begin(0x1549A966);
        e.uint(0x2AD7B1, tick_ns); // TimestampScale
        e.str(0x4D80, "OkoRec");
        e.str(0x5741, "OkoRec");
        self.duration_at = e.float(0x4489, 0);
        e.end(info);

        const tracks = e.begin(0x1654AE6B);
        const track = e.begin(0xAE);
        e.uint(0xD7, 1); // TrackNumber
        e.uint(0x73C5, 1); // TrackUID
        e.uint(0x83, 1); // video
        e.uint(0x9C, 0); // no lacing
        e.str(0x86, "V_MPEGH/ISO/HEVC");
        e.str(0x63A2, hvcc); // CodecPrivate
        const video_el = e.begin(0xE0);
        e.uint(0xB0, width);
        e.uint(0xBA, height);
        e.end(video_el);
        e.end(track);
        if (opus_head) |oh| {
            const preskip: u64 = std.mem.readInt(u16, oh[10..12], .little);
            const delay_ns = preskip * std.time.ns_per_s / 48000;
            self.audio_delay_ticks = delay_ns / tick_ns;
            const at = e.begin(0xAE);
            e.uint(0xD7, 2); // TrackNumber
            e.uint(0x73C5, 2); // TrackUID
            e.uint(0x83, 2); // audio
            e.uint(0x9C, 0); // no lacing
            e.str(0x86, "A_OPUS");
            e.str(0x63A2, oh); // CodecPrivate
            e.uint(0x56AA, delay_ns); // CodecDelay
            e.uint(0x56BB, 80_000_000); // SeekPreRoll
            const audio = e.begin(0xE1);
            _ = e.float(0xB5, 48000); // SamplingFrequency
            e.uint(0x9F, oh[9]); // Channels
            e.end(audio);
            e.end(at);
        }
        e.end(tracks);

        try self.write(e.bytes());
        return self;
    }

    fn ticks(self: *const Muxer, p: *const Packet) u64 {
        const t: u64 = @intCast(@max(0, @divTrunc(p.pts_ns - self.base_ns, tick_ns)));
        return if (p.track == 1) t + self.audio_delay_ticks else t;
    }

    /// Writes packets as one cluster per GOP. The slice must start with a
    /// video keyframe; audio packets go into whichever cluster they fall in.
    pub fn writeGops(self: *Muxer, packets: []const *Packet) !void {
        var start: usize = 0;
        for (packets, 0..) |p, i| {
            if (i > start and p.track == 0 and p.keyframe) {
                try self.writeCluster(packets[start..i]);
                start = i;
            }
        }
        try self.writeCluster(packets[start..]);
    }

    fn writeCluster(self: *Muxer, packets: []const *Packet) !void {
        if (packets.len == 0) return;
        const cluster_ts = self.ticks(packets[0]);
        var body: u64 = 0;
        // Audio captured just before the first keyframe has no place in the
        // file (it would pile up at timestamp 0).
        for (packets) |p| {
            if (p.pts_ns >= self.base_ns) body += 1 + 8 + 4 + p.data.len;
        }

        var e = Ebml(64){};
        e.id(0x1F43B675);
        var ts = Ebml(16){};
        ts.uint(0xE7, cluster_ts);
        e.size8(ts.len + body);
        e.raw(ts.bytes());
        try self.cues.append(self.gpa, .{ .ts = cluster_ts, .pos = self.pos - self.segment_start });
        try self.write(e.bytes());

        for (packets) |p| {
            if (p.pts_ns < self.base_ns) continue;
            const t = self.ticks(p);
            const diff = @as(i64, @intCast(t)) - @as(i64, @intCast(cluster_ts));
            const rel: i16 = @intCast(std.math.clamp(diff, std.math.minInt(i16), std.math.maxInt(i16)));
            var b = Ebml(32){};
            b.id(0xA3); // SimpleBlock
            b.size8(4 + p.data.len);
            b.raw(&.{0x81 + p.track}); // track number
            var r: [2]u8 = undefined;
            std.mem.writeInt(i16, &r, rel, .big);
            b.raw(&r);
            b.raw(&.{if (p.keyframe or p.track == 1) 0x80 else 0x00});
            try self.write(b.bytes());
            try self.write(p.data);
            if (p.track == 0) self.end_ts = @max(self.end_ts, t + self.frame_ticks);
        }
    }

    /// Appends the index, patches duration/sizes, closes the file.
    pub fn finish(self: *Muxer) !void {
        defer {
            _ = linux.close(self.fd);
            self.cues.deinit(self.gpa);
        }
        const cues_pos = self.pos - self.segment_start;
        var head = Ebml(16){};
        head.id(0x1C53BB6B);
        head.size8(self.cues.items.len * cue_size);
        try self.write(head.bytes());
        for (self.cues.items) |cue| {
            var e = Ebml(64){};
            const point = e.begin(0xBB);
            _ = e.uint8(0xB3, cue.ts); // CueTime
            const tp = e.begin(0xB7);
            e.uint(0xF7, 1); // CueTrack
            _ = e.uint8(0xF1, cue.pos); // CueClusterPosition
            e.end(tp);
            e.end(point);
            std.debug.assert(e.len == cue_size);
            try self.write(e.bytes());
        }

        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, cues_pos, .big);
        try util.pwriteAll(self.fd, &b, self.cues_pos_at);
        std.mem.writeInt(u64, &b, @bitCast(@as(f64, @floatFromInt(self.end_ts))), .big);
        try util.pwriteAll(self.fd, &b, self.duration_at);
        std.mem.writeInt(u64, &b, (self.pos - self.segment_start) | (1 << 56), .big);
        try util.pwriteAll(self.fd, &b, self.segment_start - 8);
    }
};

//! Recording to disk: a writer thread follows the replay ring and appends
//! each finished GOP to an MKV file, so disk I/O never blocks capture.
const std = @import("std");
const linux = std.os.linux;
const mkv = @import("mkv.zig");
const Ring = @import("ring.zig").Ring;
const Packet = @import("ring.zig").Packet;
const Pipeline = @import("pipeline.zig").Pipeline;
const Audio = @import("audio.zig").Audio;
const util = @import("util.zig");

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    ring: *Ring,
    pipe: *Pipeline,
    audio: ?*Audio,

    active: std.atomic.Value(bool) = .init(false),
    /// True from start until the file is finalised.
    busy: std.atomic.Value(bool) = .init(false),
    start_ns: i64 = 0,
    bytes: std.atomic.Value(u64) = .init(0),
    path_buf: [600]u8 = undefined,
    path_len: usize = 0,

    pub fn path(self: *const Recorder) [:0]const u8 {
        return self.path_buf[0..self.path_len :0];
    }

    pub fn start(self: *Recorder, file_path: []const u8) !void {
        if (self.busy.load(.acquire)) return error.StillFinishingPreviousRecording;
        if (!self.pipe.ready()) return error.NothingRecordedYet;
        @memcpy(self.path_buf[0..file_path.len], file_path);
        self.path_buf[file_path.len] = 0;
        self.path_len = file_path.len;
        self.start_ns = util.nowNs();
        self.bytes.store(0, .monotonic);
        self.active.store(true, .release);
        self.busy.store(true, .release);
        // Start the file on a fresh keyframe.
        self.pipe.want_idr.store(true, .release);
        (try std.Thread.spawn(.{}, writer, .{self})).detach();
    }

    /// The writer flushes what is left and finalises the file on its own.
    pub fn stop(self: *Recorder) void {
        self.active.store(false, .release);
    }

    fn writer(self: *Recorder) void {
        self.follow() catch |e| util.log("recording failed: {s}\n", .{@errorName(e)});
        self.active.store(false, .release);
        self.busy.store(false, .release);
    }

    fn follow(self: *Recorder) !void {
        var pending: std.ArrayList(*Packet) = .empty;
        defer {
            self.ring.unrefAll(pending.items);
            pending.deinit(self.gpa);
        }
        var mux: ?mkv.Muxer = null;
        // Only packets pushed from now on belong to this recording.
        var cursor: u64 = blk: {
            const snap = try self.ring.snapshot();
            defer self.ring.release(snap);
            break :blk if (snap.len > 0) snap[snap.len - 1].seq else 0;
        };

        while (true) {
            const stopping = !self.active.load(.acquire);
            const fresh = try self.ring.snapshotAfter(cursor);
            defer self.gpa.free(fresh);
            if (fresh.len > 0) cursor = fresh[fresh.len - 1].seq;
            try pending.appendSlice(self.gpa, fresh);

            if (mux == null) {
                // Wait for the first keyframe; drop whatever precedes it.
                var first: usize = 0;
                while (first < pending.items.len and !(pending.items[first].track == 0 and pending.items[first].keyframe)) first += 1;
                self.ring.unrefAll(pending.items[0..first]);
                pending.replaceRangeAssumeCapacity(0, first, &.{});
                if (pending.items.len > 0) {
                    const head: ?[]const u8 = if (self.audio) |a| (if (a.ready.load(.acquire)) &a.head else null) else null;
                    mux = try mkv.Muxer.begin(self.gpa, self.path().ptr, .{ .width = self.pipe.width, .height = self.pipe.height, .fps = self.pipe.fps.load(.monotonic) }, pending.items[0], head);
                }
            }
            if (mux) |*m| {
                // Everything before the newest keyframe is a complete GOP.
                var end: usize = pending.items.len;
                if (!stopping) {
                    while (end > 0 and !(pending.items[end - 1].track == 0 and pending.items[end - 1].keyframe)) end -= 1;
                    if (end > 0) end -= 1;
                }
                if (end > 0) {
                    try m.writeGops(pending.items[0..end]);
                    self.bytes.store(m.pos, .monotonic);
                    self.ring.unrefAll(pending.items[0..end]);
                    pending.replaceRangeAssumeCapacity(0, end, &.{});
                }
            }
            if (stopping) break;
            const ts: linux.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
            _ = linux.nanosleep(&ts, null);
        }
        if (mux) |*m| {
            try m.finish();
            util.log("recording saved: {s} ({d:.1} MB)\n", .{ self.path(), @as(f64, @floatFromInt(m.pos)) / 1e6 });
        }
    }
};

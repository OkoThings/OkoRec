//! Replay buffer: the last N seconds of encoded packets, kept in RAM.
//! Always starts on a keyframe so a saved clip is decodable from frame one.
const std = @import("std");
const util = @import("util.zig");

pub const Packet = struct {
    /// Length-prefixed NAL units.
    data: []u8,
    /// CLOCK_MONOTONIC capture time.
    pts_ns: i64,
    keyframe: bool,
    /// 0 = video, 1 = desktop audio, 2 = microphone.
    track: u8 = 0,
    /// Position in push order; lets a recording follow the ring.
    seq: u64 = 0,
    /// Guarded by the ring mutex. The ring holds one reference; each
    /// in-progress save holds another.
    refs: u32 = 1,
};

pub const Ring = struct {
    gpa: std.mem.Allocator,
    mutex: util.Mutex = .{},
    items: std.ArrayList(*Packet) = .empty,
    head: usize = 0,
    window_ns: i64,
    bytes: usize = 0,
    next_seq: u64 = 1,
    /// Bytes ever pushed, per track (for bitrate display).
    total_bytes: [3]u64 = @splat(0),

    pub fn init(gpa: std.mem.Allocator, seconds: u32) Ring {
        return .{ .gpa = gpa, .window_ns = @as(i64, seconds) * std.time.ns_per_s };
    }

    fn unref(self: *Ring, p: *Packet) void {
        p.refs -= 1;
        if (p.refs == 0) {
            self.gpa.free(p.data);
            self.gpa.destroy(p);
        }
    }

    /// Takes ownership of `data`. Safe to call from several threads.
    pub fn push(self: *Ring, data: []u8, pts_ns: i64, keyframe: bool, track: u8) !void {
        const p = try self.gpa.create(Packet);
        p.* = .{ .data = data, .pts_ns = pts_ns, .keyframe = keyframe, .track = track };
        self.mutex.lock();
        defer self.mutex.unlock();
        p.seq = self.next_seq;
        self.next_seq += 1;
        try self.items.append(self.gpa, p);
        self.bytes += data.len;
        self.total_bytes[track] += data.len;
        if (track == 0 and keyframe) self.trim(pts_ns);
    }

    /// Drops whole GOPs from the front while a later keyframe still covers
    /// the start of the window.
    fn trim(self: *Ring, now_ns: i64) void {
        const items = self.items.items;
        const cutoff = now_ns - self.window_ns;
        var new_head = self.head;
        var i = self.head + 1;
        while (i < items.len) : (i += 1) {
            if (items[i].track != 0 or !items[i].keyframe) continue;
            if (items[i].pts_ns > cutoff) break;
            new_head = i;
        }
        for (items[self.head..new_head]) |p| {
            self.bytes -= p.data.len;
            self.unref(p);
        }
        self.head = new_head;
        if (self.head > 4096 and self.head > items.len / 2) {
            const live = items.len - self.head;
            std.mem.copyForwards(*Packet, items[0..live], items[self.head..]);
            self.items.shrinkRetainingCapacity(live);
            self.head = 0;
        }
    }

    pub const Stats = struct { bytes: usize, packets: usize, span_ns: i64, total_bytes: [3]u64 };

    pub fn stats(self: *Ring) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        const live = self.items.items[self.head..];
        return .{
            .bytes = self.bytes,
            .packets = live.len,
            .span_ns = if (live.len > 0) live[live.len - 1].pts_ns - live[0].pts_ns else 0,
            .total_bytes = self.total_bytes,
        };
    }

    /// References every packet currently held; pair with `release`.
    /// Capture keeps running while the caller writes them out.
    pub fn snapshot(self: *Ring) ![]*Packet {
        self.mutex.lock();
        defer self.mutex.unlock();
        const out = try self.gpa.dupe(*Packet, self.items.items[self.head..]);
        for (out) |p| p.refs += 1;
        return out;
    }

    /// Like `snapshot`, but only packets pushed after sequence number `seq`.
    pub fn snapshotAfter(self: *Ring, seq: u64) ![]*Packet {
        self.mutex.lock();
        defer self.mutex.unlock();
        const live = self.items.items[self.head..];
        var first = live.len;
        while (first > 0 and live[first - 1].seq > seq) first -= 1;
        const out = try self.gpa.dupe(*Packet, live[first..]);
        for (out) |p| p.refs += 1;
        return out;
    }

    /// Drops references taken by a snapshot without freeing the slice.
    pub fn unrefAll(self: *Ring, packets: []const *Packet) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (packets) |p| self.unref(p);
    }

    pub fn release(self: *Ring, snap: []*Packet) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (snap) |p| self.unref(p);
        self.gpa.free(snap);
    }
};

//! KMS capture source: reads the framebuffers the display is scanning out
//! (primary plane + hardware cursor) straight from the kernel, via the
//! privileged okorec-kms helper. Zero-copy, no compositor involvement, and it
//! sees the real HDR signal.
const std = @import("std");
const linux = std.os.linux;
const kms = @import("kms.zig");
const egl = @import("egl.zig");
const Pipeline = @import("pipeline.zig").Pipeline;
const util = @import("util.zig");

pub const KmsCapture = struct {
    pipe: *Pipeline,
    helper_path: [:0]const u8,
    /// How the scanout buffers are encoded; null = follow the display's HDR
    /// state, re-checked once a second.
    force_transfer: ?egl.Transfer = null,
    transfer: egl.Transfer = .srgb,
    card: ?kms.Card = null,
    ticks: u64 = 0,
    /// Luminance (nits) the compositor gives SDR white in HDR mode.
    sdr_white: f32 = 203,

    sock: i32 = -1,
    stop: std.atomic.Value(bool) = .init(false),
    /// The cursor image, uploaded from the CPU whenever it changes (the
    /// driver refuses to import the cursor plane's linear buffer as a texture).
    cursor_tex: ?egl.Imported = null,
    cursor_fb: u32 = 0,
    cursor_size: [2]u32 = .{ 0, 0 },
    cursor_broken: bool = false,

    /// Blocks until `quit` is called.
    pub fn run(self: *KmsCapture) !void {
        try self.spawnHelper();
        try self.pipe.init();
        // Our own unprivileged handle on the card, to read the HDR state.
        self.card = kms.openActiveCard() catch null;

        var due = util.nowNs();
        while (!self.stop.load(.acquire)) {
            const interval = @divTrunc(std.time.ns_per_s, @as(i64, self.pipe.fps.load(.monotonic)));
            const ts: linux.timespec = .{ .sec = @intCast(@divTrunc(due, std.time.ns_per_s)), .nsec = @intCast(@mod(due, std.time.ns_per_s)) };
            _ = linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = true }, &ts, null);
            const now = util.nowNs();
            // Frames are stamped with their scheduled time, so wake-up
            // jitter doesn't end up in the file. After a stall, resume from
            // now instead of bursting to catch up.
            const stamp = if (now - due > 4 * interval) now else due;
            due = stamp + interval;
            try self.tick(stamp);
        }
    }

    pub fn quit(self: *KmsCapture) void {
        self.stop.store(true, .release);
    }

    fn tick(self: *KmsCapture, now: i64) !void {
        const pipe = self.pipe;
        if (self.ticks % pipe.fps.load(.monotonic) == 0) {
            const t: egl.Transfer = self.force_transfer orelse
                if (self.card != null and self.card.?.pqActive()) .pq else .srgb;
            if (t != self.transfer and pipe.ready()) util.log("capture: display switched to {s}\n", .{if (t == .pq) "HDR (PQ)" else "SDR"});
            self.transfer = t;
        }
        self.ticks += 1;
        var primary: kms.Frame = .{};
        const fd = try self.request(1, &primary);
        defer if (fd) |d| {
            _ = linux.close(d);
        };
        if (primary.width == 0) return; // display off or mid-modeset
        if (fd == null) return error.HelperLacksCapSysAdmin;

        var cursor: kms.Frame = .{};
        const cursor_fd = try self.request(2, &cursor);
        defer if (cursor_fd) |d| {
            _ = linux.close(d);
        };

        // Every tick is encoded. Framebuffer ids can't tell us whether the
        // picture changed: a game flipping between two buffers at twice our
        // rate shows the same id on every tick. Unchanged frames cost a few
        // bytes each.
        const first = !pipe.ready();
        try pipe.configure(primary.width, primary.height);
        if (first) util.log("capture: {d}x{d} via KMS, {s} scanout ({s}), up to {d} fps\n", .{
            primary.width,
            primary.height,
            if (self.transfer == .pq) "HDR" else "SDR",
            kms.fourccStr(primary.fourcc),
            pipe.fps.load(.monotonic),
        });

        try pipe.gpu.bindDmabuf(&pipe.source, fd.?, primary.width, primary.height, primary.fourcc, primary.pitch, primary.offset, primary.modifier);
        try pipe.gpu.draw(pipe.source, pipe.target, 0, 0, primary.width, primary.height, self.transfer, self.sdr_white, false);
        if (cursor_fd) |cfd| {
            if (self.loadCursor(cfd, cursor)) |tex|
                try pipe.gpu.draw(tex, pipe.target, cursor.x, cursor.y, cursor.width, cursor.height, self.transfer, self.sdr_white, true);
        }
        try pipe.encodeTarget(now);
    }

    /// Returns the texture holding the current cursor image, refreshing it
    /// when the cursor plane shows a different framebuffer.
    fn loadCursor(self: *KmsCapture, fd: i32, cursor: kms.Frame) ?egl.Imported {
        if (self.cursor_broken) return null;
        const gpu = &self.pipe.gpu;
        if (self.cursor_tex != null and cursor.fb_id == self.cursor_fb) return self.cursor_tex;
        if (self.cursor_tex == null or cursor.width != self.cursor_size[0] or cursor.height != self.cursor_size[1]) {
            if (self.cursor_tex) |old| gpu.destroy(old);
            self.cursor_tex = gpu.createTarget(cursor.width, cursor.height) catch return null;
            self.cursor_size = .{ cursor.width, cursor.height };
        }
        const len = @as(usize, cursor.pitch) * cursor.height;
        const rc = linux.mmap(null, len, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, cursor.offset);
        if (util.isErr(rc)) {
            util.log("kms: cannot read the cursor image (errno {d}); recording without cursor\n", .{util.errnoOf(rc)});
            self.cursor_broken = true;
            return null;
        }
        defer _ = linux.munmap(@ptrFromInt(rc), len);
        gpu.upload(self.cursor_tex.?, @ptrFromInt(rc), cursor.width, cursor.height, cursor.pitch);
        self.cursor_fb = cursor.fb_id;
        return self.cursor_tex;
    }

    fn spawnHelper(self: *KmsCapture) !void {
        var pair: [2]i32 = undefined;
        if (util.isErr(linux.socketpair(linux.AF.UNIX, linux.SOCK.SEQPACKET, 0, &pair))) return error.SocketPairFailed;
        var fd_buf: [16]u8 = undefined;
        const fd_arg = try std.fmt.bufPrintZ(&fd_buf, "{d}", .{pair[1]});
        const argv = [_:null]?[*:0]const u8{ self.helper_path.ptr, "serve", fd_arg.ptr };
        const envp = [_:null]?[*:0]const u8{};

        const pid = linux.fork();
        if (util.isErr(pid)) return error.ForkFailed;
        if (pid == 0) {
            _ = linux.close(pair[0]);
            _ = linux.execve(self.helper_path.ptr, &argv, &envp);
            linux.exit_group(127);
        }
        _ = linux.close(pair[1]);
        self.sock = pair[0];
    }

    /// Asks the helper for the plane of `plane_type`; returns its DMA-BUF.
    fn request(self: *KmsCapture, plane_type: u8, frame: *kms.Frame) !?i32 {
        if (util.isErr(linux.write(self.sock, &[1]u8{plane_type}, 1))) return error.KmsHelperGone;
        var iov = [1]std.posix.iovec{.{ .base = @ptrCast(frame), .len = @sizeOf(kms.Frame) }};
        var cbuf: [32]u8 align(8) = undefined;
        var hdr: linux.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &cbuf,
            .controllen = cbuf.len,
            .flags = 0,
        };
        const rc = linux.recvmsg(self.sock, &hdr, linux.MSG.CMSG_CLOEXEC);
        if (util.isErr(rc) or rc != @sizeOf(kms.Frame)) {
            util.log("kms: helper {s} did not answer (is it installed?)\n", .{self.helper_path});
            return error.KmsHelperGone;
        }
        if (hdr.controllen >= 20 and std.mem.readInt(i32, cbuf[12..16], .little) == 1)
            return std.mem.readInt(i32, cbuf[16..20], .little);
        return null;
    }
};

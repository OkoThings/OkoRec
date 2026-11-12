//! okorec-kms: the only part of okorec that needs a privilege (CAP_SYS_ADMIN, so
//! the kernel will hand out framebuffer handles). Kept tiny on purpose: it
//! only ever exports what the display planes are showing.
//!
//!   okorec-kms probe      print what each display plane is showing
//!   okorec-kms serve FD   answer frame requests on an inherited socket (used by okorec)
//!
//! Protocol on the socket: the client sends one byte, the DRM plane type it
//! wants (1 primary, 2 cursor). The reply is a `kms.Frame`, with the DMA-BUF
//! attached as a passed fd when there is one.
const std = @import("std");
const linux = std.os.linux;
const kms = @import("kms.zig");
const util = @import("util.zig");

fn probe() !void {
    const card = try kms.openActiveCard();
    for ([_]u32{ 1, 0, 2 }) |plane_type| {
        var skip: usize = 0;
        while (skip < 8) : (skip += 1) {
            var f: kms.Frame = .{};
            const fd = card.grab(plane_type, skip, &f);
            if (f.width == 0) break;
            util.log("{s} plane at {d},{d}: fb {d} {d}x{d} {s} pitch {d} modifier 0x{x} -> {s}\n", .{
                switch (plane_type) {
                    1 => "primary",
                    2 => "cursor",
                    else => "overlay",
                },
                f.x,
                f.y,
                f.fb_id,
                f.width,
                f.height,
                kms.fourccStr(f.fourcc),
                f.pitch,
                f.modifier,
                if (fd != null) "exported" else "no handle (needs CAP_SYS_ADMIN)",
            });
            if (fd) |d| _ = linux.close(d);
        }
    }
}

fn serve(sock: i32) !void {
    const card = try kms.openActiveCard();
    while (true) {
        var req: [1]u8 = undefined;
        const rc = linux.read(sock, &req, 1);
        if (util.isErr(rc) or rc == 0) return; // client went away

        var frame: kms.Frame = .{};
        const fd = card.grab(req[0], 0, &frame);
        defer if (fd) |d| {
            _ = linux.close(d);
        };

        var iov = [1]std.posix.iovec_const{.{ .base = @ptrCast(&frame), .len = @sizeOf(kms.Frame) }};
        // cmsghdr { u64 len; i32 level; i32 type; i32 fd; pad }
        var cbuf: [24]u8 align(8) = @splat(0);
        std.mem.writeInt(u64, cbuf[0..8], 20, .little);
        std.mem.writeInt(i32, cbuf[8..12], linux.SOL.SOCKET, .little);
        std.mem.writeInt(i32, cbuf[12..16], 1, .little); // SCM_RIGHTS
        std.mem.writeInt(i32, cbuf[16..20], fd orelse -1, .little);
        const msg: linux.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = if (fd != null) &cbuf else null,
            .controllen = if (fd != null) cbuf.len else 0,
            .flags = 0,
        };
        if (util.isErr(linux.sendmsg(sock, &msg, linux.MSG.NOSIGNAL))) return;
    }
}

pub fn main(init: std.process.Init.Minimal) void {
    var args = init.args.iterate();
    _ = args.skip();
    const cmd = args.next() orelse "probe";
    const result = if (std.mem.eql(u8, cmd, "serve"))
        serve(std.fmt.parseInt(i32, args.next() orelse "", 10) catch linux.exit_group(2))
    else
        probe();
    result catch |e| {
        util.log("okorec-kms: {s}\n", .{@errorName(e)});
        linux.exit_group(1);
    };
    linux.exit_group(0);
}

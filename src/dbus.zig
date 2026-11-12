//! Minimal D-Bus client: just enough of the wire protocol to talk to
//! xdg-desktop-portal over the session bus (little-endian only).
const std = @import("std");
const linux = std.os.linux;
const util = @import("util.zig");

pub const MsgType = enum(u8) { call = 1, ret = 2, err = 3, signal = 4 };

/// Marshals D-Bus values. Alignment is relative to the buffer start, so a
/// body built on its own stays valid when appended after the 8-aligned header.
pub const Writer = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    pub fn alignTo(w: *Writer, n: usize) void {
        while (w.len % n != 0) : (w.len += 1) w.buf[w.len] = 0;
    }
    pub fn byte(w: *Writer, v: u8) void {
        w.buf[w.len] = v;
        w.len += 1;
    }
    pub fn u32_(w: *Writer, v: u32) void {
        w.alignTo(4);
        std.mem.writeInt(u32, w.buf[w.len..][0..4], v, .little);
        w.len += 4;
    }
    pub fn i32_(w: *Writer, v: i32) void {
        w.u32_(@bitCast(v));
    }
    pub fn boolean(w: *Writer, v: bool) void {
        w.u32_(@intFromBool(v));
    }
    /// Also used for object paths (same wire format).
    pub fn string(w: *Writer, s: []const u8) void {
        w.u32_(@intCast(s.len));
        @memcpy(w.buf[w.len..][0..s.len], s);
        w.len += s.len;
        w.byte(0);
    }
    pub fn signature(w: *Writer, s: []const u8) void {
        w.byte(@intCast(s.len));
        @memcpy(w.buf[w.len..][0..s.len], s);
        w.len += s.len;
        w.byte(0);
    }
    /// Returns a handle to pass to arrayEnd.
    pub fn arrayBegin(w: *Writer, elem_align: usize) [2]usize {
        w.u32_(0);
        const len_pos = w.len - 4;
        w.alignTo(elem_align);
        return .{ len_pos, w.len };
    }
    pub fn arrayEnd(w: *Writer, h: [2]usize) void {
        std.mem.writeInt(u32, w.buf[h[0]..][0..4], @intCast(w.len - h[1]), .little);
    }
    // a{sv} entries
    pub fn dictStr(w: *Writer, key: []const u8, val: []const u8) void {
        w.alignTo(8);
        w.string(key);
        w.signature("s");
        w.string(val);
    }
    pub fn dictU32(w: *Writer, key: []const u8, val: u32) void {
        w.alignTo(8);
        w.string(key);
        w.signature("u");
        w.u32_(val);
    }
    pub fn dictBool(w: *Writer, key: []const u8, val: bool) void {
        w.alignTo(8);
        w.string(key);
        w.signature("b");
        w.boolean(val);
    }
    pub fn bytes(w: *Writer) []const u8 {
        return w.buf[0..w.len];
    }
};

/// Demarshals a message body.
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn alignTo(r: *Reader, n: usize) void {
        r.pos = (r.pos + n - 1) / n * n;
    }
    pub fn byte(r: *Reader) !u8 {
        if (r.pos >= r.data.len) return error.Truncated;
        defer r.pos += 1;
        return r.data[r.pos];
    }
    pub fn u32_(r: *Reader) !u32 {
        r.alignTo(4);
        if (r.pos + 4 > r.data.len) return error.Truncated;
        defer r.pos += 4;
        return std.mem.readInt(u32, r.data[r.pos..][0..4], .little);
    }
    pub fn string(r: *Reader) ![]const u8 {
        const n = try r.u32_();
        if (r.pos + n + 1 > r.data.len) return error.Truncated;
        defer r.pos += n + 1;
        return r.data[r.pos..][0..n];
    }
    pub fn signature(r: *Reader) ![]const u8 {
        const n = try r.byte();
        if (r.pos + n + 1 > r.data.len) return error.Truncated;
        defer r.pos += @as(usize, n) + 1;
        return r.data[r.pos..][0..n];
    }
    /// Begins an array; returns the end offset of its contents.
    pub fn arrayBegin(r: *Reader, elem_align: usize) !usize {
        const n = try r.u32_();
        r.alignTo(elem_align);
        if (r.pos + n > r.data.len) return error.Truncated;
        return r.pos + n;
    }

    fn alignOf(code: u8) usize {
        return switch (code) {
            'y', 'g', 'v' => 1,
            'n', 'q' => 2,
            'b', 'i', 'u', 'h', 's', 'o', 'a' => 4,
            else => 8, // x t d ( {
        };
    }

    /// Skips one complete value described by the front of `sig`, consuming
    /// that type from `sig`.
    pub fn skip(r: *Reader, sig: *[]const u8) !void {
        if (sig.len == 0) return error.BadSignature;
        const code = sig.*[0];
        sig.* = sig.*[1..];
        switch (code) {
            'y' => r.pos += 1,
            'n', 'q' => {
                r.alignTo(2);
                r.pos += 2;
            },
            'b', 'i', 'u', 'h' => {
                r.alignTo(4);
                r.pos += 4;
            },
            'x', 't', 'd' => {
                r.alignTo(8);
                r.pos += 8;
            },
            's', 'o' => _ = try r.string(),
            'g' => _ = try r.signature(),
            'v' => {
                var inner = try r.signature();
                try r.skip(&inner);
            },
            'a' => {
                if (sig.len == 0) return error.BadSignature;
                const end = try r.arrayBegin(alignOf(sig.*[0]));
                skipType(sig);
                r.pos = end;
            },
            '(', '{' => {
                r.alignTo(8);
                const close: u8 = if (code == '(') ')' else '}';
                while (sig.len > 0 and sig.*[0] != close) try r.skip(sig);
                if (sig.len == 0) return error.BadSignature;
                sig.* = sig.*[1..];
            },
            else => return error.BadSignature,
        }
        if (r.pos > r.data.len) return error.Truncated;
    }
};

/// Advances `sig` past one complete type.
fn skipType(sig: *[]const u8) void {
    if (sig.len == 0) return;
    const code = sig.*[0];
    sig.* = sig.*[1..];
    switch (code) {
        'a' => skipType(sig),
        '(', '{' => {
            const close: u8 = if (code == '(') ')' else '}';
            while (sig.len > 0 and sig.*[0] != close) skipType(sig);
            if (sig.len > 0) sig.* = sig.*[1..];
        },
        else => {},
    }
}

pub const Message = struct {
    type: MsgType,
    serial: u32,
    reply_serial: u32 = 0,
    path: []const u8 = "",
    interface: []const u8 = "",
    member: []const u8 = "",
    error_name: []const u8 = "",
    signature: []const u8 = "",
    body: []const u8 = "",
    /// File descriptor received with this message, if any.
    fd: i32 = -1,
};

pub const Call = struct {
    dest: []const u8,
    path: []const u8,
    interface: []const u8,
    member: []const u8,
    signature: []const u8 = "",
    body: []const u8 = "",
};

pub const Connection = struct {
    fd: i32,
    serial: u32 = 0,
    unique_name_buf: [64]u8 = undefined,
    unique_name_len: usize = 0,
    rx: [64 * 1024]u8 = undefined,

    pub fn connectSession() !Connection {
        var path_buf: [108]u8 = undefined;
        var path: []const u8 = "";
        if (util.env("DBUS_SESSION_BUS_ADDRESS")) |addr| {
            if (std.mem.indexOf(u8, addr, "unix:path=")) |i| {
                const rest = addr[i + 10 ..];
                path = rest[0 .. std.mem.indexOfScalar(u8, rest, ',') orelse rest.len];
            }
        }
        if (path.len == 0) {
            path = try std.fmt.bufPrint(&path_buf, "/run/user/{d}/bus", .{linux.getuid()});
        }

        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (util.isErr(rc)) return error.SocketFailed;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);

        var sa: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
        @memset(&sa.path, 0);
        if (path.len >= sa.path.len) return error.PathTooLong;
        @memcpy(sa.path[0..path.len], path);
        if (util.isErr(linux.connect(fd, &sa, @sizeOf(linux.sockaddr.un)))) return error.ConnectFailed;

        var conn = Connection{ .fd = fd };
        try conn.authenticate();

        // Hello() gives us our unique bus name.
        const serial = try conn.send(.{
            .dest = "org.freedesktop.DBus",
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "Hello",
        });
        const reply = try conn.waitReply(serial);
        var r = Reader{ .data = reply.body };
        const name = try r.string();
        @memcpy(conn.unique_name_buf[0..name.len], name);
        conn.unique_name_len = name.len;
        return conn;
    }

    pub fn uniqueName(self: *const Connection) []const u8 {
        return self.unique_name_buf[0..self.unique_name_len];
    }

    pub fn close(self: *Connection) void {
        _ = linux.close(self.fd);
    }

    fn readLine(self: *Connection, buf: []u8) ![]u8 {
        var n: usize = 0;
        while (n < buf.len) {
            const rc = linux.read(self.fd, buf.ptr + n, 1);
            if (util.isErr(rc) or rc == 0) return error.AuthFailed;
            n += 1;
            if (buf[n - 1] == '\n') return buf[0..n];
        }
        return error.AuthFailed;
    }

    fn authenticate(self: *Connection) !void {
        // SASL EXTERNAL: our uid, as hex of its decimal ASCII form.
        var uid_buf: [16]u8 = undefined;
        const uid = try std.fmt.bufPrint(&uid_buf, "{d}", .{linux.getuid()});
        var msg: [96]u8 = undefined;
        var n: usize = 0;
        const head = "\x00AUTH EXTERNAL ";
        @memcpy(msg[0..head.len], head);
        n = head.len;
        for (uid) |ch| {
            const hex = "0123456789abcdef";
            msg[n] = hex[ch >> 4];
            msg[n + 1] = hex[ch & 15];
            n += 2;
        }
        msg[n] = '\r';
        msg[n + 1] = '\n';
        try util.writeAll(self.fd, msg[0 .. n + 2]);

        var line: [256]u8 = undefined;
        if (!std.mem.startsWith(u8, try self.readLine(&line), "OK ")) return error.AuthFailed;
        try util.writeAll(self.fd, "NEGOTIATE_UNIX_FD\r\n");
        if (!std.mem.startsWith(u8, try self.readLine(&line), "AGREE_UNIX_FD")) return error.NoFdPassing;
        try util.writeAll(self.fd, "BEGIN\r\n");
    }

    /// Sends a method call; returns its serial.
    pub fn send(self: *Connection, call: Call) !u32 {
        self.serial += 1;
        var w = Writer{};
        w.byte('l');
        w.byte(@intFromEnum(MsgType.call));
        w.byte(0);
        w.byte(1);
        w.u32_(@intCast(call.body.len));
        w.u32_(self.serial);
        const arr = w.arrayBegin(8);
        const Field = struct { code: u8, sig: []const u8, val: []const u8 };
        const fields = [_]Field{
            .{ .code = 1, .sig = "o", .val = call.path },
            .{ .code = 2, .sig = "s", .val = call.interface },
            .{ .code = 3, .sig = "s", .val = call.member },
            .{ .code = 6, .sig = "s", .val = call.dest },
        };
        for (fields) |f| {
            w.alignTo(8);
            w.byte(f.code);
            w.signature(f.sig);
            w.string(f.val);
        }
        if (call.signature.len > 0) {
            w.alignTo(8);
            w.byte(8);
            w.signature("g");
            w.signature(call.signature);
        }
        w.arrayEnd(arr);
        w.alignTo(8);
        try util.writeAll(self.fd, w.bytes());
        try util.writeAll(self.fd, call.body);
        return self.serial;
    }

    /// Receives exactly `buf.len` bytes, capturing one passed fd if present.
    fn recvExact(self: *Connection, buf: []u8, fd_out: *i32) !void {
        var off: usize = 0;
        while (off < buf.len) {
            var iov = [1]std.posix.iovec{.{ .base = buf.ptr + off, .len = buf.len - off }};
            var cbuf: [64]u8 align(8) = undefined;
            var hdr: linux.msghdr = .{
                .name = null,
                .namelen = 0,
                .iov = &iov,
                .iovlen = 1,
                .control = &cbuf,
                .controllen = cbuf.len,
                .flags = 0,
            };
            const rc = linux.recvmsg(self.fd, &hdr, linux.MSG.CMSG_CLOEXEC);
            if (util.isErr(rc)) {
                if (util.errnoOf(rc) == @intFromEnum(linux.E.INTR)) continue;
                return error.RecvFailed;
            }
            if (rc == 0) return error.ConnectionClosed;
            off += rc;
            // cmsghdr: u64 len, i32 level, i32 type, then data.
            if (hdr.controllen >= 20) {
                const level = std.mem.readInt(i32, cbuf[8..12], .little);
                const ctype = std.mem.readInt(i32, cbuf[12..16], .little);
                if (level == linux.SOL.SOCKET and ctype == 1) // SCM_RIGHTS
                    fd_out.* = std.mem.readInt(i32, cbuf[16..20], .little);
            }
        }
    }

    /// Blocks until the next message arrives. Slices in the result point into
    /// the connection's receive buffer and are valid until the next recv.
    pub fn recv(self: *Connection) !Message {
        var fd: i32 = -1;
        try self.recvExact(self.rx[0..16], &fd);
        if (self.rx[0] != 'l') return error.BigEndianUnsupported;
        const body_len = std.mem.readInt(u32, self.rx[4..8], .little);
        const fields_len = std.mem.readInt(u32, self.rx[12..16], .little);
        const fields_end = 16 + fields_len;
        const body_start = (fields_end + 7) / 8 * 8;
        const total = body_start + body_len;
        if (total > self.rx.len) return error.MessageTooLarge;
        try self.recvExact(self.rx[16..total], &fd);

        var msg = Message{
            .type = @enumFromInt(self.rx[1]),
            .serial = std.mem.readInt(u32, self.rx[8..12], .little),
            .body = self.rx[body_start..total],
            .fd = fd,
        };
        var r = Reader{ .data = self.rx[0..fields_end], .pos = 16 };
        while (r.pos < fields_end) {
            r.alignTo(8);
            if (r.pos >= fields_end) break;
            const code = try r.byte();
            var sig = try r.signature();
            switch (code) {
                1 => msg.path = try r.string(),
                2 => msg.interface = try r.string(),
                3 => msg.member = try r.string(),
                4 => msg.error_name = try r.string(),
                5 => msg.reply_serial = try r.u32_(),
                8 => msg.signature = try r.signature(),
                else => try r.skip(&sig),
            }
        }
        return msg;
    }

    fn reportError(msg: Message) void {
        var r = Reader{ .data = msg.body };
        const text = if (std.mem.startsWith(u8, msg.signature, "s")) (r.string() catch "") else "";
        util.log("dbus error: {s}: {s}\n", .{ msg.error_name, text });
    }

    /// Waits for the reply to the call with the given serial.
    pub fn waitReply(self: *Connection, serial: u32) !Message {
        while (true) {
            const msg = try self.recv();
            if (msg.reply_serial != serial) continue;
            if (msg.type == .err) {
                reportError(msg);
                return error.DBusCallFailed;
            }
            if (msg.type == .ret) return msg;
        }
    }

    /// Waits for a signal `member` on `path`; fails if the call `serial`
    /// (0 = none) gets an error reply in the meantime.
    pub fn waitSignal(self: *Connection, path: []const u8, member: []const u8, serial: u32) !Message {
        while (true) {
            const msg = try self.recv();
            if (msg.type == .err and serial != 0 and msg.reply_serial == serial) {
                reportError(msg);
                return error.DBusCallFailed;
            }
            if (msg.type == .signal and std.mem.eql(u8, msg.path, path) and std.mem.eql(u8, msg.member, member))
                return msg;
        }
    }
};

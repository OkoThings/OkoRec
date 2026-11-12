//! xdg-desktop-portal ScreenCast session: asks the compositor for a monitor
//! stream and returns a PipeWire fd + node id. A restore token is persisted so
//! the share dialog only appears the first time.
const std = @import("std");
const dbus = @import("dbus.zig");
const util = @import("util.zig");

const dest = "org.freedesktop.portal.Desktop";
const obj = "/org/freedesktop/portal/desktop";
const iface = "org.freedesktop.portal.ScreenCast";

pub const Session = struct {
    conn: dbus.Connection,
    pw_fd: i32,
    node_id: u32,
    session_buf: [256]u8 = undefined,
    session_len: usize = 0,

    /// Closing the bus connection ends the screencast session.
    pub fn close(self: *Session) void {
        self.conn.close();
    }
};

fn tokenPath(buf: []u8) ?[:0]u8 {
    return util.statePath(buf, "restore_token");
}

const Step = struct {
    conn: *dbus.Connection,
    n: u32 = 0,
    path_buf: [256]u8 = undefined,
    token_buf: [32]u8 = undefined,

    /// Picks a fresh handle token and returns it; `requestPath` then gives
    /// the object path the portal will emit Response on.
    fn token(self: *Step) []const u8 {
        self.n += 1;
        return std.fmt.bufPrint(&self.token_buf, "okorec{d}", .{self.n}) catch unreachable;
    }
    fn requestPath(self: *Step) []const u8 {
        // Sender ":1.42" becomes "1_42".
        var sender: [64]u8 = undefined;
        const name = self.conn.uniqueName()[1..];
        for (name, 0..) |ch, i| sender[i] = if (ch == '.') '_' else ch;
        return std.fmt.bufPrint(&self.path_buf, "{s}/request/{s}/okorec{d}", .{ obj, sender[0..name.len], self.n }) catch unreachable;
    }
    /// Sends the call and waits for the portal's Response signal.
    /// Returns a reader positioned at the results a{sv}.
    fn run(self: *Step, member: []const u8, sig: []const u8, body: []const u8) !dbus.Reader {
        const serial = try self.conn.send(.{ .dest = dest, .path = obj, .interface = iface, .member = member, .signature = sig, .body = body });
        const msg = try self.conn.waitSignal(self.requestPath(), "Response", serial);
        var r = dbus.Reader{ .data = msg.body };
        const code = try r.u32_();
        if (code != 0) {
            util.log("portal: {s} was {s}\n", .{ member, if (code == 1) "cancelled" else "refused" });
            return error.PortalRequestDenied;
        }
        return r;
    }
};

pub fn open() !Session {
    var s = Session{ .conn = try dbus.Connection.connectSession(), .pw_fd = -1, .node_id = 0 };
    errdefer s.conn.close();
    var step = Step{ .conn = &s.conn };

    // 1. CreateSession
    {
        var w = dbus.Writer{};
        const a = w.arrayBegin(8);
        w.dictStr("handle_token", step.token());
        w.dictStr("session_handle_token", "okorec");
        w.arrayEnd(a);
        var r = try step.run("CreateSession", "a{sv}", w.bytes());
        const end = try r.arrayBegin(8);
        while (r.pos < end) {
            r.alignTo(8);
            const key = try r.string();
            var vsig = try r.signature();
            if (std.mem.eql(u8, key, "session_handle") and std.mem.eql(u8, vsig, "s")) {
                const h = try r.string();
                @memcpy(s.session_buf[0..h.len], h);
                s.session_len = h.len;
            } else try r.skip(&vsig);
        }
        if (s.session_len == 0) return error.NoSessionHandle;
    }
    const session = s.session_buf[0..s.session_len];

    // 2. SelectSources: one monitor, cursor drawn into the frames, persistent.
    var tok_path_buf: [512]u8 = undefined;
    const tok_path = tokenPath(&tok_path_buf);
    {
        var tok_buf: [256]u8 = undefined;
        var w = dbus.Writer{};
        w.string(session);
        const a = w.arrayBegin(8);
        w.dictStr("handle_token", step.token());
        w.dictU32("types", 1); // MONITOR
        w.dictBool("multiple", false);
        w.dictU32("cursor_mode", 2); // EMBEDDED
        w.dictU32("persist_mode", 2); // until explicitly revoked
        if (tok_path) |p| if (util.readFile(p, &tok_buf)) |tok| {
            const t = std.mem.trim(u8, tok, " \n");
            if (t.len > 0) w.dictStr("restore_token", t);
        };
        w.arrayEnd(a);
        _ = try step.run("SelectSources", "oa{sv}", w.bytes());
    }

    // 3. Start: shows the share dialog unless the restore token is accepted.
    {
        var w = dbus.Writer{};
        w.string(session);
        w.string(""); // parent window
        const a = w.arrayBegin(8);
        w.dictStr("handle_token", step.token());
        w.arrayEnd(a);
        var r = try step.run("Start", "osa{sv}", w.bytes());
        const end = try r.arrayBegin(8);
        var found = false;
        while (r.pos < end) {
            r.alignTo(8);
            const key = try r.string();
            var vsig = try r.signature();
            if (std.mem.eql(u8, key, "streams") and std.mem.eql(u8, vsig, "a(ua{sv})")) {
                const arr_end = try r.arrayBegin(8);
                if (r.pos < arr_end) {
                    s.node_id = try r.u32_();
                    found = true;
                }
                r.pos = arr_end;
            } else if (std.mem.eql(u8, key, "restore_token") and std.mem.eql(u8, vsig, "s")) {
                const t = try r.string();
                if (tok_path) |p| util.writeFile(p, t) catch {};
            } else try r.skip(&vsig);
        }
        if (!found) return error.NoStream;
    }

    // 4. OpenPipeWireRemote: plain method reply carrying the fd.
    {
        var w = dbus.Writer{};
        w.string(session);
        const a = w.arrayBegin(8);
        w.arrayEnd(a);
        const serial = try s.conn.send(.{ .dest = dest, .path = obj, .interface = iface, .member = "OpenPipeWireRemote", .signature = "oa{sv}", .body = w.bytes() });
        const reply = try s.conn.waitReply(serial);
        if (reply.fd < 0) return error.NoPipeWireFd;
        s.pw_fd = reply.fd;
    }
    return s;
}

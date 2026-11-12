//! Choices made in the window or with `okorec fps`, kept in
//! $XDG_CONFIG_HOME/okorec/okorec.conf as `key = value` lines. The file can
//! be edited by hand; comments and unknown lines survive updates.
const std = @import("std");
const linux = std.os.linux;
const util = @import("util.zig");

const file_name = "okorec.conf";
const header = "# OkoRec settings. Written by the window and `okorec fps`; editable by hand.\n";

/// The value of `key`, copied into `out`, or null when unset.
pub fn get(key: []const u8, out: []u8) ?[]const u8 {
    var pbuf: [512]u8 = undefined;
    var fbuf: [4096]u8 = undefined;
    const text = util.readFile(util.configPath(&pbuf, file_name) orelse return null, &fbuf) orelse return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const v = valueOf(line, key) orelse continue;
        if (v.len > out.len) return null;
        @memcpy(out[0..v.len], v);
        return out[0..v.len];
    }
    return null;
}

fn valueOf(line: []const u8, key: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or t[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, t, '=') orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, t[0..eq], " \t"), key)) return null;
    return std.mem.trim(u8, t[eq + 1 ..], " \t");
}

/// Sets `key` to `value`, replacing its line or appending one.
pub fn set(key: []const u8, value: []const u8) void {
    var pbuf: [512]u8 = undefined;
    const path = util.configPath(&pbuf, file_name) orelse return;
    var fbuf: [4096]u8 = undefined;
    const old = util.readFile(path, &fbuf) orelse header;
    var out: [4096 + 128]u8 = undefined;
    var len: usize = 0;
    var done = false;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, old, "\n"), '\n');
    while (lines.next()) |line| {
        const repl = !done and valueOf(line, key) != null;
        const piece = if (repl)
            std.fmt.bufPrint(out[len..], "{s} = {s}\n", .{ key, value }) catch return
        else
            std.fmt.bufPrint(out[len..], "{s}\n", .{line}) catch return;
        len += piece.len;
        done = done or repl;
    }
    if (!done) len += (std.fmt.bufPrint(out[len..], "{s} = {s}\n", .{ key, value }) catch return).len;
    // Write a sibling and rename, so a crash never leaves half a file.
    var tbuf: [520]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tbuf, "{s}.new", .{path}) catch return;
    util.writeFile(tmp, out[0..len]) catch return;
    _ = linux.rename(tmp, path);
}

/// Earlier versions kept these in $XDG_STATE_HOME/okorec as one file each.
pub fn migrate() void {
    for ([_][]const u8{ "fps", "mic" }) |name| {
        var pbuf: [512]u8 = undefined;
        var fbuf: [32]u8 = undefined;
        const old = util.statePath(&pbuf, name) orelse continue;
        const text = util.readFile(old, &fbuf) orelse continue;
        var vbuf: [32]u8 = undefined;
        if (get(name, &vbuf) == null) {
            const v = std.mem.trim(u8, text, " \n");
            set(name, if (std.mem.eql(u8, name, "mic")) (if (std.mem.eql(u8, v, "1")) "on" else "off") else v);
        }
        _ = linux.unlink(old);
    }
}

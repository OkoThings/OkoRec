//! Thin helpers over raw Linux syscalls (no std.Io, no libc stdio).
const std = @import("std");
const linux = std.os.linux;

pub extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub fn env(name: [*:0]const u8) ?[]const u8 {
    const p = getenv(name) orelse return null;
    return std.mem.span(p);
}

pub fn isErr(rc: usize) bool {
    return @as(isize, @bitCast(rc)) < 0;
}

pub fn errnoOf(rc: usize) isize {
    return -@as(isize, @bitCast(rc));
}

pub fn nowNs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}

pub fn writeAll(fd: i32, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.write(fd, data.ptr + off, data.len - off);
        if (isErr(rc)) {
            if (errnoOf(rc) == @intFromEnum(linux.E.INTR)) continue;
            return error.WriteFailed;
        }
        off += rc;
    }
}

pub fn pwriteAll(fd: i32, data: []const u8, offset: u64) !void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.pwrite(fd, data.ptr + off, data.len - off, @intCast(offset + off));
        if (isErr(rc)) return error.WriteFailed;
        off += rc;
    }
}

/// Reads a whole small file into `buf`; returns the bytes read or null.
pub fn readFile(path: [*:0]const u8, buf: []u8) ?[]u8 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (isErr(rc)) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const r = linux.read(fd, buf.ptr + n, buf.len - n);
        if (isErr(r) or r == 0) break;
        n += r;
    }
    return buf[0..n];
}

pub fn writeFile(path: [*:0]const u8, data: []const u8) !void {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    if (isErr(rc)) return error.OpenFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    try writeAll(fd, data);
}

/// mkdir -p for an absolute path.
pub fn mkdirAll(path: []const u8) void {
    var buf: [512]u8 = undefined;
    if (path.len >= buf.len) return;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            @memcpy(buf[0..i], path[0..i]);
            buf[i] = 0;
            _ = linux.mkdir(@ptrCast(&buf), 0o755);
        }
    }
}

pub const Mutex = struct {
    m: std.c.pthread_mutex_t = .{},
    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.m);
    }
    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.m);
    }
};

pub const log = std.debug.print;

/// Path of a small persistent file in $XDG_STATE_HOME/okorec (created on demand).
pub fn statePath(buf: []u8, name: []const u8) ?[:0]u8 {
    return xdgPath(buf, "XDG_STATE_HOME", ".local/state", name);
}

/// Path of a file in $XDG_CONFIG_HOME/okorec (created on demand).
pub fn configPath(buf: []u8, name: []const u8) ?[:0]u8 {
    return xdgPath(buf, "XDG_CONFIG_HOME", ".config", name);
}

fn xdgPath(buf: []u8, comptime var_name: [:0]const u8, comptime home_sub: []const u8, name: []const u8) ?[:0]u8 {
    var dir_buf: [400]u8 = undefined;
    const dir = if (env(var_name)) |d|
        std.fmt.bufPrint(&dir_buf, "{s}/okorec", .{d}) catch return null
    else if (env("HOME")) |h|
        std.fmt.bufPrint(&dir_buf, "{s}/" ++ home_sub ++ "/okorec", .{h}) catch return null
    else
        return null;
    mkdirAll(dir);
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, name }) catch null;
}

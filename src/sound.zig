//! Short feedback sounds, played by handing a freedesktop theme sound to
//! pw-play. Fire and forget: nothing here can block or fail the recorder.
const std = @import("std");
const linux = std.os.linux;
const util = @import("util.zig");

pub const Cue = enum { saved, started, failed };

fn file(cue: Cue) [*:0]const u8 {
    const stereo = "/usr/share/sounds/freedesktop/stereo/";
    // "hum" ships with GNOME only; fall back to the freedesktop theme.
    const hum = "/usr/share/sounds/gnome/default/alerts/hum.ogg";
    return switch (cue) {
        .saved => stereo ++ "complete.oga",
        .started => stereo ++ "message-new-instant.oga",
        .failed => if (util.isErr(linux.access(hum, linux.R_OK))) stereo ++ "dialog-error.oga" else hum,
    };
}

pub fn play(cue: Cue) void {
    // Everything the child needs is prepared before the fork: afterwards it
    // may only make system calls (other threads hold locks we can't see).
    var env_buf: [300]u8 = undefined;
    const runtime = std.fmt.bufPrintZ(&env_buf, "XDG_RUNTIME_DIR={s}", .{util.env("XDG_RUNTIME_DIR") orelse return}) catch return;
    const argv = [_:null]?[*:0]const u8{ "/usr/bin/pw-play", "--media-role", "Notification", file(cue) };
    const envp = [_:null]?[*:0]const u8{runtime.ptr};

    const pid = linux.fork();
    if (util.isErr(pid)) return;
    if (pid == 0) {
        // Fork again so the player is reparented to init and never becomes
        // our zombie.
        if (linux.fork() != 0) linux.exit_group(0);
        var all = linux.sigfillset();
        _ = linux.sigprocmask(linux.SIG.UNBLOCK, &all, null);
        _ = linux.execve(argv[0].?, &argv, &envp);
        linux.exit_group(127);
    }
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
}

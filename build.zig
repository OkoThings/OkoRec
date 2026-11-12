const std = @import("std");

const version = "0.1.0"; // keep in sync with build.zig.zon

/// Debian multiarch, Fedora/openSUSE lib64, Arch lib.
fn findLibDir(b: *std.Build, arch: std.Target.Cpu.Arch) ?[]const u8 {
    const candidates = [_][]const u8{
        b.fmt("/usr/lib/{s}-linux-gnu", .{@tagName(arch)}),
        "/usr/lib64",
        "/usr/lib",
    };
    for (candidates) |dir| {
        const probe = b.fmt("{s}/libpipewire-0.3.so.0", .{dir});
        if (std.Io.Dir.cwd().access(b.graph.io, probe, .{})) return dir else |_| {}
    }
    return null;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    mod.addOptions("build_options", options);

    // Headers are vendored, so the default build needs no -dev packages: it
    // links the runtime libraries by file. Packagers pass -Dsystem-libs to
    // resolve them through pkg-config instead.
    mod.addIncludePath(b.path("vendor/include"));
    const system_libs = b.option(bool, "system-libs", "Link libpipewire and libopus through pkg-config (needs their -dev packages)") orelse false;
    const libdir_opt = b.option([]const u8, "libdir", "Directory holding libpipewire-0.3.so.0 and libopus.so.0 (default: searched)");
    if (system_libs) {
        mod.linkSystemLibrary("libpipewire-0.3", .{});
        mod.linkSystemLibrary("opus", .{});
    } else {
        const libdir = libdir_opt orelse findLibDir(b, target.result.cpu.arch) orelse
            @panic("libpipewire-0.3.so.0 not found; pass -Dlibdir=DIR or -Dsystem-libs");
        mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libpipewire-0.3.so.0", .{libdir}) });
        mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libopus.so.0", .{libdir}) });
    }

    // Window: raylib, built from source. It needs X11/GL development files;
    // without root, `zig build fetch-x11` unpacks the Debian -dev packages
    // into third_party/x11.
    const x11 = "third_party/x11";
    const fetch_x11 = b.step("fetch-x11", "Download X11/GL headers for raylib into " ++ x11 ++ " (no root needed)");
    fetch_x11.dependOn(&b.addSystemCommand(&.{ "sh", "tools/fetch_x11_dev.sh", x11 }).step);
    const raylib_dep = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
        .linux_display_backend = .X11,
        .raudio = false,
    });
    const raylib = raylib_dep.artifact("raylib");
    const has_local_x11 = if (std.Io.Dir.cwd().access(b.graph.io, b.pathFromRoot(x11), .{})) true else |_| false;
    if (has_local_x11) {
        raylib.root_module.addIncludePath(b.path(x11 ++ "/root/usr/include"));
        raylib.root_module.addLibraryPath(b.path(x11 ++ "/lib"));
        mod.addLibraryPath(b.path(x11 ++ "/lib"));
    }
    const raylib_h = b.addTranslateC(.{
        .root_source_file = raylib_dep.path("src/raylib.h"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("raylib", raylib_h.createModule());
    mod.linkLibrary(raylib);

    const exe = b.addExecutable(.{ .name = "okorec", .root_module = mod });
    b.installArtifact(exe);

    // Privileged helper for KMS capture; no libc, no GPU libraries.
    const kms_exe = b.addExecutable(.{ .name = "okorec-kms", .root_module = b.createModule(.{
        .root_source_file = b.path("src/kms_helper.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.installArtifact(kms_exe);
    b.installFile("data/okorec.desktop", "share/applications/okorec.desktop");

    // Install for the current user with a launcher and global shortcuts:
    //   zig build install-app -Doptimize=ReleaseSafe
    const home = b.graph.environ_map.get("HOME") orelse "/tmp";
    const app_prefix = b.option([]const u8, "app-prefix", "Where install-app puts things (default ~/.local)") orelse b.fmt("{s}/.local", .{home});
    const install_app = b.addSystemCommand(&.{ "sh", "tools/install_app.sh", app_prefix });
    install_app.addFileArg(exe.getEmittedBin());
    install_app.has_side_effects = true;
    b.step("install-app", "Install okorec with a GNOME launcher and shortcuts into ~/.local").dependOn(&install_app.step);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run okorec").dependOn(&run.step);
}

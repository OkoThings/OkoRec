//! Headless EGL + desktop OpenGL context on the NVIDIA device platform.
//! Hand-declared: we only need ~25 entry points, loaded at runtime.
const std = @import("std");
const util = @import("util.zig");

pub const Display = ?*anyopaque;
pub const Context = ?*anyopaque;
pub const Image = ?*anyopaque;
const Config = ?*anyopaque;

const EGL_NONE = 0x3038;
const EGL_EXTENSIONS = 0x3055;
const EGL_PLATFORM_DEVICE_EXT = 0x313F;
const EGL_OPENGL_API = 0x30A2;
const EGL_SURFACE_TYPE = 0x3033;
const EGL_PBUFFER_BIT = 0x0001;
const EGL_RENDERABLE_TYPE = 0x3040;
const EGL_OPENGL_BIT = 0x0008;
const EGL_WIDTH = 0x3057;
const EGL_HEIGHT = 0x3056;
const EGL_LINUX_DMA_BUF_EXT = 0x3270;
const EGL_LINUX_DRM_FOURCC_EXT = 0x3271;
const EGL_DMA_BUF_PLANE0_FD_EXT = 0x3272;
const EGL_DMA_BUF_PLANE0_OFFSET_EXT = 0x3273;
const EGL_DMA_BUF_PLANE0_PITCH_EXT = 0x3274;
const EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT = 0x3443;
const EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT = 0x3444;

pub const GL_TEXTURE_2D = 0x0DE1;
pub const GL_RGBA8 = 0x8058;
const GL_RGBA = 0x1908;
const GL_UNSIGNED_BYTE = 0x1401;
const GL_NEAREST = 0x2600;
const GL_TEXTURE_MAG_FILTER = 0x2800;
const GL_TEXTURE_MIN_FILTER = 0x2801;
const GL_READ_FRAMEBUFFER = 0x8CA8;
const GL_DRAW_FRAMEBUFFER = 0x8CA9;
const GL_COLOR_ATTACHMENT0 = 0x8CE0;
const GL_FRAMEBUFFER_COMPLETE = 0x8CD5;
const GL_COLOR_BUFFER_BIT = 0x4000;
const GL_RENDERER = 0x1F01;
const GL_VERSION = 0x1F02;

pub const DRM_FORMAT_XRGB8888: u32 = 0x34325258;
pub const DRM_FORMAT_ARGB8888: u32 = 0x34325241;
pub const DRM_FORMAT_MOD_INVALID: u64 = 0x00ffffffffffffff;

const cc: std.builtin.CallingConvention = .c;

const Egl = struct {
    eglGetProcAddress: *const fn ([*:0]const u8) callconv(cc) ?*const anyopaque,
    eglGetPlatformDisplay: *const fn (c_uint, ?*anyopaque, ?[*]const isize) callconv(cc) Display,
    eglInitialize: *const fn (Display, ?*c_int, ?*c_int) callconv(cc) c_uint,
    eglQueryString: *const fn (Display, c_int) callconv(cc) ?[*:0]const u8,
    eglBindAPI: *const fn (c_uint) callconv(cc) c_uint,
    eglChooseConfig: *const fn (Display, [*]const c_int, ?[*]Config, c_int, *c_int) callconv(cc) c_uint,
    eglCreateContext: *const fn (Display, Config, Context, ?[*]const c_int) callconv(cc) Context,
    eglMakeCurrent: *const fn (Display, ?*anyopaque, ?*anyopaque, Context) callconv(cc) c_uint,
    eglGetError: *const fn () callconv(cc) c_int,
};

const Ext = struct {
    eglQueryDevicesEXT: *const fn (c_int, ?[*]?*anyopaque, *c_int) callconv(cc) c_uint,
    eglQueryDmaBufModifiersEXT: *const fn (Display, c_int, c_int, ?[*]u64, ?[*]c_uint, *c_int) callconv(cc) c_uint,
    eglCreateImageKHR: *const fn (Display, Context, c_uint, ?*anyopaque, [*]const c_int) callconv(cc) Image,
    eglDestroyImageKHR: *const fn (Display, Image) callconv(cc) c_uint,

    glGetString: *const fn (c_uint) callconv(cc) ?[*:0]const u8,
    glGetError: *const fn () callconv(cc) c_uint,
    glGenTextures: *const fn (c_int, [*]c_uint) callconv(cc) void,
    glDeleteTextures: *const fn (c_int, [*]const c_uint) callconv(cc) void,
    glBindTexture: *const fn (c_uint, c_uint) callconv(cc) void,
    glTexImage2D: *const fn (c_uint, c_int, c_int, c_int, c_int, c_int, c_uint, c_uint, ?*const anyopaque) callconv(cc) void,
    glTexParameteri: *const fn (c_uint, c_uint, c_int) callconv(cc) void,
    glGenFramebuffers: *const fn (c_int, [*]c_uint) callconv(cc) void,
    glDeleteFramebuffers: *const fn (c_int, [*]const c_uint) callconv(cc) void,
    glBindFramebuffer: *const fn (c_uint, c_uint) callconv(cc) void,
    glFramebufferTexture2D: *const fn (c_uint, c_uint, c_uint, c_uint, c_int) callconv(cc) void,
    glCheckFramebufferStatus: *const fn (c_uint) callconv(cc) c_uint,
    glBlitFramebuffer: *const fn (c_int, c_int, c_int, c_int, c_int, c_int, c_int, c_int, c_uint, c_uint) callconv(cc) void,
    glEGLImageTargetTexture2DOES: *const fn (c_uint, Image) callconv(cc) void,
    glFlush: *const fn () callconv(cc) void,
    glFinish: *const fn () callconv(cc) void,
    glCreateShader: *const fn (c_uint) callconv(cc) c_uint,
    glShaderSource: *const fn (c_uint, c_int, [*]const [*]const u8, [*]const c_int) callconv(cc) void,
    glCompileShader: *const fn (c_uint) callconv(cc) void,
    glGetShaderiv: *const fn (c_uint, c_uint, *c_int) callconv(cc) void,
    glGetShaderInfoLog: *const fn (c_uint, c_int, ?*c_int, [*]u8) callconv(cc) void,
    glCreateProgram: *const fn () callconv(cc) c_uint,
    glAttachShader: *const fn (c_uint, c_uint) callconv(cc) void,
    glLinkProgram: *const fn (c_uint) callconv(cc) void,
    glGetProgramiv: *const fn (c_uint, c_uint, *c_int) callconv(cc) void,
    glUseProgram: *const fn (c_uint) callconv(cc) void,
    glGetUniformLocation: *const fn (c_uint, [*:0]const u8) callconv(cc) c_int,
    glUniform1i: *const fn (c_int, c_int) callconv(cc) void,
    glUniform1f: *const fn (c_int, f32) callconv(cc) void,
    glUniform2i: *const fn (c_int, c_int, c_int) callconv(cc) void,
    glGenVertexArrays: *const fn (c_int, [*]c_uint) callconv(cc) void,
    glBindVertexArray: *const fn (c_uint) callconv(cc) void,
    glDrawArrays: *const fn (c_uint, c_int, c_int) callconv(cc) void,
    glViewport: *const fn (c_int, c_int, c_int, c_int) callconv(cc) void,
    glEnable: *const fn (c_uint) callconv(cc) void,
    glDisable: *const fn (c_uint) callconv(cc) void,
    glBlendFunc: *const fn (c_uint, c_uint) callconv(cc) void,
    glPixelStorei: *const fn (c_uint, c_int) callconv(cc) void,
    glTexSubImage2D: *const fn (c_uint, c_int, c_int, c_int, c_int, c_int, c_uint, c_uint, *const anyopaque) callconv(cc) void,
    glReadPixels: *const fn (c_int, c_int, c_int, c_int, c_uint, c_uint, *anyopaque) callconv(cc) void,
};

/// A texture wrapped in a framebuffer, optionally backed by an EGL image.
pub const Imported = struct {
    image: Image,
    tex: c_uint,
    fbo: c_uint,
};

/// How the pixels of a source texture are encoded.
pub const Transfer = enum(c_int) {
    /// Already sRGB: copy as is.
    srgb = 0,
    /// HDR scanout: BT.2020 primaries, PQ curve. Converted to sRGB, with
    /// anything brighter than SDR white clipped.
    pq = 1,
};

const vertex_src =
    \\#version 330
    \\void main() {
    \\    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    \\    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

// Texel (x, y) of the source goes to texel (x + offset.x, y + offset.y) of
// the destination; nothing is flipped or filtered.
const fragment_src =
    \\#version 330
    \\uniform sampler2D tex;
    \\uniform int transfer;
    \\uniform float sdr_white;
    \\uniform ivec2 offset;
    \\out vec4 o;
    \\vec3 pq_eotf(vec3 e) {
    \\    const float m1 = 0.1593017578125, m2 = 78.84375;
    \\    const float c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    \\    vec3 p = pow(max(e, 0.0), vec3(1.0 / m2));
    \\    return pow(max(p - c1, 0.0) / (c2 - c3 * p), vec3(1.0 / m1));
    \\}
    \\vec3 srgb_oetf(vec3 l) {
    \\    return mix(12.92 * l, 1.055 * pow(l, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, l));
    \\}
    \\void main() {
    \\    vec4 c = texelFetch(tex, ivec2(gl_FragCoord.xy) - offset, 0);
    \\    if (transfer == 1) {
    \\        vec3 rgb = c.a > 0.0 ? c.rgb / c.a : c.rgb;
    \\        vec3 lin = pq_eotf(rgb) * (10000.0 / sdr_white);
    \\        lin = mat3(1.6605, -0.1246, -0.0182, -0.5876, 1.1329, -0.1006, -0.0728, -0.0083, 1.1187) * lin;
    \\        c.rgb = srgb_oetf(clamp(lin, 0.0, 1.0)) * c.a;
    \\    }
    \\    o = c;
    \\}
;

pub const Gpu = struct {
    lib: std.DynLib,
    egl: Egl,
    x: Ext,
    dpy: Display,
    ctx: Context,
    program: c_uint = 0,
    u_transfer: c_int = 0,
    u_sdr_white: c_int = 0,
    u_offset: c_int = 0,

    pub fn init() !Gpu {
        var lib = std.DynLib.open("libEGL.so.1") catch return error.NoLibEGL;
        var egl: Egl = undefined;
        inline for (@typeInfo(Egl).@"struct".fields) |f| {
            @field(egl, f.name) = lib.lookup(f.type, f.name) orelse return error.MissingEglSymbol;
        }
        var x: Ext = undefined;
        inline for (@typeInfo(Ext).@"struct".fields) |f| {
            const p = egl.eglGetProcAddress(f.name) orelse {
                util.log("egl: missing {s}\n", .{f.name});
                return error.MissingGlSymbol;
            };
            @field(x, f.name) = @ptrCast(p);
        }

        // First EGL device = the NVIDIA GPU on this single-GPU machine.
        var devices: [8]?*anyopaque = undefined;
        var n_dev: c_int = 0;
        if (x.eglQueryDevicesEXT(devices.len, &devices, &n_dev) == 0 or n_dev == 0) return error.NoEglDevice;
        const dpy = egl.eglGetPlatformDisplay(EGL_PLATFORM_DEVICE_EXT, devices[0], null);
        if (dpy == null) return error.NoEglDisplay;
        if (egl.eglInitialize(dpy, null, null) == 0) return error.EglInitFailed;
        if (egl.eglBindAPI(EGL_OPENGL_API) == 0) return error.EglBindApiFailed;

        const cfg_attrs = [_]c_int{ EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_NONE };
        var cfg: [1]Config = .{null};
        var n_cfg: c_int = 0;
        if (egl.eglChooseConfig(dpy, &cfg_attrs, &cfg, 1, &n_cfg) == 0 or n_cfg == 0) return error.NoEglConfig;
        const ctx = egl.eglCreateContext(dpy, cfg[0], null, null);
        if (ctx == null) return error.EglContextFailed;
        // Surfaceless: we only ever render to our own framebuffers.
        if (egl.eglMakeCurrent(dpy, null, null, ctx) == 0) return error.EglMakeCurrentFailed;

        return .{ .lib = lib, .egl = egl, .x = x, .dpy = dpy, .ctx = ctx };
    }

    pub fn describe(self: *Gpu) void {
        const ext = std.mem.span(self.egl.eglQueryString(self.dpy, EGL_EXTENSIONS) orelse "");
        util.log("gl: {s} / {s}\n", .{ self.x.glGetString(GL_RENDERER) orelse "?", self.x.glGetString(GL_VERSION) orelse "?" });
        util.log("egl dma_buf import: {}, modifiers: {}\n", .{
            std.mem.indexOf(u8, ext, "EGL_EXT_image_dma_buf_import") != null,
            std.mem.indexOf(u8, ext, "EGL_EXT_image_dma_buf_import_modifiers") != null,
        });
    }

    /// Modifiers the driver can import for `fourcc` as a regular 2D texture.
    pub fn modifiers(self: *Gpu, fourcc: u32, out: []u64) []u64 {
        var mods: [64]u64 = undefined;
        var ext_only: [64]c_uint = undefined;
        var n: c_int = 0;
        if (self.x.eglQueryDmaBufModifiersEXT(self.dpy, @bitCast(fourcc), mods.len, &mods, &ext_only, &n) == 0) return out[0..0];
        var k: usize = 0;
        for (0..@intCast(n)) |i| {
            if (ext_only[i] != 0 or k >= out.len) continue;
            out[k] = mods[i];
            k += 1;
        }
        return out[0..k];
    }

    /// Plain RGBA8 texture we own (the CUDA-visible copy target) + draw FBO.
    pub fn createTarget(self: *Gpu, w: u32, h: u32) !Imported {
        const x = &self.x;
        var tex: [1]c_uint = .{0};
        x.glGenTextures(1, &tex);
        x.glBindTexture(GL_TEXTURE_2D, tex[0]);
        x.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, @intCast(w), @intCast(h), 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        x.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        x.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        return .{ .image = null, .tex = tex[0], .fbo = try self.wrap(tex[0]) };
    }

    fn wrap(self: *Gpu, tex: c_uint) !c_uint {
        const x = &self.x;
        var fbo: [1]c_uint = .{0};
        x.glGenFramebuffers(1, &fbo);
        x.glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo[0]);
        x.glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
        const status = x.glCheckFramebufferStatus(GL_READ_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            util.log("gl: framebuffer incomplete (0x{x})\n", .{status});
            return error.FramebufferIncomplete;
        }
        return fbo[0];
    }

    /// Empty texture + framebuffer that `bindDmabuf` points at each frame.
    pub fn createSource(self: *Gpu) Imported {
        const x = &self.x;
        var tex: [1]c_uint = .{0};
        var fbo: [1]c_uint = .{0};
        x.glGenTextures(1, &tex);
        x.glGenFramebuffers(1, &fbo);
        x.glBindTexture(GL_TEXTURE_2D, tex[0]);
        x.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        x.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        return .{ .image = null, .tex = tex[0], .fbo = fbo[0] };
    }

    /// Points `src` at a DMA-BUF. Done for every frame (as OBS and
    /// gpu-screen-recorder do) rather than caching imports per buffer.
    pub fn bindDmabuf(self: *Gpu, src: *Imported, fd: i32, w: u32, h: u32, fourcc: u32, stride: u32, offset: u32, modifier: u64) !void {
        const x = &self.x;
        var attrs: [20]c_int = undefined;
        var n: usize = 0;
        const base = [_]c_int{
            EGL_WIDTH,                     @intCast(w),
            EGL_HEIGHT,                    @intCast(h),
            EGL_LINUX_DRM_FOURCC_EXT,      @bitCast(fourcc),
            EGL_DMA_BUF_PLANE0_FD_EXT,     fd,
            EGL_DMA_BUF_PLANE0_OFFSET_EXT, @intCast(offset),
            EGL_DMA_BUF_PLANE0_PITCH_EXT,  @intCast(stride),
        };
        @memcpy(attrs[0..base.len], &base);
        n = base.len;
        if (modifier != DRM_FORMAT_MOD_INVALID) {
            attrs[n] = EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT;
            attrs[n + 1] = @bitCast(@as(u32, @truncate(modifier)));
            attrs[n + 2] = EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT;
            attrs[n + 3] = @bitCast(@as(u32, @truncate(modifier >> 32)));
            n += 4;
        }
        attrs[n] = EGL_NONE;

        const image = x.eglCreateImageKHR(self.dpy, null, EGL_LINUX_DMA_BUF_EXT, null, &attrs);
        if (image == null) {
            util.log("egl: dmabuf import failed (0x{x})\n", .{self.egl.eglGetError()});
            return error.DmabufImportFailed;
        }
        if (src.image != null) _ = x.eglDestroyImageKHR(self.dpy, src.image);
        src.image = image;

        x.glBindTexture(GL_TEXTURE_2D, src.tex);
        _ = x.glGetError();
        x.glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, image);
        const err = x.glGetError();
        if (err != 0) {
            util.log("gl: EGLImageTargetTexture2D failed (0x{x})\n", .{err});
            return error.DmabufBindFailed;
        }
        x.glBindFramebuffer(GL_READ_FRAMEBUFFER, src.fbo);
        x.glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, src.tex, 0);
    }

    pub fn destroy(self: *Gpu, im: Imported) void {
        self.x.glDeleteFramebuffers(1, &[1]c_uint{im.fbo});
        self.x.glDeleteTextures(1, &[1]c_uint{im.tex});
        if (im.image != null) _ = self.x.eglDestroyImageKHR(self.dpy, im.image);
    }

    /// Uploads CPU pixels (BGRx, `stride` bytes per row) into `dst`.
    pub fn upload(self: *Gpu, dst: Imported, pixels: *const anyopaque, w: u32, h: u32, stride: u32) void {
        const x = &self.x;
        x.glBindTexture(GL_TEXTURE_2D, dst.tex);
        x.glPixelStorei(0x0CF2, @intCast(stride / 4)); // GL_UNPACK_ROW_LENGTH
        x.glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, @intCast(w), @intCast(h), 0x80E1, GL_UNSIGNED_BYTE, pixels); // GL_BGRA
        x.glFlush();
    }

    fn compile(self: *Gpu, kind: c_uint, src: []const u8) !c_uint {
        const x = &self.x;
        const sh = x.glCreateShader(kind);
        x.glShaderSource(sh, 1, &[1][*]const u8{src.ptr}, &[1]c_int{@intCast(src.len)});
        x.glCompileShader(sh);
        var ok: c_int = 0;
        x.glGetShaderiv(sh, 0x8B81, &ok); // GL_COMPILE_STATUS
        if (ok == 0) {
            var log: [512]u8 = @splat(0);
            x.glGetShaderInfoLog(sh, log.len - 1, null, &log);
            util.log("gl: shader compile failed: {s}\n", .{std.mem.sliceTo(&log, 0)});
            return error.ShaderCompileFailed;
        }
        return sh;
    }

    fn ensureProgram(self: *Gpu) !void {
        if (self.program != 0) return;
        const x = &self.x;
        const prog = x.glCreateProgram();
        x.glAttachShader(prog, try self.compile(0x8B31, vertex_src)); // GL_VERTEX_SHADER
        x.glAttachShader(prog, try self.compile(0x8B30, fragment_src)); // GL_FRAGMENT_SHADER
        x.glLinkProgram(prog);
        var ok: c_int = 0;
        x.glGetProgramiv(prog, 0x8B82, &ok); // GL_LINK_STATUS
        if (ok == 0) return error.ShaderLinkFailed;
        var vao: [1]c_uint = .{0};
        x.glGenVertexArrays(1, &vao);
        x.glBindVertexArray(vao[0]);
        x.glUseProgram(prog);
        x.glUniform1i(x.glGetUniformLocation(prog, "tex"), 0);
        self.u_transfer = x.glGetUniformLocation(prog, "transfer");
        self.u_sdr_white = x.glGetUniformLocation(prog, "sdr_white");
        self.u_offset = x.glGetUniformLocation(prog, "offset");
        self.program = prog;
    }

    /// Draws `src` (w x h, premultiplied alpha) into `dst` at (x, y),
    /// converting its colours to sRGB. With `blend` it is composited over
    /// what is already there (cursor); otherwise it replaces it.
    pub fn draw(self: *Gpu, src: Imported, dst: Imported, px: i32, py: i32, w: u32, h: u32, transfer: Transfer, sdr_white: f32, blend: bool) !void {
        try self.ensureProgram();
        const x = &self.x;
        x.glBindFramebuffer(GL_DRAW_FRAMEBUFFER, dst.fbo);
        x.glViewport(px, py, @intCast(w), @intCast(h));
        x.glBindTexture(GL_TEXTURE_2D, src.tex);
        x.glUniform1i(self.u_transfer, @intFromEnum(transfer));
        x.glUniform1f(self.u_sdr_white, sdr_white);
        x.glUniform2i(self.u_offset, px, py);
        if (blend) {
            x.glEnable(0x0BE2); // GL_BLEND
            x.glBlendFunc(1, 0x0303); // ONE, ONE_MINUS_SRC_ALPHA
        } else x.glDisable(0x0BE2);
        x.glDrawArrays(4, 0, 3); // GL_TRIANGLES
        x.glFlush();
    }

    /// GPU-side 1:1 copy src -> dst.
    pub fn blit(self: *Gpu, src: Imported, dst: Imported, w: u32, h: u32) void {
        const x = &self.x;
        const wi: c_int = @intCast(w);
        const hi: c_int = @intCast(h);
        x.glBindFramebuffer(GL_READ_FRAMEBUFFER, src.fbo);
        x.glBindFramebuffer(GL_DRAW_FRAMEBUFFER, dst.fbo);
        x.glBlitFramebuffer(0, 0, wi, hi, 0, 0, wi, hi, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        x.glFlush();
    }

    /// Debug: brightest RGBA value over a 7x7 grid of sample points.
    pub fn peek(self: *Gpu, im: Imported, w: u32, h: u32) [4]u8 {
        var px: [4]u8 = .{ 0, 0, 0, 0 };
        var max: [4]u8 = .{ 0, 0, 0, 0 };
        self.x.glBindFramebuffer(GL_READ_FRAMEBUFFER, im.fbo);
        for (1..8) |gy| for (1..8) |gx| {
            self.x.glReadPixels(@intCast(w * gx / 8), @intCast(h * gy / 8), 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &px);
            for (0..4) |i| max[i] = @max(max[i], px[i]);
        };
        return max;
    }
    pub fn glError(self: *Gpu) c_uint {
        return self.x.glGetError();
    }
};

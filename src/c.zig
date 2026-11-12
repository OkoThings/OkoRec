//! C declarations pulled straight from the vendored headers (vendor/include).
//! NVENC structs that contain bitfields come out opaque here; see nvenc_abi.zig.
pub extern fn pw_init(argc: ?*c_int, argv: ?*[*][*:0]u8) void;

pub const c = @cImport({
    @cInclude("time.h");
    @cInclude("pipewire/stream.h");
    @cInclude("pipewire/keys.h");
    @cInclude("pipewire/main-loop.h");
    @cInclude("pipewire/context.h");
    @cInclude("spa/param/video/format.h");
    @cInclude("spa/param/audio/raw.h");
    @cInclude("spa/param/buffers.h");
    @cInclude("spa/buffer/buffer.h");
    @cInclude("spa/buffer/meta.h");
    @cInclude("ffnvcodec/dynlink_cuda.h");
    @cInclude("ffnvcodec/nvEncodeAPI.h");
});

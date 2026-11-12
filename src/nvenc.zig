//! NVENC HEVC encoder fed from a CUDA device buffer (RGBA in, Annex B out).
//! Synchronous: one frame in, one packet out, no B-frames or lookahead.
const std = @import("std");
const c = @import("c.zig").c;
const abi = @import("nvenc_abi.zig");
const util = @import("util.zig");

pub const Options = struct {
    width: u32,
    height: u32,
    fps: u32,
    /// Constant-quality target (lower = better, ~19-28 is the useful range).
    cq: u8,
};

pub const Packet = struct {
    data: []const u8,
    keyframe: bool,
};

fn check(rc: c.NVENCSTATUS, what: []const u8) !void {
    if (rc != c.NV_ENC_SUCCESS) {
        util.log("nvenc: {s} failed ({d})\n", .{ what, rc });
        return error.NvencFailed;
    }
}

pub const Encoder = struct {
    lib: std.DynLib,
    f: c.NV_ENCODE_API_FUNCTION_LIST,
    enc: ?*anyopaque,
    registered: ?*anyopaque,
    bitstream: ?*anyopaque,
    opt: Options,
    pitch: u32,
    frame_idx: u32 = 0,
    locked: bool = false,

    pub fn init(cuda_ctx: ?*anyopaque, dev_ptr: u64, pitch: usize, opt: Options) !Encoder {
        var lib = std.DynLib.open("libnvidia-encode.so.1") catch return error.NoLibNvEncode;
        const create = lib.lookup(*const fn (*c.NV_ENCODE_API_FUNCTION_LIST) callconv(.c) c.NVENCSTATUS, "NvEncodeAPICreateInstance") orelse return error.MissingNvencSymbol;
        var f = std.mem.zeroes(c.NV_ENCODE_API_FUNCTION_LIST);
        f.version = c.NV_ENCODE_API_FUNCTION_LIST_VER;
        try check(create(&f), "CreateInstance");

        var sp = std.mem.zeroes(c.NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS);
        sp.version = c.NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
        sp.deviceType = c.NV_ENC_DEVICE_TYPE_CUDA;
        sp.device = cuda_ctx;
        sp.apiVersion = c.NVENCAPI_VERSION;
        var enc: ?*anyopaque = null;
        try check(f.nvEncOpenEncodeSessionEx.?(&sp, &enc), "OpenEncodeSession");

        const codec = c.NV_ENC_CODEC_HEVC_GUID;
        const preset = c.NV_ENC_PRESET_P5_GUID;
        const tuning = c.NV_ENC_TUNING_INFO_HIGH_QUALITY;

        // Start from the preset, then override what a replay buffer needs.
        const pc = try std.heap.page_allocator.create(abi.PresetConfig);
        defer std.heap.page_allocator.destroy(pc);
        @memset(std.mem.asBytes(pc), 0);
        pc.version = c.NV_ENC_PRESET_CONFIG_VER;
        pc.presetCfg.version = c.NV_ENC_CONFIG_VER;
        try check(f.nvEncGetEncodePresetConfigEx.?(enc, codec, preset, tuning, @ptrCast(pc)), "GetEncodePresetConfigEx");

        const cfg = &pc.presetCfg;
        cfg.gopLength = c.NVENC_INFINITE_GOPLENGTH; // we force IDRs by time
        cfg.frameIntervalP = 1; // no B-frames: one in, one out
        cfg.rcParams.rateControlMode = c.NV_ENC_PARAMS_RC_VBR;
        cfg.rcParams.averageBitRate = 0;
        cfg.rcParams.maxBitRate = 0;
        cfg.rcParams.vbvBufferSize = 0;
        cfg.rcParams.targetQuality = opt.cq;
        cfg.rcParams.targetQualityLSB = 0;
        cfg.rcParams.flags &= ~@as(u32, 1 << 5); // no lookahead
        cfg.rcParams.lookaheadDepth = 0;
        cfg.hevc.idrPeriod = c.NVENC_INFINITE_GOPLENGTH;
        cfg.hevc.flags |= 1 << 7; // repeatSPSPPS: every IDR is self-contained
        // NVENC converts our RGB input to limited-range YUV; label it.
        cfg.hevc.vui.videoSignalTypePresentFlag = 1;
        cfg.hevc.vui.videoFormat = c.NV_ENC_VUI_VIDEO_FORMAT_UNSPECIFIED;
        cfg.hevc.vui.videoFullRangeFlag = 0;
        cfg.hevc.vui.colourDescriptionPresentFlag = 1;
        cfg.hevc.vui.colourPrimaries = c.NV_ENC_VUI_COLOR_PRIMARIES_BT709;
        cfg.hevc.vui.transferCharacteristics = c.NV_ENC_VUI_TRANSFER_CHARACTERISTIC_BT709;
        cfg.hevc.vui.colourMatrix = c.NV_ENC_VUI_MATRIX_COEFFS_BT709;

        var ip = std.mem.zeroes(abi.InitParams);
        ip.version = c.NV_ENC_INITIALIZE_PARAMS_VER;
        ip.encodeGUID = codec;
        ip.presetGUID = preset;
        ip.encodeWidth = opt.width;
        ip.encodeHeight = opt.height;
        ip.darWidth = opt.width;
        ip.darHeight = opt.height;
        ip.frameRateNum = opt.fps;
        ip.frameRateDen = 1;
        ip.enablePTD = 1;
        ip.encodeConfig = cfg;
        ip.maxEncodeWidth = opt.width;
        ip.maxEncodeHeight = opt.height;
        ip.tuningInfo = tuning;
        try check(f.nvEncInitializeEncoder.?(enc, @ptrCast(&ip)), "InitializeEncoder");

        var rr = std.mem.zeroes(c.NV_ENC_REGISTER_RESOURCE);
        rr.version = c.NV_ENC_REGISTER_RESOURCE_VER;
        rr.resourceType = c.NV_ENC_INPUT_RESOURCE_TYPE_CUDADEVICEPTR;
        rr.width = opt.width;
        rr.height = opt.height;
        rr.pitch = @intCast(pitch);
        rr.resourceToRegister = @ptrFromInt(dev_ptr);
        rr.bufferFormat = c.NV_ENC_BUFFER_FORMAT_ABGR; // bytes R,G,B,A = GL_RGBA8
        rr.bufferUsage = c.NV_ENC_INPUT_IMAGE;
        try check(f.nvEncRegisterResource.?(enc, &rr), "RegisterResource");

        var cb = std.mem.zeroes(c.NV_ENC_CREATE_BITSTREAM_BUFFER);
        cb.version = c.NV_ENC_CREATE_BITSTREAM_BUFFER_VER;
        try check(f.nvEncCreateBitstreamBuffer.?(enc, &cb), "CreateBitstreamBuffer");

        return .{
            .lib = lib,
            .f = f,
            .enc = enc,
            .registered = rr.registeredResource,
            .bitstream = cb.bitstreamBuffer,
            .opt = opt,
            .pitch = @intCast(pitch),
        };
    }

    /// Encodes the current contents of the device buffer. The returned packet
    /// data is valid until `release`; null means the encoder wants more input.
    pub fn encode(self: *Encoder, pts: u64, force_idr: bool) !?Packet {
        const f = &self.f;
        var map = std.mem.zeroes(c.NV_ENC_MAP_INPUT_RESOURCE);
        map.version = c.NV_ENC_MAP_INPUT_RESOURCE_VER;
        map.registeredResource = self.registered;
        try check(f.nvEncMapInputResource.?(self.enc, &map), "MapInputResource");
        defer _ = f.nvEncUnmapInputResource.?(self.enc, map.mappedResource);

        var pp = std.mem.zeroes(abi.PicParams);
        pp.version = c.NV_ENC_PIC_PARAMS_VER;
        pp.inputWidth = self.opt.width;
        pp.inputHeight = self.opt.height;
        pp.inputPitch = self.pitch;
        pp.encodePicFlags = if (force_idr) c.NV_ENC_PIC_FLAG_FORCEIDR else 0;
        pp.frameIdx = self.frame_idx;
        pp.inputTimeStamp = pts;
        pp.inputBuffer = map.mappedResource;
        pp.outputBitstream = self.bitstream;
        pp.bufferFmt = @intCast(map.mappedBufferFmt);
        pp.pictureStruct = c.NV_ENC_PIC_STRUCT_FRAME;
        self.frame_idx +%= 1;
        const rc = f.nvEncEncodePicture.?(self.enc, @ptrCast(&pp));
        if (rc == c.NV_ENC_ERR_NEED_MORE_INPUT) return null;
        try check(rc, "EncodePicture");

        var lb = std.mem.zeroes(abi.LockBitstream);
        lb.version = c.NV_ENC_LOCK_BITSTREAM_VER;
        lb.outputBitstream = self.bitstream;
        try check(f.nvEncLockBitstream.?(self.enc, @ptrCast(&lb)), "LockBitstream");
        self.locked = true;
        return .{
            .data = lb.bitstreamBufferPtr.?[0..lb.bitstreamSizeInBytes],
            .keyframe = lb.pictureType == c.NV_ENC_PIC_TYPE_IDR,
        };
    }

    pub fn release(self: *Encoder) void {
        if (!self.locked) return;
        _ = self.f.nvEncUnlockBitstream.?(self.enc, self.bitstream);
        self.locked = false;
    }
};

//! Hand-written layouts for the NVENC structs that contain C bitfields (Zig's
//! C import turns those into opaque types). Only the fields we touch are
//! named; the rest is padding. Offsets and sizes are asserted against values
//! printed by tools/abi_check.c from the vendored nvEncodeAPI.h (SDK 12.1).
const std = @import("std");
const c = @import("c.zig").c;

pub const Guid = c.GUID;

pub const RcParams = extern struct {
    version: u32,
    rateControlMode: u32,
    constQP: [3]u32,
    averageBitRate: u32,
    maxBitRate: u32,
    vbvBufferSize: u32,
    vbvInitialDelay: u32,
    /// bit 3 enableAQ, bit 5 enableLookahead, bit 8 enableTemporalAQ, bits 12-15 aqStrength
    flags: u32,
    _qp: [48]u8,
    targetQuality: u8,
    targetQualityLSB: u8,
    lookaheadDepth: u16,
    _rest: [36]u8,
};

pub const Vui = c.NV_ENC_CONFIG_HEVC_VUI_PARAMETERS;

pub const ConfigHevc = extern struct {
    level: u32,
    tier: u32,
    minCUSize: u32,
    maxCUSize: u32,
    /// bit 4 outputAUD, bit 7 repeatSPSPPS, bits 9-10 chromaFormatIDC
    flags: u32,
    idrPeriod: u32,
    _a: [40]u8,
    vui: Vui,
    _rest: [1560 - 176]u8,
};

pub const Config = extern struct {
    version: u32,
    profileGUID: Guid,
    gopLength: u32,
    frameIntervalP: i32,
    monoChromeEncoding: u32,
    frameFieldMode: u32,
    mvPrecision: u32,
    rcParams: RcParams,
    hevc: ConfigHevc align(8),
    _rest: [3584 - 168 - 1560]u8,
};

pub const InitParams = extern struct {
    version: u32,
    encodeGUID: Guid,
    presetGUID: Guid,
    encodeWidth: u32,
    encodeHeight: u32,
    darWidth: u32,
    darHeight: u32,
    frameRateNum: u32,
    frameRateDen: u32,
    enableEncodeAsync: u32,
    enablePTD: u32,
    flags: u32,
    privDataSize: u32,
    privData: ?*anyopaque,
    encodeConfig: ?*Config,
    maxEncodeWidth: u32,
    maxEncodeHeight: u32,
    _me: [32]u8,
    tuningInfo: u32,
    bufferFormat: u32,
    _rest: [1808 - 144]u8,
};

pub const PresetConfig = extern struct {
    version: u32,
    presetCfg: Config align(8),
    _rest: [5128 - 8 - 3584]u8,
};

pub const PicParams = extern struct {
    version: u32,
    inputWidth: u32,
    inputHeight: u32,
    inputPitch: u32,
    encodePicFlags: u32,
    frameIdx: u32,
    inputTimeStamp: u64,
    inputDuration: u64,
    inputBuffer: ?*anyopaque,
    outputBitstream: ?*anyopaque,
    completionEvent: ?*anyopaque,
    bufferFmt: u32,
    pictureStruct: u32,
    pictureType: u32,
    _rest: [3360 - 76]u8,
};

pub const LockBitstream = extern struct {
    version: u32,
    flags: u32,
    outputBitstream: ?*anyopaque,
    sliceOffsets: ?*u32,
    frameIdx: u32,
    hwEncodeStatus: u32,
    numSlices: u32,
    bitstreamSizeInBytes: u32,
    outputTimeStamp: u64,
    outputDuration: u64,
    bitstreamBufferPtr: ?[*]u8,
    pictureType: u32,
    pictureStruct: u32,
    frameAvgQP: u32,
    _rest: [1552 - 76]u8,
};

comptime {
    const eq = struct {
        fn f(a: usize, b: usize) void {
            if (a != b) @compileError(std.fmt.comptimePrint("NVENC ABI mismatch: {d} != {d}", .{ a, b }));
        }
    }.f;
    eq(@sizeOf(RcParams), 128);
    eq(@offsetOf(RcParams, "averageBitRate"), 20);
    eq(@offsetOf(RcParams, "flags"), 36);
    eq(@offsetOf(RcParams, "targetQuality"), 88);
    eq(@offsetOf(RcParams, "lookaheadDepth"), 90);
    eq(@sizeOf(ConfigHevc), 1560);
    eq(@offsetOf(ConfigHevc, "idrPeriod"), 20);
    eq(@offsetOf(ConfigHevc, "vui"), 64);
    eq(@sizeOf(Vui), 112);
    eq(@sizeOf(Config), 3584);
    eq(@offsetOf(Config, "gopLength"), 20);
    eq(@offsetOf(Config, "rcParams"), 40);
    eq(@offsetOf(Config, "hevc"), 168);
    eq(@sizeOf(InitParams), 1808);
    eq(@offsetOf(InitParams, "enablePTD"), 64);
    eq(@offsetOf(InitParams, "privData"), 80);
    eq(@offsetOf(InitParams, "encodeConfig"), 88);
    eq(@offsetOf(InitParams, "tuningInfo"), 136);
    eq(@sizeOf(PresetConfig), 5128);
    eq(@offsetOf(PresetConfig, "presetCfg"), 8);
    eq(@sizeOf(PicParams), 3360);
    eq(@offsetOf(PicParams, "inputTimeStamp"), 24);
    eq(@offsetOf(PicParams, "inputBuffer"), 40);
    eq(@offsetOf(PicParams, "bufferFmt"), 64);
    eq(@offsetOf(PicParams, "pictureType"), 72);
    eq(@sizeOf(LockBitstream), 1552);
    eq(@offsetOf(LockBitstream, "bitstreamSizeInBytes"), 36);
    eq(@offsetOf(LockBitstream, "bitstreamBufferPtr"), 56);
    eq(@offsetOf(LockBitstream, "pictureType"), 64);
}

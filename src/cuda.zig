//! CUDA driver API, used only as the bridge GL texture -> NVENC input.
const std = @import("std");
const c = @import("c.zig").c;
const util = @import("util.zig");

const Fns = struct {
    cuInit: *const c.tcuInit,
    cuDeviceGet: *const c.tcuDeviceGet,
    cuCtxCreate_v2: *const c.tcuCtxCreate_v2,
    cuMemAllocPitch_v2: *const c.tcuMemAllocPitch_v2,
    cuMemcpy2D_v2: *const c.tcuMemcpy2D_v2,
    cuGraphicsGLRegisterImage: *const c.tcuGraphicsGLRegisterImage,
    cuGraphicsMapResources: *const c.tcuGraphicsMapResources,
    cuGraphicsUnmapResources: *const c.tcuGraphicsUnmapResources,
    cuGraphicsSubResourceGetMappedArray: *const c.tcuGraphicsSubResourceGetMappedArray,
};

fn check(rc: c.CUresult, what: []const u8) !void {
    if (rc != c.CUDA_SUCCESS) {
        util.log("cuda: {s} failed ({d})\n", .{ what, rc });
        return error.CudaFailed;
    }
}

pub const Cuda = struct {
    lib: std.DynLib,
    f: Fns,
    ctx: c.CUcontext,

    /// Requires the GL context to be current on this thread.
    pub fn init() !Cuda {
        var lib = std.DynLib.open("libcuda.so.1") catch return error.NoLibCuda;
        var f: Fns = undefined;
        inline for (@typeInfo(Fns).@"struct".fields) |fld| {
            @field(f, fld.name) = lib.lookup(fld.type, fld.name) orelse return error.MissingCudaSymbol;
        }
        try check(f.cuInit(0), "cuInit");
        var dev: c.CUdevice = 0;
        try check(f.cuDeviceGet(&dev, 0), "cuDeviceGet");
        var ctx: c.CUcontext = null;
        try check(f.cuCtxCreate_v2(&ctx, 0, dev), "cuCtxCreate");
        return .{ .lib = lib, .f = f, .ctx = ctx };
    }
};

/// A GL texture registered with CUDA plus the device buffer NVENC reads.
pub const Bridge = struct {
    cuda: *Cuda,
    res: c.CUgraphicsResource,
    dev_ptr: c.CUdeviceptr,
    pitch: usize,
    width_bytes: usize,
    height: usize,

    pub fn init(cuda: *Cuda, gl_tex: c_uint, gl_target: c_uint, w: u32, h: u32) !Bridge {
        var res: c.CUgraphicsResource = null;
        // Flag 1 = read-only from CUDA's side.
        try check(cuda.f.cuGraphicsGLRegisterImage(&res, gl_tex, gl_target, 1), "cuGraphicsGLRegisterImage");
        var ptr: c.CUdeviceptr = 0;
        var pitch: usize = 0;
        try check(cuda.f.cuMemAllocPitch_v2(&ptr, &pitch, @as(usize, w) * 4, h, 4), "cuMemAllocPitch");
        return .{ .cuda = cuda, .res = res, .dev_ptr = ptr, .pitch = pitch, .width_bytes = @as(usize, w) * 4, .height = h };
    }

    /// Copies the texture's current contents into the device buffer.
    /// Mapping waits for pending GL work on the texture.
    pub fn pull(self: *Bridge) !void {
        const f = &self.cuda.f;
        try check(f.cuGraphicsMapResources(1, &self.res, null), "cuGraphicsMapResources");
        defer _ = f.cuGraphicsUnmapResources(1, &self.res, null);
        var arr: c.CUarray = null;
        try check(f.cuGraphicsSubResourceGetMappedArray(&arr, self.res, 0, 0), "GetMappedArray");
        var cp = std.mem.zeroes(c.CUDA_MEMCPY2D);
        cp.srcMemoryType = c.CU_MEMORYTYPE_ARRAY;
        cp.srcArray = arr;
        cp.dstMemoryType = c.CU_MEMORYTYPE_DEVICE;
        cp.dstDevice = self.dev_ptr;
        cp.dstPitch = self.pitch;
        cp.WidthInBytes = self.width_bytes;
        cp.Height = self.height;
        try check(f.cuMemcpy2D_v2(&cp), "cuMemcpy2D");
    }
};

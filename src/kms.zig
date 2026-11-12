//! Raw DRM/KMS ioctls (no libdrm): enumerate planes, look up the framebuffer
//! a plane is scanning out and export it as a DMA-BUF.
//! Getting framebuffer handles needs CAP_SYS_ADMIN, hence the helper binary.
const std = @import("std");
const linux = std.os.linux;
const util = @import("util.zig");

fn ioc(dir: u32, nr: u32, comptime T: type) u32 {
    return (dir << 30) | (@as(u32, @sizeOf(T)) << 16) | (@as(u32, 'd') << 8) | nr;
}
const W = 1;
const RW = 3;

const SetClientCap = extern struct { capability: u64, value: u64 };
const PlaneRes = extern struct { plane_id_ptr: u64, count_planes: u32, _pad: u32 = 0 };
const GetPlane = extern struct {
    plane_id: u32,
    crtc_id: u32 = 0,
    fb_id: u32 = 0,
    possible_crtcs: u32 = 0,
    gamma_size: u32 = 0,
    count_format_types: u32 = 0,
    format_type_ptr: u64 = 0,
};
const FbCmd2 = extern struct {
    fb_id: u32,
    width: u32 = 0,
    height: u32 = 0,
    pixel_format: u32 = 0,
    flags: u32 = 0,
    handles: [4]u32 = .{ 0, 0, 0, 0 },
    pitches: [4]u32 = .{ 0, 0, 0, 0 },
    offsets: [4]u32 = .{ 0, 0, 0, 0 },
    modifier: [4]u64 align(8) = .{ 0, 0, 0, 0 },
};
const PrimeHandle = extern struct { handle: u32, flags: u32, fd: i32 = -1 };
const GemClose = extern struct { handle: u32, pad: u32 = 0 };
const ObjGetProps = extern struct {
    props_ptr: u64,
    prop_values_ptr: u64,
    count_props: u32,
    obj_id: u32,
    obj_type: u32,
    _pad: u32 = 0,
};
const GetProperty = extern struct {
    values_ptr: u64 = 0,
    enum_blob_ptr: u64 = 0,
    prop_id: u32,
    flags: u32 = 0,
    name: [32]u8 = undefined,
    count_values: u32 = 0,
    count_enum_blobs: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(PlaneRes) == 16);
    std.debug.assert(@sizeOf(GetPlane) == 32);
    std.debug.assert(@sizeOf(FbCmd2) == 104);
    std.debug.assert(@sizeOf(PrimeHandle) == 12);
    std.debug.assert(@sizeOf(ObjGetProps) == 32);
    std.debug.assert(@sizeOf(GetProperty) == 64);
}

const obj_plane = 0xeeeeeeee;
const obj_connector = 0xc0c0c0c0;

const CardRes = extern struct {
    fb_id_ptr: u64 = 0,
    crtc_id_ptr: u64 = 0,
    connector_id_ptr: u64 = 0,
    encoder_id_ptr: u64 = 0,
    count_fbs: u32 = 0,
    count_crtcs: u32 = 0,
    count_connectors: u32 = 0,
    count_encoders: u32 = 0,
    min_width: u32 = 0,
    max_width: u32 = 0,
    min_height: u32 = 0,
    max_height: u32 = 0,
};
const GetBlob = extern struct { blob_id: u32, length: u32, data: u64 };

/// One scanned-out framebuffer, exported.
pub const Frame = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    fourcc: u32 = 0,
    pitch: u32 = 0,
    offset: u32 = 0,
    fb_id: u32 = 0,
    modifier: u64 = 0,
    /// Plane position on the CRTC (meaningful for the cursor plane).
    x: i32 = 0,
    y: i32 = 0,
    /// 1 primary, 2 cursor, 0 overlay (DRM plane "type" property).
    plane_type: u32 = 0,
    _pad: u32 = 0,
};

pub const Plane = struct {
    id: u32,
    /// 1 primary, 2 cursor, 0 overlay.
    type: u32 = 0,
    /// Indexes of CRTC_X / CRTC_Y in the plane's property list.
    x_idx: ?usize = null,
    y_idx: ?usize = null,
};

pub const Card = struct {
    fd: i32,
    planes: [32]Plane = undefined,
    n_planes: usize = 0,

    pub fn open(path: [*:0]const u8) !Card {
        const rc = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (util.isErr(rc)) return error.OpenCardFailed;
        var self = Card{ .fd = @intCast(rc) };
        var cap = SetClientCap{ .capability = 2, .value = 1 }; // UNIVERSAL_PLANES
        _ = linux.ioctl(self.fd, ioc(W, 0x0d, SetClientCap), @intFromPtr(&cap));
        cap = .{ .capability = 3, .value = 1 }; // ATOMIC (exposes CRTC_X/Y props)
        _ = linux.ioctl(self.fd, ioc(W, 0x0d, SetClientCap), @intFromPtr(&cap));

        // Plane ids, types and property layout never change; read them once.
        var ids: [32]u32 = undefined;
        var res = PlaneRes{ .plane_id_ptr = @intFromPtr(&ids), .count_planes = ids.len };
        if (util.isErr(linux.ioctl(self.fd, ioc(RW, 0xB5, PlaneRes), @intFromPtr(&res)))) return error.NotADisplayCard;
        for (ids[0..@min(res.count_planes, ids.len)]) |id| {
            var plane = Plane{ .id = id };
            var props: [64]u32 = undefined;
            var values: [64]u64 = undefined;
            const n = self.readProps(id, obj_plane, &props, &values);
            for (props[0..n], 0..) |prop_id, i| {
                var gp = GetProperty{ .prop_id = prop_id };
                if (util.isErr(linux.ioctl(self.fd, ioc(RW, 0xAA, GetProperty), @intFromPtr(&gp)))) continue;
                const name = std.mem.sliceTo(&gp.name, 0);
                if (std.mem.eql(u8, name, "type")) plane.type = @intCast(values[i]);
                if (std.mem.eql(u8, name, "CRTC_X")) plane.x_idx = i;
                if (std.mem.eql(u8, name, "CRTC_Y")) plane.y_idx = i;
            }
            self.planes[self.n_planes] = plane;
            self.n_planes += 1;
        }
        return self;
    }

    fn readProps(self: *const Card, obj_id: u32, obj_type: u32, ids: *[64]u32, values: *[64]u64) usize {
        var req = ObjGetProps{
            .props_ptr = @intFromPtr(ids),
            .prop_values_ptr = @intFromPtr(values),
            .count_props = ids.len,
            .obj_id = obj_id,
            .obj_type = obj_type,
        };
        if (util.isErr(linux.ioctl(self.fd, ioc(RW, 0xB9, ObjGetProps), @intFromPtr(&req)))) return 0;
        return @min(req.count_props, ids.len);
    }

    fn currentFb(self: *const Card, plane_id: u32) u32 {
        var gp = GetPlane{ .plane_id = plane_id };
        if (util.isErr(linux.ioctl(self.fd, ioc(RW, 0xB6, GetPlane), @intFromPtr(&gp)))) return 0;
        return gp.fb_id;
    }

    /// True when a connector is signalling HDR with the PQ transfer function
    /// (its HDR_OUTPUT_METADATA says EOTF = SMPTE ST 2084). Needs no privilege.
    pub fn pqActive(self: *const Card) bool {
        var conns: [16]u32 = undefined;
        var res = CardRes{ .connector_id_ptr = @intFromPtr(&conns), .count_connectors = conns.len };
        if (util.isErr(linux.ioctl(self.fd, ioc(RW, 0xA0, CardRes), @intFromPtr(&res)))) return false;
        for (conns[0..@min(res.count_connectors, conns.len)]) |conn| {
            var ids: [64]u32 = undefined;
            var values: [64]u64 = undefined;
            const n = self.readProps(conn, obj_connector, &ids, &values);
            for (ids[0..n], 0..) |prop_id, i| {
                if (values[i] == 0) continue;
                var gp = GetProperty{ .prop_id = prop_id };
                if (util.isErr(linux.ioctl(self.fd, ioc(RW, 0xAA, GetProperty), @intFromPtr(&gp)))) continue;
                if (!std.mem.eql(u8, std.mem.sliceTo(&gp.name, 0), "HDR_OUTPUT_METADATA")) continue;
                // struct hdr_output_metadata { u32 type; u8 eotf; ... }
                var blob: [64]u8 = @splat(0);
                // The kernel only copies when asked for the blob's exact
                // length, so ask for the length first.
                var gb = GetBlob{ .blob_id = @intCast(values[i]), .length = 0, .data = @intFromPtr(&blob) };
                if (util.isErr(linux.ioctl(self.fd, ioc(RW, 0xAC, GetBlob), @intFromPtr(&gb)))) continue;
                if (gb.length < 5 or gb.length > blob.len) continue;
                if (util.isErr(linux.ioctl(self.fd, ioc(RW, 0xAC, GetBlob), @intFromPtr(&gb)))) continue;
                if (blob[4] == 2) return true;
            }
        }
        return false;
    }

    pub fn hasActivePlane(self: *const Card) bool {
        for (self.planes[0..self.n_planes]) |p| if (self.currentFb(p.id) != 0) return true;
        return false;
    }

    /// Describes what the first active plane of `plane_type` is showing and
    /// exports it as a DMA-BUF. `frame.width == 0` means no such plane is
    /// active; a null fd with a filled frame means the kernel withheld the
    /// handle (no CAP_SYS_ADMIN).
    pub fn grab(self: *const Card, plane_type: u32, skip: usize, frame: *Frame) ?i32 {
        frame.* = .{};
        var seen: usize = 0;
        for (self.planes[0..self.n_planes]) |p| {
            if (p.type != plane_type) continue;
            const fb_id = self.currentFb(p.id);
            if (fb_id == 0) continue;
            if (seen < skip) {
                seen += 1;
                continue;
            }
            var fb = FbCmd2{ .fb_id = fb_id };
            if (util.isErr(linux.ioctl(self.fd, ioc(RW, 0xCE, FbCmd2), @intFromPtr(&fb)))) return null;
            frame.* = .{
                .width = fb.width,
                .height = fb.height,
                .fourcc = fb.pixel_format,
                .pitch = fb.pitches[0],
                .offset = fb.offsets[0],
                .fb_id = fb.fb_id,
                .modifier = if (fb.flags & 2 != 0) fb.modifier[0] else 0x00ffffffffffffff,
                .plane_type = p.type,
            };
            if (p.x_idx != null and p.y_idx != null) {
                var ids: [64]u32 = undefined;
                var values: [64]u64 = undefined;
                if (self.readProps(p.id, obj_plane, &ids, &values) > @max(p.x_idx.?, p.y_idx.?)) {
                    frame.x = @truncate(@as(i64, @bitCast(values[p.x_idx.?])));
                    frame.y = @truncate(@as(i64, @bitCast(values[p.y_idx.?])));
                }
            }
            if (fb.handles[0] == 0) return null;
            defer {
                // GETFB2 creates a new handle per plane, possibly the same one.
                var closed: [4]u32 = .{ 0, 0, 0, 0 };
                for (fb.handles, 0..) |h, i| {
                    if (h == 0 or std.mem.indexOfScalar(u32, closed[0..i], h) != null) continue;
                    closed[i] = h;
                    var gc = GemClose{ .handle = h };
                    _ = linux.ioctl(self.fd, ioc(W, 0x09, GemClose), @intFromPtr(&gc));
                }
            }
            var ph = PrimeHandle{ .handle = fb.handles[0], .flags = @as(u32, @bitCast(linux.O{ .CLOEXEC = true })) };
            if (util.isErr(linux.ioctl(self.fd, ioc(RW, 0x2d, PrimeHandle), @intFromPtr(&ph)))) return null;
            return ph.fd;
        }
        return null;
    }
};

/// First card that is driving a display.
pub fn openActiveCard() !Card {
    for ([_][*:0]const u8{ "/dev/dri/card0", "/dev/dri/card1", "/dev/dri/card2", "/dev/dri/card3" }) |path| {
        const card = Card.open(path) catch continue;
        if (card.hasActivePlane()) return card;
        _ = linux.close(card.fd);
    }
    return error.NoActiveDisplay;
}

pub fn fourccStr(f: u32) [4]u8 {
    return .{ @truncate(f), @truncate(f >> 8), @truncate(f >> 16), @truncate(f >> 24) };
}

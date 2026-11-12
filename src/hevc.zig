//! HEVC bitstream helpers: Annex B -> length-prefixed NAL units (what
//! Matroska stores) and the hvcC codec-private record.
const std = @import("std");

pub const NalType = struct {
    pub const vps = 32;
    pub const sps = 33;
    pub const pps = 34;
};

pub fn nalType(nal: []const u8) u8 {
    return (nal[0] >> 1) & 0x3f;
}

/// Iterates NAL units of an Annex B stream (start codes 00 00 01).
const AnnexB = struct {
    data: []const u8,
    pos: usize,

    fn init(data: []const u8) AnnexB {
        const first = std.mem.indexOf(u8, data, &.{ 0, 0, 1 }) orelse data.len;
        return .{ .data = data, .pos = @min(first + 3, data.len) };
    }
    fn next(it: *AnnexB) ?[]const u8 {
        if (it.pos >= it.data.len) return null;
        const start = it.pos;
        const sc = std.mem.indexOfPos(u8, it.data, start, &.{ 0, 0, 1 });
        var end = sc orelse it.data.len;
        it.pos = if (sc) |s| s + 3 else it.data.len;
        // Zeros before the next start code belong to it, not to this NAL.
        while (end > start and it.data[end - 1] == 0) end -= 1;
        return it.data[start..end];
    }
};

/// Returns a newly allocated copy with each NAL prefixed by its u32 BE length.
pub fn toLengthPrefixed(gpa: std.mem.Allocator, annexb: []const u8) ![]u8 {
    var total: usize = 0;
    var it = AnnexB.init(annexb);
    while (it.next()) |nal| total += 4 + nal.len;
    const out = try gpa.alloc(u8, total);
    var off: usize = 0;
    it = AnnexB.init(annexb);
    while (it.next()) |nal| {
        std.mem.writeInt(u32, out[off..][0..4], @intCast(nal.len), .big);
        @memcpy(out[off + 4 ..][0..nal.len], nal);
        off += 4 + nal.len;
    }
    return out;
}

pub const ParamSets = struct {
    vps: []const u8 = "",
    sps: []const u8 = "",
    pps: []const u8 = "",

    /// Finds VPS/SPS/PPS in a length-prefixed keyframe packet.
    pub fn find(packet: []const u8) ?ParamSets {
        var ps = ParamSets{};
        var off: usize = 0;
        while (off + 4 <= packet.len) {
            const n = std.mem.readInt(u32, packet[off..][0..4], .big);
            if (off + 4 + n > packet.len or n < 2) break;
            const nal = packet[off + 4 ..][0..n];
            switch (nalType(nal)) {
                NalType.vps => ps.vps = nal,
                NalType.sps => ps.sps = nal,
                NalType.pps => ps.pps = nal,
                else => {},
            }
            off += 4 + n;
        }
        if (ps.vps.len == 0 or ps.sps.len == 0 or ps.pps.len == 0) return null;
        return ps;
    }
};

/// Builds the HEVCDecoderConfigurationRecord (8-bit 4:2:0). Returns the
/// used part of `out`.
pub fn buildHvcC(ps: ParamSets, out: []u8) ![]u8 {
    // The 12-byte general profile_tier_level sits right after the 2-byte NAL
    // header and 1 byte of ids in the SPS; undo emulation prevention first.
    var rbsp: [15]u8 = undefined;
    var n: usize = 0;
    var zeros: usize = 0;
    for (ps.sps) |byte| {
        if (n == rbsp.len) break;
        if (zeros >= 2 and byte == 3) {
            zeros = 0;
            continue;
        }
        zeros = if (byte == 0) zeros + 1 else 0;
        rbsp[n] = byte;
        n += 1;
    }
    if (n < rbsp.len) return error.SpsTooShort;
    const ptl = rbsp[3..15];

    const need = 23 + 3 * 5 + ps.vps.len + ps.sps.len + ps.pps.len;
    if (out.len < need) return error.BufferTooSmall;
    out[0] = 1; // configurationVersion
    @memcpy(out[1..13], ptl); // profile space/tier/idc, compat flags, constraints, level
    out[13] = 0xF0; // min_spatial_segmentation_idc = 0
    out[14] = 0x00;
    out[15] = 0xFC; // parallelismType = 0
    out[16] = 0xFC | 1; // chroma 4:2:0
    out[17] = 0xF8; // luma 8 bit
    out[18] = 0xF8; // chroma 8 bit
    out[19] = 0; // avgFrameRate unknown
    out[20] = 0;
    out[21] = (1 << 3) | (1 << 2) | 3; // 1 temporal layer, nested, 4-byte lengths
    out[22] = 3; // arrays
    var off: usize = 23;
    const sets = [_]struct { t: u8, d: []const u8 }{
        .{ .t = NalType.vps, .d = ps.vps },
        .{ .t = NalType.sps, .d = ps.sps },
        .{ .t = NalType.pps, .d = ps.pps },
    };
    for (sets) |s| {
        out[off] = 0x80 | s.t; // array_completeness + type
        std.mem.writeInt(u16, out[off + 1 ..][0..2], 1, .big);
        std.mem.writeInt(u16, out[off + 3 ..][0..2], @intCast(s.d.len), .big);
        @memcpy(out[off + 5 ..][0..s.d.len], s.d);
        off += 5 + s.d.len;
    }
    return out[0..off];
}

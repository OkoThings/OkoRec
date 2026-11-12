//! SPA POD (PipeWire's serialization format) builder and reader. The C API
//! for this is variadic macros, so it's reimplemented here: a POD is
//! {size:u32, type:u32, body...} padded to 8 bytes.
const std = @import("std");

pub const T = struct {
    pub const Id = 3;
    pub const Int = 4;
    pub const Long = 5;
    pub const Rectangle = 10;
    pub const Fraction = 11;
    pub const Object = 15;
    pub const Choice = 19;
};

pub const ChoiceKind = enum(u32) { none = 0, range = 1, step = 2, enumeration = 3, flags = 4 };

pub const Builder = struct {
    buf: []align(8) u8,
    len: usize = 0,

    pub fn raw32(b: *Builder, v: u32) void {
        std.mem.writeInt(u32, b.buf[b.len..][0..4], v, .little);
        b.len += 4;
    }
    pub fn raw64(b: *Builder, v: u64) void {
        std.mem.writeInt(u64, b.buf[b.len..][0..8], v, .little);
        b.len += 8;
    }
    fn pad(b: *Builder) void {
        while (b.len % 8 != 0) : (b.len += 1) b.buf[b.len] = 0;
    }
    fn begin(b: *Builder, pod_type: u32) usize {
        const at = b.len;
        b.raw32(0);
        b.raw32(pod_type);
        return at;
    }
    /// Closes an object or choice opened at `at`.
    pub fn end(b: *Builder, at: usize) void {
        std.mem.writeInt(u32, b.buf[at..][0..4], @intCast(b.len - at - 8), .little);
        b.pad();
    }
    pub fn object(b: *Builder, object_type: u32, object_id: u32) usize {
        const at = b.begin(T.Object);
        b.raw32(object_type);
        b.raw32(object_id);
        return at;
    }
    /// Property header; follow with exactly one value.
    pub fn prop(b: *Builder, key: u32, flags: u32) void {
        b.raw32(key);
        b.raw32(flags);
    }
    pub fn id(b: *Builder, v: u32) void {
        b.raw32(4);
        b.raw32(T.Id);
        b.raw32(v);
        b.pad();
    }
    pub fn int(b: *Builder, v: i32) void {
        b.raw32(4);
        b.raw32(T.Int);
        b.raw32(@bitCast(v));
        b.pad();
    }
    pub fn long(b: *Builder, v: u64) void {
        b.raw32(8);
        b.raw32(T.Long);
        b.raw64(v);
    }
    pub fn pair(b: *Builder, pod_type: u32, x: u32, y: u32) void {
        b.raw32(8);
        b.raw32(pod_type);
        b.raw32(x);
        b.raw32(y);
    }
    /// Array of Id values.
    pub fn idArray(b: *Builder, values: []const u32) void {
        b.raw32(@intCast(8 + 4 * values.len));
        b.raw32(13); // Array
        b.raw32(4);
        b.raw32(T.Id);
        for (values) |v| b.raw32(v);
        b.pad();
    }
    /// Opens a choice; follow with raw values (first one is the default),
    /// then `end`.
    pub fn choice(b: *Builder, kind: ChoiceKind, child_type: u32, child_size: u32) usize {
        const at = b.begin(T.Choice);
        b.raw32(@intFromEnum(kind));
        b.raw32(0);
        b.raw32(child_size);
        b.raw32(child_type);
        return at;
    }
    /// Pointer to the POD starting at `at`, for handing to PipeWire.
    pub fn ptr(b: *Builder, at: usize) *const anyopaque {
        return @ptrCast(b.buf.ptr + at);
    }
};

pub const Prop = struct {
    key: u32,
    flags: u32,
    type: u32,
    body: []const u8,

    /// The value's bytes; for a choice, its first (default) alternative.
    pub fn value(p: Prop) []const u8 {
        if (p.type != T.Choice) return p.body;
        const child_size = std.mem.readInt(u32, p.body[8..12], .little);
        return p.body[16..][0..child_size];
    }
    /// For a choice: all alternatives after the default, `size` bytes each.
    pub fn alternatives(p: Prop) struct { data: []const u8, size: usize } {
        if (p.type != T.Choice) return .{ .data = p.body, .size = p.body.len };
        const child_size = std.mem.readInt(u32, p.body[8..12], .little);
        return .{ .data = p.body[16 + child_size ..], .size = child_size };
    }
    pub fn asU32(p: Prop) u32 {
        return std.mem.readInt(u32, p.value()[0..4], .little);
    }
    pub fn asU64(p: Prop) u64 {
        return std.mem.readInt(u64, p.value()[0..8], .little);
    }
    pub fn asPair(p: Prop) [2]u32 {
        const v = p.value();
        return .{ std.mem.readInt(u32, v[0..4], .little), std.mem.readInt(u32, v[4..8], .little) };
    }
};

/// Iterates the properties of an object POD.
pub const ObjectIter = struct {
    data: []const u8,
    pos: usize = 16,

    pub fn init(pod: [*]const u8) ?ObjectIter {
        const size = std.mem.readInt(u32, pod[0..4], .little);
        if (std.mem.readInt(u32, pod[4..8], .little) != T.Object or size < 8) return null;
        return .{ .data = pod[0 .. 8 + size] };
    }
    pub fn next(it: *ObjectIter) ?Prop {
        if (it.pos + 16 > it.data.len) return null;
        const d = it.data[it.pos..];
        const size = std.mem.readInt(u32, d[8..12], .little);
        if (16 + size > d.len) return null;
        it.pos += 16 + (size + 7) / 8 * 8;
        return .{
            .key = std.mem.readInt(u32, d[0..4], .little),
            .flags = std.mem.readInt(u32, d[4..8], .little),
            .type = std.mem.readInt(u32, d[12..16], .little),
            .body = d[16..][0..size],
        };
    }
    pub fn find(pod: [*]const u8, key: u32) ?Prop {
        var it = init(pod) orelse return null;
        while (it.next()) |p| if (p.key == key) return p;
        return null;
    }
};

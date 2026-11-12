//! Desktop notifications through org.freedesktop.Notifications.
const dbus = @import("dbus.zig");

pub fn send(summary: []const u8, body: []const u8) void {
    var conn = dbus.Connection.connectSession() catch return;
    defer conn.close();
    var w = dbus.Writer{};
    w.string("OkoRec");
    w.u32_(0); // replaces_id
    w.string("media-record"); // icon
    w.string(summary);
    w.string(body);
    w.arrayEnd(w.arrayBegin(4)); // actions
    w.arrayEnd(w.arrayBegin(8)); // hints
    w.i32_(3000); // ms
    const serial = conn.send(.{
        .dest = "org.freedesktop.Notifications",
        .path = "/org/freedesktop/Notifications",
        .interface = "org.freedesktop.Notifications",
        .member = "Notify",
        .signature = "susssasa{sv}i",
        .body = w.bytes(),
    }) catch return;
    _ = conn.waitReply(serial) catch {};
}

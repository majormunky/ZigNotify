const std = @import("std");
const zig_notify = @import("zig_notify");
const c = @cImport({
    @cInclude("systemd/sd-bus.h");
});

pub fn main() !void {
    var bus: ?*c.sd_bus = null;

    const r = c.sd_bus_open_user(&bus);
    if (r < 0) {
        std.log.err("failed to connect to session bus: {d}", .{r});
        return error.BusConnectFailed;
    }
    defer _ = c.sd_bus_unref(bus);

    std.log.info("Connected to session bus!", .{});

    var unique_name: [*c]const u8 = null;
    const r2 = c.sd_bus_get_unique_name(bus, &unique_name);
    if (r2 >= 0) {
        std.log.info("Our bus name: {s}", .{unique_name});
    }

    const r3 = c.sd_bus_request_name(bus, "org.freedesktop.Notifications", 0);
    if (r3 < 0) {
        std.log.err("Failed to request bus name(is another daemon running?): {d}", .{r3});
        return error.RequestNameFailed;
    }
    defer _ = c.sd_bus_release_name(bus, "org.freedesktop.Notifications");

    std.log.info("Claimed org.freedesktop.Notifications", .{});
}

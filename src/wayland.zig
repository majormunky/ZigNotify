const std = @import("std");
const c = @cImport({
    @cInclude("wayland-client.h");
});

pub fn connect() !*c.wl_display {
    const display = c.wl_display_connect(null);
    if (display == null) {
        std.log.err("Failed to connect to Wayland display", .{});
        return error.WaylandConnectFailed;
    }

    std.log.info("Connected to Wayland display", .{});
    return display.?;
}

pub fn disconnect(display: *c.wl_display) void {
    c.wl_display_disconnect(display);
}

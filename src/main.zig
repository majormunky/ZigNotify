const std = @import("std");
const zig_notify = @import("zig_notify");
const c = @cImport({
    @cInclude("systemd/sd-bus.h");
    @cInclude("vtable.h");
});

export fn handle_get_capabilities(
    msg: ?*c.sd_bus_message,
    _: ?*anyopaque,
    _: ?*c.sd_bus_error,
) callconv(.c) c_int {
    std.log.info("GetCapabilities called", .{});
    var reply: ?*c.sd_bus_message = null;
    var r = c.sd_bus_message_new_method_return(msg, &reply);
    if (r < 0) return r;
    defer _ = c.sd_bus_message_unref(reply);

    r = c.sd_bus_message_open_container(reply, 'a', "s");
    if (r < 0) return r;
    r = c.sd_bus_message_append_basic(reply, 's', @as([*:0]const u8, "body"));
    if (r < 0) return r;
    r = c.sd_bus_message_close_container(reply);
    if (r < 0) return r;

    r = c.sd_bus_send(null, reply, null);
    return if (r < 0) r else 1;
}

export fn handle_get_server_information(
    msg: ?*c.sd_bus_message,
    _: ?*anyopaque,
    _: ?*c.sd_bus_error,
) callconv(.c) c_int {
    std.log.info("GetServerInformation called", .{});
    const r = c.sd_bus_reply_method_return(
        msg,
        "ssss",
        @as([*:0]const u8, "zignotify"),
        @as([*:0]const u8, "zignotify"),
        @as([*:0]const u8, "0.1.0"),
        @as([*:0]const u8, "1.2"),
    );
    return if (r < 0) r else 1;
}

pub fn main() !void {
    var bus: ?*c.sd_bus = null;

    var r = c.sd_bus_open_user(&bus);
    if (r < 0) {
        std.log.err("failed to connect to session bus: {d}", .{r});
        return error.BusConnectFailed;
    }
    defer _ = c.sd_bus_unref(bus);

    std.log.info("Connected to session bus!", .{});

    var unique_name: [*c]const u8 = null;
    r = c.sd_bus_get_unique_name(bus, &unique_name);
    if (r >= 0) {
        std.log.info("Our bus name: {s}", .{unique_name});
    }

    r = c.sd_bus_request_name(bus, "org.freedesktop.Notifications", 0);
    if (r < 0) {
        std.log.err("Failed to request bus name(is another daemon running?): {d}", .{r});
        return error.RequestNameFailed;
    }
    defer _ = c.sd_bus_release_name(bus, "org.freedesktop.Notifications");

    var slot: ?*c.sd_bus_slot = null;
    r = c.sd_bus_add_object_vtable(
        bus,
        &slot,
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        @ptrCast(c.get_notification_vtable()),
        null,
    );
    if (r < 0) {
        std.log.err("Failed to register vtable: {d}", .{r});
        return error.VTableFailed;
    }
    defer _ = c.sd_bus_slot_unref(slot);

    std.log.info("Claimed org.freedesktop.Notifications", .{});

    std.log.info("Listening for notifications...", .{});

    while (true) {
        r = c.sd_bus_process(bus, null);
        if (r < 0) {
            std.log.err("Bus process error: {d}", .{r});
            return error.ProcessFailed;
        }

        if (r > 0) continue;

        r = c.sd_bus_wait(bus, std.math.maxInt(u64));
        if (r < 0) {
            std.log.err("Bus wait error: {d}", .{r});
            return error.WaitFailed;
        }
    }
}

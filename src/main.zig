const std = @import("std");
const zig_notify = @import("zig_notify");
const c = @cImport({
    @cInclude("systemd/sd-bus.h");
    @cInclude("vtable.h");
});

var next_notification_id: u32 = 1;

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

export fn handle_notify(
    msg: ?*c.sd_bus_message,
    _: ?*anyopaque,
    _: ?*c.sd_bus_error,
) callconv(.c) c_int {
    std.log.info("!!!! Handle notify called !!!", .{});

    var app_name: [*c]const u8 = null;
    var replaces_id: u32 = 0;
    var app_icon: [*c]const u8 = null;
    var summary: [*c]const u8 = null;
    var body: [*c]const u8 = null;
    var timeout: i32 = -1;

    std.log.info("After variables", .{});

    // read the first 5 args
    var r = c.sd_bus_message_read(msg, "susss", &app_name, &replaces_id, &app_icon, &summary, &body);
    if (r < 0) return r;

    std.log.info("After reading 5 variables", .{});

    // skip actions array and hits dict for now
    r = c.sd_bus_message_skip(msg, "as");
    if (r < 0) return r;
    r = c.sd_bus_message_skip(msg, "a{sv}");
    if (r < 0) return r;

    std.log.info("After skipping actions and hits dict", .{});

    // read timeout
    r = c.sd_bus_message_read(msg, "i", &timeout);
    if (r < 0) return r;

    std.log.info("After read timeout", .{});

    // return a notification id
    const id = next_notification_id;
    next_notification_id +%= 1;
    if (next_notification_id == 0) next_notification_id = 1;

    std.log.info("Notify: id={d} app={s} summary={s} body={s} timeout={d}", .{ id, app_name, summary, body, timeout });

    r = c.sd_bus_reply_method_return(msg, "u", id);
    return if (r < 0) r else 1;
}

export fn handle_close_notification(
    msg: ?*c.sd_bus_message,
    _: ?*anyopaque,
    _: ?*c.sd_bus_error,
) callconv(.c) c_int {
    var id: u32 = 0;
    var r = c.sd_bus_message_read(msg, "u", &id);
    if (r < 0) return r;

    std.log.info("CloseNotification id={d}", .{id});

    r = c.sd_bus_reply_method_return(msg, "");
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

const std = @import("std");
const zig_notify = @import("zig_notify");
const c = @cImport({
    @cInclude("systemd/sd-bus.h");
    @cInclude("vtable.h");
});
const wayland = @import("wayland.zig");
const state_mod = @import("state.zig");

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
    var app_name: [*c]const u8 = null;
    var replaces_id: u32 = 0;
    var app_icon: [*c]const u8 = null;
    var summary: [*c]const u8 = null;
    var body: [*c]const u8 = null;
    var timeout: i32 = -1;

    // read the first 5 args
    var r = c.sd_bus_message_read(msg, "susss", &app_name, &replaces_id, &app_icon, &summary, &body);
    if (r < 0) return r;

    // skip actions array and hits dict for now
    r = c.sd_bus_message_skip(msg, "as");
    if (r < 0) return r;
    r = c.sd_bus_message_skip(msg, "a{sv}");
    if (r < 0) return r;

    // read timeout
    r = c.sd_bus_message_read(msg, "i", &timeout);
    if (r < 0) return r;

    if (state_mod.global_state) |state| {
        if (state.surface) |*surf| {
            wayland.drawSurface(
                state.display,
                state.globals,
                surf,
                std.mem.sliceTo(summary, 0),
                std.mem.sliceTo(body, 0),
            ) catch |err| {
                std.log.err("drawSurface failed: {any}", .{err});
            };
        }
    }

    // return a notification id
    const id = next_notification_id;
    next_notification_id +%= 1;
    if (next_notification_id == 0) next_notification_id = 1;

    if (state_mod.global_state) |state| {
        state.active = .{
            .id = id,
            .created_at = std.time.milliTimestamp(),
            .timeout_ms = timeout,
        };
    }

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

fn checkExpiry() void {
    const state = state_mod.global_state orelse return;
    const active = state.active orelse return;

    // timeout -1 means server default, 0 means never expire
    const effective_timeout: i32 = if (active.timeout_ms <= 0) 5000 else active.timeout_ms;
    const now = std.time.milliTimestamp();

    if (now - active.created_at >= effective_timeout) {
        std.log.info("Notification {d} expired, dismissing", .{active.id});
        const id = active.id;
        state.active = null;

        // hide the surface by clearing it
        if (state.surface) |*surf| {
            wayland.clearSurface(surf);
            _ = wayland.c.wl_display_flush(state.display);
        }

        const bus_global: *c.sd_bus = @ptrCast(@alignCast(state.bus));

        // emit notification closed signal
        _ = c.sd_bus_emit_signal(
            bus_global,
            "/org/freedesktop/Notifications",
            "org.freedesktop.Notifications",
            "NotificationClosed",
            "uu",
            id,
            @as(u32, 1), // reason 1 = expired
        );
    }
}

pub fn main() !void {
    // wayland connect
    const display = try wayland.connect();
    defer wayland.disconnect(display);

    const globals = try wayland.getGlobals(display);
    if (globals.compositor == null) return error.NoCompositor;
    if (globals.shm == null) return error.NoShm;
    if (globals.layer_shell == null) return error.NoLayerShell;
    std.log.info("All Wayland globals bound", .{});

    var surface = try wayland.createSurface(display, globals);

    try wayland.drawSurface(display, globals, &surface, "zignotify", "ready");

    var bus: ?*c.sd_bus = null;

    var r = c.sd_bus_open_user(&bus);
    if (r < 0) {
        std.log.err("failed to connect to session bus: {d}", .{r});
        return error.BusConnectFailed;
    }
    defer _ = c.sd_bus_unref(bus);

    var state = state_mod.State{
        .display = display,
        .globals = globals,
        .surface = surface,
        .bus = bus.?,
    };
    state_mod.global_state = &state;

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

        checkExpiry();

        r = c.sd_bus_wait(bus, 100 * std.time.us_per_ms);
        if (r < 0) {
            std.log.err("Bus wait error: {d}", .{r});
            return error.WaitFailed;
        }
    }
}

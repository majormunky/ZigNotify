const std = @import("std");
const zig_notify = @import("zig_notify");
const c = @cImport({
    @cInclude("systemd/sd-bus.h");
    @cInclude("vtable.h");
});
const wayland = @import("wayland.zig");
const state_mod = @import("state.zig");
const config_mod = @import("config.zig");
const inotify_mod = @import("inotify.zig");

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

    // skip actions array
    r = c.sd_bus_message_skip(msg, "as");
    if (r < 0) return r;

    var urgency: state_mod.Urgency = .normal;
    r = c.sd_bus_message_enter_container(msg, 'a', "{sv}");
    if (r > 0) {
        while (c.sd_bus_message_enter_container(msg, 'e', "sv") > 0) {
            var key: [*c]const u8 = null;

            _ = c.sd_bus_message_read_basic(msg, 's', @ptrCast(&key));
            const key_str = std.mem.sliceTo(key, 0);
            if (std.mem.eql(u8, key_str, "urgency")) {
                _ = c.sd_bus_message_enter_container(msg, 'v', "y");
                var u: u8 = 1;
                _ = c.sd_bus_message_read_basic(msg, 'y', @ptrCast(&u));
                urgency = @enumFromInt(@min(u, 2));
                _ = c.sd_bus_message_exit_container(msg);
            } else {
                _ = c.sd_bus_message_skip(msg, "v");
            }
            _ = c.sd_bus_message_exit_container(msg);
        }
        _ = c.sd_bus_message_exit_container(msg);
    }

    // read timeout
    r = c.sd_bus_message_read(msg, "i", &timeout);
    if (r < 0) return r;

    // return a notification id
    const id = next_notification_id;
    next_notification_id +%= 1;
    if (next_notification_id == 0) next_notification_id = 1;

    if (state_mod.global_state) |state| {
        state.addPending(
            id,
            timeout,
            urgency,
            std.mem.sliceTo(summary, 0),
            std.mem.sliceTo(body, 0),
        );
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

    if (state_mod.global_state) |state| {
        if (state.removeNotification(id)) |*n| {
            wayland.destroySurface(@constCast(&n.surface));
            _ = wayland.c.wl_display_flush(state.display);
            state.repositionAll();

            const sd_bus: *c.sd_bus = @ptrCast(@alignCast(state.bus));
            _ = c.sd_bus_emit_signal(
                sd_bus,
                "/org/freedesktop/Notifications",
                "org.freedesktop.Notifications",
                "NotificationClosed",
                "uu",
                id,
                @as(u32, 1),
            );
        }
    }

    r = c.sd_bus_reply_method_return(msg, "");
    return if (r < 0) r else 1;
}

fn checkExpiry() void {
    const state = state_mod.global_state orelse return;
    const now = std.time.milliTimestamp();

    for (&state.active) |*slot| {
        if (slot.*) |*n| {
            const effective_timeout: i64 = if (n.timeout_ms <= 0) 5000 else n.timeout_ms;
            if (now - n.created_at >= effective_timeout) {
                std.log.info("Notification {d} expired", .{n.id});
                const id = n.id;

                wayland.destroySurface(&n.surface);
                _ = wayland.c.wl_display_flush(state.display);
                slot.* = null;

                state.repositionAll();

                const sd_bus: *c.sd_bus = @ptrCast(@alignCast(state.bus));
                _ = c.sd_bus_emit_signal(
                    sd_bus,
                    "/org/freedesktop/Notifications",
                    "org.freedesktop.Notifications",
                    "NotificationClosed",
                    "uu",
                    id,
                    @as(u32, 1),
                );
            }
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // wayland connect
    const display = try wayland.connect();
    defer wayland.disconnect(display);

    const globals = try wayland.getGlobals(display);
    if (globals.compositor == null) return error.NoCompositor;
    if (globals.shm == null) return error.NoShm;
    if (globals.layer_shell == null) return error.NoLayerShell;
    std.log.info("All Wayland globals bound", .{});

    try wayland.setupPointer(globals);

    var bus: ?*c.sd_bus = null;

    var r = c.sd_bus_open_user(&bus);
    if (r < 0) {
        std.log.err("failed to connect to session bus: {d}", .{r});
        return error.BusConnectFailed;
    }
    defer _ = c.sd_bus_unref(bus);

    const config = try config_mod.load(allocator);

    const home = std.posix.getenv("HOME") orelse "";

    const config_path_slice = try std.fmt.allocPrint(allocator, "{s}/.config/zignotify/config", .{home});
    defer allocator.free(config_path_slice);
    const config_path = try allocator.dupeZ(u8, config_path_slice);
    defer allocator.free(config_path);

    var watcher = inotify_mod.Watcher.init(config_path) catch |err| blk: {
        std.log.warn("Could not watch config file: {any}", .{err});
        break :blk null;
    };
    defer if (watcher) |*w| w.deinit();

    var state = state_mod.State.init(display, globals, bus.?, config);
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

    // main event loop
    while (true) {
        r = c.sd_bus_process(bus, null);
        if (r < 0) {
            std.log.err("Bus process error: {d}", .{r});
            return error.ProcessFailed;
        }
        if (r > 0) continue;

        checkExpiry();

        // Process pending notifications
        if (state_mod.global_state) |st| {
            for (&st.pending) |*sl| {
                if (sl.*) |p| {
                    const y_offset = st.count() * 110;
                    const surf = wayland.createSurface(st.display, st.globals, @intCast(y_offset), st.config) catch continue;
                    wayland.drawSurface(
                        st.display,
                        st.globals,
                        @constCast(&surf),
                        p.summary[0..p.summary_len],
                        p.body[0..p.body_len],
                        p.urgency,
                        st.config,
                    ) catch continue;
                    st.addNotification(p.id, p.timeout_ms, p.urgency, surf);
                    sl.* = null;
                }
            }

            _ = wayland.c.wl_display_prepare_read(st.display);
            _ = wayland.c.wl_display_read_events(st.display);
            _ = wayland.c.wl_display_dispatch_pending(st.display);
            _ = wayland.c.wl_display_flush(st.display);
        }

        // check for config file changes
        if (watcher) |*w| {
            if (w.check()) {
                std.log.info("Config changed, reloading...", .{});
                const new_config = config_mod.load(allocator) catch |err| blk: {
                    std.log.err("Failed to reload config: {any}", .{err});
                    break :blk state.config;
                };
                state.config = new_config;
                std.log.info("Config reloaded", .{});
            }
        }

        r = c.sd_bus_wait(bus, 100 * std.time.us_per_ms);
        if (r < 0) {
            std.log.err("Bus wait error: {d}", .{r});
            return error.WaitFailed;
        }
    }
}

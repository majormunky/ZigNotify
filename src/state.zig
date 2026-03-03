const std = @import("std");
const wayland = @import("wayland.zig");
const config_mod = @import("config.zig");

pub const MAX_NOTIFICATIONS = 10;

pub const Urgency = enum(u8) {
    low = 0,
    normal = 1,
    critical = 2,
};

pub const ActiveNotification = struct {
    id: u32,
    created_at: i64,
    timeout_ms: i32,
    surface: wayland.Surface,
    urgency: Urgency,
};

pub const PendingNotification = struct {
    id: u32,
    timeout_ms: i32,
    urgency: Urgency,
    summary: [256]u8,
    summary_len: usize,
    body: [256]u8,
    body_len: usize,
    app_name: [256]u8,
    app_name_len: usize,
    icon: [256]u8,
    icon_len: usize,
};

pub const State = struct {
    display: *wayland.c.wl_display,
    globals: wayland.Globals,
    active: [MAX_NOTIFICATIONS]?ActiveNotification,
    pending: [MAX_NOTIFICATIONS]?PendingNotification,
    bus: *anyopaque,
    config: config_mod.Config,

    pub fn init(display: *wayland.c.wl_display, globals: wayland.Globals, bus: *anyopaque, config: config_mod.Config) State {
        return .{
            .display = display,
            .globals = globals,
            .active = [_]?ActiveNotification{null} ** MAX_NOTIFICATIONS,
            .pending = [_]?PendingNotification{null} ** MAX_NOTIFICATIONS,
            .bus = bus,
            .config = config,
        };
    }

    pub fn addPending(self: *State, id: u32, timeout_ms: i32, urgency: Urgency, summary: []const u8, body: []const u8, app_name: []const u8, icon: []const u8) void {
        for (&self.pending) |*slot| {
            if (slot.* == null) {
                var p = PendingNotification{
                    .id = id,
                    .timeout_ms = timeout_ms,
                    .urgency = urgency,
                    .summary = undefined,
                    .summary_len = summary.len,
                    .body = undefined,
                    .body_len = body.len,
                    .app_name = undefined,
                    .app_name_len = app_name.len,
                    .icon = undefined,
                    .icon_len = @min(icon.len, 255),
                };
                @memcpy(p.summary[0..p.summary_len], summary);
                @memcpy(p.body[0..p.body_len], body);
                @memcpy(p.app_name[0..p.app_name_len], app_name);
                @memcpy(p.icon[0..p.icon_len], icon[0..p.icon_len]);

                slot.* = p;
                return;
            }
        }
    }

    pub fn addNotification(self: *State, id: u32, timeout_ms: i32, urgency: Urgency, surface: wayland.Surface) void {
        for (&self.active) |*slot| {
            if (slot.* == null) {
                slot.* = .{
                    .id = id,
                    .created_at = std.time.milliTimestamp(),
                    .timeout_ms = timeout_ms,
                    .surface = surface,
                    .urgency = urgency,
                };
                return;
            }
        }
    }

    pub fn removeNotification(self: *State, id: u32) ?ActiveNotification {
        for (&self.active) |*slot| {
            if (slot.*) |n| {
                if (n.id == id) {
                    slot.* = null;
                    return n;
                }
            }
        }

        return null;
    }

    pub fn count(self: *State) usize {
        var n: usize = 0;
        for (self.active) |slot| {
            if (slot != null) n += 1;
        }
        return n;
    }

    pub fn repositionAll(self: *State) void {
        var index: u32 = 0;
        for (&self.active) |*slot| {
            if (slot.*) |*n| {
                const y_offset = index * (self.config.height + self.config.margin);
                wayland.repositionSurface(self.display, &n.surface, y_offset, self.config);
                index += 1;
            }
        }
    }
};

pub var global_state: ?*State = null;

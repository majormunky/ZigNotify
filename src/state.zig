const std = @import("std");
const wayland = @import("wayland.zig");

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
};

pub const State = struct {
    display: *wayland.c.wl_display,
    globals: wayland.Globals,
    active: [MAX_NOTIFICATIONS]?ActiveNotification,
    pending: [MAX_NOTIFICATIONS]?PendingNotification,
    bus: *anyopaque,

    pub fn init(display: *wayland.c.wl_display, globals: wayland.Globals, bus: *anyopaque) State {
        return .{
            .display = display,
            .globals = globals,
            .active = [_]?ActiveNotification{null} ** MAX_NOTIFICATIONS,
            .pending = [_]?PendingNotification{null} ** MAX_NOTIFICATIONS,
            .bus = bus,
        };
    }

    pub fn addPending(self: *State, id: u32, timeout_ms: i32, urgency: Urgency, summary: []const u8, body: []const u8) void {
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
                };
                @memcpy(p.summary[0..summary.len], summary);
                @memcpy(p.body[0..body.len], body);
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
                const y_offset = index * 110;
                wayland.repositionSurface(self.display, &n.surface, y_offset);
                index += 1;
            }
        }
    }
};

pub var global_state: ?*State = null;

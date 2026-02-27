const std = @import("std");
const wayland = @import("wayland.zig");

pub const MAX_NOTIFICATIONS = 10;

pub const ActiveNotification = struct {
    id: u32,
    created_at: i64,
    timeout_ms: i32,
    surface: wayland.Surface,
};

pub const State = struct {
    display: *wayland.c.wl_display,
    globals: wayland.Globals,
    active: [MAX_NOTIFICATIONS]?ActiveNotification,
    bus: *anyopaque,

    pub fn init(display: *wayland.c.wl_display, globals: wayland.Globals, bus: *anyopaque) State {
        return .{
            .display = display,
            .globals = globals,
            .active = [_]?ActiveNotification{null} ** MAX_NOTIFICATIONS,
            .bus = bus,
        };
    }

    pub fn addNotification(self: *State, id: u32, timeout_ms: i32, surface: wayland.Surface) void {
        for (&self.active) |*slot| {
            if (slot.* == null) {
                slot.* = .{
                    .id = id,
                    .created_at = std.time.milliTimestamp(),
                    .timeout_ms = timeout_ms,
                    .surface = surface,
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

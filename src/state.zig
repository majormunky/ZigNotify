const std = @import("std");
const wayland = @import("wayland.zig");

pub const ActiveNotification = struct {
    id: u32,
    created_at: i64,
    timeout_ms: i32,
};

pub const State = struct {
    display: *@import("wayland.zig").c.wl_display,
    globals: wayland.Globals,
    surface: ?wayland.Surface,
    active: ?ActiveNotification = null,
    bus: *anyopaque,
};

pub var global_state: ?*State = null;

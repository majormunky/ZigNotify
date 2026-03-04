const std = @import("std");
pub const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xdg-shell.h");
    @cInclude("wlr-layer-shell-unstable-v1.h");
    @cInclude("cairo/cairo.h");
    @cInclude("gdk-pixbuf/gdk-pixbuf.h");
});
const posix = std.posix;
const state_mod = @import("state.zig");

var g_pointer_x: f64 = 0;
var g_pointer_y: f64 = 0;
var g_clicked_surface: ?*c.wl_surface = null;

pub const Globals = struct {
    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,
    seat: ?*c.wl_seat = null,
};

pub const Surface = struct {
    surface: *c.wl_surface,
    layer_surface: *c.zwlr_layer_surface_v1,
    width: u32,
    height: u32,
    configured: bool,
};

// Pointer handling
fn pointerEnter(
    _: ?*anyopaque,
    _: ?*c.wl_pointer,
    _: u32,
    surface: ?*c.wl_surface,
    _: c.wl_fixed_t,
    _: c.wl_fixed_t,
) callconv(.c) void {
    g_clicked_surface = surface;
}

fn pointerLeave(
    _: ?*anyopaque,
    _: ?*c.wl_pointer,
    _: u32,
    _: ?*c.wl_surface,
) callconv(.c) void {
    g_clicked_surface = null;
}

fn pointerMotion(
    _: ?*anyopaque,
    _: ?*c.wl_pointer,
    _: u32,
    x: c.wl_fixed_t,
    y: c.wl_fixed_t,
) callconv(.c) void {
    g_pointer_x = c.wl_fixed_to_double(x);
    g_pointer_y = c.wl_fixed_to_double(y);
}

fn pointerButton(
    _: ?*anyopaque,
    _: ?*c.wl_pointer,
    _: u32,
    _: u32,
    button: u32,
    state: u32,
) callconv(.c) void {
    // button 272 = left click, state 1 = pressed
    if (button == 272 and state == 1) {
        if (g_clicked_surface) |surf| {
            dismissSurface(surf);
        }
    }
}

fn pointerAxis(
    _: ?*anyopaque,
    _: ?*c.wl_pointer,
    _: u32,
    _: u32,
    _: c.wl_fixed_t,
) callconv(.c) void {}

const pointer_listener = c.wl_pointer_listener{
    .enter = pointerEnter,
    .leave = pointerLeave,
    .motion = pointerMotion,
    .button = pointerButton,
    .axis = pointerAxis,
};

pub fn setupPointer(globals: Globals) !void {
    const seat = globals.seat orelse return error.NoSeat;
    const pointer = c.wl_seat_get_pointer(seat) orelse return error.NoPointer;
    _ = c.wl_pointer_add_listener(pointer, &pointer_listener, null);
    std.log.info("Pointer listener setup", .{});
}

fn drawIcon(cr: ?*c.cairo_t, icon: []const u8, x: f64, y: f64, size: f64) void {
    if (icon.len == 0) {
        std.log.info("drawIcon: icon is empty", .{});
        return;
    }

    if (!std.mem.startsWith(u8, icon, "/")) {
        std.log.info("drawIcon: icon does not start with /", .{});
        return;
    }

    var buf: [256:0]u8 = undefined;
    const icon_z = std.fmt.bufPrintZ(&buf, "{s}", .{icon}) catch return;
    std.log.info("drawIcon: loading {s}", .{icon_z});

    const pixbuf = c.gdk_pixbuf_new_from_file_at_scale(
        icon_z.ptr,
        @intFromFloat(size),
        @intFromFloat(size),
        1, // preserve aspect ratio
        null,
    );
    if (pixbuf == null) {
        std.log.info("drawIcon: pixbuf is null, failed to load image", .{});
        return;
    }
    defer c.g_object_unref(pixbuf);
    std.log.info("drawIcon: pixbuf loaded successfully", .{});

    // convert to cairo
    const width = c.gdk_pixbuf_get_width(pixbuf);
    const height = c.gdk_pixbuf_get_height(pixbuf);
    const row_stride = c.gdk_pixbuf_get_rowstride(pixbuf);
    const pixels = c.gdk_pixbuf_get_pixels(pixbuf);
    const has_alpha = c.gdk_pixbuf_get_has_alpha(pixbuf);

    std.log.info("drawIcon: width: {d}", .{width});
    std.log.info("drawIcon: height: {d}", .{height});
    std.log.info("drawIcon: row_stride: {d}", .{row_stride});

    const format = if (has_alpha != 0) c.CAIRO_FORMAT_ARGB32 else c.CAIRO_FORMAT_RGB24;

    std.log.info("drawIcon: format={d}", .{format});

    const icon_surface = c.cairo_image_surface_create(format, width, height);
    if (icon_surface == null) return;
    defer c.cairo_surface_destroy(icon_surface);

    const dst = c.cairo_image_surface_get_data(icon_surface);
    if (dst == null) {
        std.log.info("drawIcon: dst is null", .{});
        return;
    }
    const dst_stride = c.cairo_image_surface_get_stride(icon_surface);

    std.log.info("drawIcon: _dst_stride={d}", .{dst_stride});

    // convert RGBA (gdk-pixbuf) to ARGB(cairo)

    const src_channels: usize = if (has_alpha != 0) @as(usize, 4) else @as(usize, 3);
    const h: usize = @intCast(width);
    const w: usize = @intCast(height);
    const src_stride: usize = @intCast(row_stride);
    const d_stride: usize = @intCast(dst_stride);

    var row: usize = 0;
    while (row < h) : (row += 1) {
        var col: usize = 0;
        while (col < w) : (col += 1) {
            const src_offset = row * src_stride + col * src_channels;
            const dst_offset = row * d_stride + col * 4;

            const r = pixels[src_offset + 0];
            const g = pixels[src_offset + 1];
            const b = pixels[src_offset + 2];
            const a: u8 = if (has_alpha != 0) pixels[src_offset + 3] else 255;

            // cairo uses premultiplied argb
            const af: u32 = a;
            dst[dst_offset + 0] = @intCast((b * af) / 255);
            dst[dst_offset + 1] = @intCast((g * af) / 255);
            dst[dst_offset + 2] = @intCast((r * af) / 255);
            dst[dst_offset + 3] = a;
        }
    }

    const center_off = (h / 2) * d_stride + (w / 2) * 4;
    std.log.info("drawIcon: first pixel ARGB: {d} {d} {d} {d}", .{ dst[center_off + 3], dst[center_off + 2], dst[center_off + 1], dst[center_off + 0] });

    c.cairo_surface_mark_dirty(icon_surface);
    c.cairo_surface_flush(icon_surface);

    std.log.info("drawIcon: setting source surface", .{});
    c.cairo_set_source_surface(cr, icon_surface, x, y);
    c.cairo_rectangle(cr, x, y, @floatFromInt(width), @floatFromInt(height));
    c.cairo_fill(cr);
    std.log.info("drawIcon: done", .{});
}

pub fn dismissSurface(surf: *c.wl_surface) void {
    const state = @import("state.zig").global_state orelse return;
    for (&state.active) |*slot| {
        if (slot.*) |*n| {
            if (n.surface.surface == surf) {
                const id = n.id;
                destroySurface(&n.surface);
                _ = c.wl_display_flush(state.display);
                slot.* = null;
                state.repositionAll();

                std.log.info("Notification {d} dismissed by click", .{id});

                // emit notificationclosed signal via state bus
                const sd_bus_c = @cImport(@cInclude("systemd/sd-bus.h"));
                const sd_bus: *sd_bus_c.sd_bus = @ptrCast(@alignCast(state.bus));
                _ = sd_bus_c.sd_bus_emit_signal(
                    sd_bus,
                    "/org/freedesktop/Notifications",
                    "org.freedesktop.Notifications",
                    "NotificationClosed",
                    "uu",
                    id,
                    @as(u32, 2), // dismissed by user
                );
                return;
            }
        }
    }
}

pub fn clearSurface(s: *Surface) void {
    c.wl_surface_attach(s.surface, null, 0, 0);
    c.wl_surface_commit(s.surface);
    s.configured = false;
}

pub fn drawSurface(display: *c.wl_display, globals: Globals, s: *Surface, summary: []const u8, body: []const u8, app_name: []const u8, icon: []const u8, urgency: state_mod.Urgency, config: @import("config.zig").Config) !void {
    const width = s.width;
    const height = s.height;
    const stride = width * 4;
    const size = stride * height;

    if (!s.configured) {
        reconfigureSurface(display, s);
    }

    // create a shared memory file
    const fd = try posix.memfd_create("munknotify-shm", 0);
    defer posix.close(fd);
    try posix.ftruncate(fd, size);

    // map it into our address space
    const data = try posix.mmap(
        null,
        size,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer posix.munmap(data);

    const cairo_surface = c.cairo_image_surface_create_for_data(
        @ptrCast(data.ptr),
        c.CAIRO_FORMAT_ARGB32,
        @intCast(width),
        @intCast(height),
        @intCast(stride),
    ) orelse return error.CairoSurfaceFailed;
    defer c.cairo_surface_destroy(cairo_surface);

    const cr = c.cairo_create(cairo_surface) orelse return error.CairoCreateFailed;
    defer c.cairo_destroy(cr);

    // draw background
    const bg = config.background_color;
    c.cairo_set_source_rgba(cr, bg.r, bg.g, bg.b, bg.a); // dark gray
    roundedRect(cr, 0, 0, @floatFromInt(width), @floatFromInt(height), config.corner_radius);
    c.cairo_fill(cr);

    roundedRect(cr, 0, 0, @floatFromInt(width), @floatFromInt(height), config.corner_radius);
    c.cairo_clip(cr);

    // accent color based on urgency
    const accent = switch (urgency) {
        .low => config.low_color,
        .normal => config.normal_color,
        .critical => config.critical_color,
    };

    c.cairo_set_source_rgba(cr, accent.r, accent.g, accent.b, accent.a);

    // draw a colored left border accent
    c.cairo_rectangle(cr, 0, 0, 4, @floatFromInt(height));
    c.cairo_fill(cr);

    // draw icon
    drawIcon(cr, icon, 10, 10, 48);

    // summary text
    var summary_buf: [256:0]u8 = undefined;
    const summary_z = std.fmt.bufPrintZ(&summary_buf, "{s}", .{summary}) catch "...";

    var body_buf: [256:0]u8 = undefined;
    const body_z = std.fmt.bufPrintZ(&body_buf, "{s}", .{body}) catch "...";

    var app_name_buf: [256:0]u8 = undefined;
    const app_name_buf_z = std.fmt.bufPrintZ(&app_name_buf, "{s}", .{app_name}) catch "...";

    const text_x: f64 = if (icon.len > 0 and std.mem.startsWith(u8, icon, "/")) 68.0 else 14.0;

    // draw app name
    c.cairo_set_source_rgba(cr, 0.6, 0.6, 0.6, 1.0); // white
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, 10.0);
    c.cairo_move_to(cr, text_x, 14);
    c.cairo_show_text(cr, app_name_buf_z.ptr);

    // draw summary text
    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 1.0); // white
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
    c.cairo_set_font_size(cr, config.font_size_summary);
    c.cairo_move_to(cr, text_x, 32);
    c.cairo_show_text(cr, summary_z.ptr);

    // draw body text
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, config.font_size_body);
    c.cairo_set_source_rgba(cr, 0.8, 0.8, 0.8, 1.0); // light grey
    c.cairo_move_to(cr, text_x, 52);
    c.cairo_show_text(cr, body_z.ptr);

    const pool = c.wl_shm_create_pool(globals.shm, fd, @intCast(size)) orelse return error.CreatePoolFailed;
    defer c.wl_shm_pool_destroy(pool);

    const buffer = c.wl_shm_pool_create_buffer(
        pool,
        0,
        @intCast(width),
        @intCast(height),
        @intCast(stride),
        c.WL_SHM_FORMAT_ARGB8888,
    ) orelse return error.CreateBufferFailed;
    defer c.wl_buffer_destroy(buffer);

    // attach buffer to surface and commit
    c.wl_surface_attach(s.surface, buffer, 0, 0);
    c.wl_surface_damage(s.surface, 0, 0, @intCast(width), @intCast(height));
    c.wl_surface_commit(s.surface);
    _ = c.wl_display_flush(display);

    std.log.info("Surface Drawn!", .{});
}

pub fn createSurface(display: *c.wl_display, globals: Globals, y_offset: u32, config: @import("config.zig").Config) !Surface {
    // create a base wayland surface
    const surface = c.wl_compositor_create_surface(globals.compositor) orelse
        return error.CreateSurfaceFailed;

    // Wrap it in a layer shell surface
    const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(globals.layer_shell, surface, null, c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "notifications") orelse return error.CreateLayerSurfaceFailed;

    const width: u32 = config.width;
    const height: u32 = config.height;
    const margin: u32 = config.margin;

    // configure the layer surface
    c.zwlr_layer_surface_v1_set_size(layer_surface, width, height);

    const anchor = switch (config.position) {
        .top_right => c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        .top_left => c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT,
        .bottom_right => c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        .bottom_left => c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT,
    };

    c.zwlr_layer_surface_v1_set_anchor(
        layer_surface,
        @intCast(anchor),
    );
    c.zwlr_layer_surface_v1_set_margin(layer_surface, @intCast(margin + y_offset), 10, 0, 0);

    var s = Surface{
        .surface = surface,
        .layer_surface = layer_surface,
        .width = width,
        .height = height,
        .configured = false,
    };

    // add a listener to the configure event
    _ = c.zwlr_layer_surface_v1_add_listener(layer_surface, &layer_surface_listener, &s);

    // commit to trigger the configure event
    c.wl_surface_commit(surface);
    _ = c.wl_display_flush(display);

    return s;
}

pub fn repositionSurface(display: *c.wl_display, s: *Surface, y_offset: u32, config: @import("config.zig").Config) void {
    c.zwlr_layer_surface_v1_set_margin(s.layer_surface, @intCast(config.margin + y_offset), @intCast(config.margin), 0, 0);
    c.wl_surface_commit(s.surface);
    _ = c.wl_display_roundtrip(display);
}

pub fn destroySurface(s: *Surface) void {
    c.zwlr_layer_surface_v1_destroy(s.layer_surface);
    c.wl_surface_destroy(s.surface);
}

pub fn reconfigureSurface(display: *c.wl_display, s: *Surface) void {
    c.zwlr_layer_surface_v1_set_size(s.layer_surface, s.width, s.height);
    c.wl_surface_commit(s.surface);
    _ = c.wl_display_roundtrip(display);
}

fn layerSurfaceConfigure(
    data: ?*anyopaque,
    layer_surface: ?*c.zwlr_layer_surface_v1,
    serial: u32,
    _: u32,
    _: u32,
) callconv(.c) void {
    const s: *Surface = @ptrCast(@alignCast(data));
    s.configured = true;
    c.zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
    std.log.info("Layer surface configured!", .{});
}

fn layerSurfaceClosed(
    _: ?*anyopaque,
    _: ?*c.zwlr_layer_surface_v1,
) callconv(.c) void {
    std.log.info("Layer surface closed", .{});
}

const layer_surface_listener = c.zwlr_layer_surface_v1_listener{
    .configure = layerSurfaceConfigure,
    .closed = layerSurfaceClosed,
};

fn registryListener(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    const globals: *Globals = @ptrCast(@alignCast(data));
    const iface = std.mem.sliceTo(interface, 0);

    std.log.info("Global: {s} (version {d})", .{ iface, version });

    if (std.mem.eql(u8, iface, "wl_compositor")) {
        globals.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, 4));
    } else if (std.mem.eql(u8, iface, "wl_shm")) {
        globals.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
    } else if (std.mem.eql(u8, iface, "zwlr_layer_shell_v1")) {
        globals.layer_shell = @ptrCast(c.wl_registry_bind(
            registry,
            name,
            &c.zwlr_layer_shell_v1_interface,
            1,
        ));
        std.log.info("Layer shell bound!", .{});
    } else if (std.mem.eql(u8, iface, "wl_seat")) {
        globals.seat = @ptrCast(c.wl_registry_bind(
            registry,
            name,
            &c.wl_seat_interface,
            1,
        ));
        std.log.info("Seat bound!", .{});
    }
}

fn registryRemoveListener(
    _: ?*anyopaque,
    _: ?*c.wl_registry,
    _: u32,
) callconv(.c) void {}

const registry_listener = c.wl_registry_listener{
    .global = registryListener,
    .global_remove = registryRemoveListener,
};

pub fn getGlobals(display: *c.wl_display) !Globals {
    var globals = Globals{};
    const registry = c.wl_display_get_registry(display);
    _ = c.wl_registry_add_listener(registry, &registry_listener, &globals);
    _ = c.wl_display_roundtrip(display);
    return globals;
}

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

fn roundedRect(cr: ?*c.cairo_t, x: f64, y: f64, width: f64, height: f64, radius: f64) void {
    c.cairo_new_path(cr);
    c.cairo_arc(cr, x + width - radius, y + radius, radius, -std.math.pi / 2.0, 0.0);
    c.cairo_arc(cr, x + width - radius, y + height - radius, radius, 0.0, std.math.pi / 2.0);
    c.cairo_arc(cr, x + radius, y + height - radius, radius, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, x + radius, y + radius, radius, std.math.pi, 3.0 * std.math.pi / 2.0);
    c.cairo_close_path(cr);
}

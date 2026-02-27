const std = @import("std");
pub const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xdg-shell.h");
    @cInclude("wlr-layer-shell-unstable-v1.h");
    @cInclude("cairo/cairo.h");
});
const posix = std.posix;

pub const Globals = struct {
    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,
};

pub const Surface = struct {
    surface: *c.wl_surface,
    layer_surface: *c.zwlr_layer_surface_v1,
    width: u32,
    height: u32,
    configured: bool,
};

pub fn clearSurface(s: *Surface) void {
    c.wl_surface_attach(s.surface, null, 0, 0);
    c.wl_surface_commit(s.surface);
    s.configured = false;
}

pub fn drawSurface(display: *c.wl_display, globals: Globals, s: *Surface, summary: []const u8, body: []const u8) !void {
    const width = s.width;
    const height = s.height;
    const stride = width * 4;
    const size = stride * height;

    if (!s.configured) {
        reconfigureSurface(display, s);
    }

    // create a shared memory file
    const fd = try posix.memfd_create("zignotify-shm", 0);
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
    c.cairo_set_source_rgba(cr, 0.18, 0.18, 0.18, 1.0); // dark gray
    c.cairo_paint(cr);

    // draw a colored left border accent
    c.cairo_set_source_rgba(cr, 0.27, 0.52, 0.95, 1.0); // blue
    c.cairo_rectangle(cr, 0, 0, 4, @floatFromInt(height));
    c.cairo_fill(cr);

    // summary text
    var summary_buf: [256:0]u8 = undefined;
    const summary_z = std.fmt.bufPrintZ(&summary_buf, "{s}", .{summary}) catch "...";

    var body_buf: [256:0]u8 = undefined;
    const body_z = std.fmt.bufPrintZ(&body_buf, "{s}", .{body}) catch "...";

    // draw summary text
    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 1.0); // white
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
    c.cairo_set_font_size(cr, 14.0);
    c.cairo_move_to(cr, 14, 22);
    c.cairo_show_text(cr, summary_z.ptr);

    // draw body text
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, 12.0);
    c.cairo_set_source_rgba(cr, 0.8, 0.8, 0.8, 1.0); // light grey
    c.cairo_move_to(cr, 14, 44);
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
    _ = c.wl_display_roundtrip(display);

    std.log.info("Surface Drawn!", .{});
}

pub fn createSurface(display: *c.wl_display, globals: Globals, y_offset: u32) !Surface {
    // create a base wayland surface
    const surface = c.wl_compositor_create_surface(globals.compositor) orelse
        return error.CreateSurfaceFailed;

    // Wrap it in a layer shell surface
    const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(globals.layer_shell, surface, null, c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "notifications") orelse return error.CreateLayerSurfaceFailed;

    const width: u32 = 300;
    const height: u32 = 100;
    const margin: u32 = 10;

    // configure the layer surface
    c.zwlr_layer_surface_v1_set_size(layer_surface, width, height);
    c.zwlr_layer_surface_v1_set_anchor(
        layer_surface,
        c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
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
    _ = c.wl_display_roundtrip(display);

    return s;
}

pub fn repositionSurface(display: *c.wl_display, s: *Surface, y_offset: u32) void {
    const margin: u32 = 10;
    c.zwlr_layer_surface_v1_set_margin(s.layer_surface, @intCast(margin + y_offset), margin, 0, 0);
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

const std = @import("std");

pub const Position = enum {
    top_right,
    top_left,
    bottom_right,
    bottom_left,
};

pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64,
};

pub const Config = struct {
    width: u32 = 300,
    height: u32 = 100,
    margin: u32 = 10,
    default_timeout: i32 = 5000,
    font_size_summary: f64 = 14.0,
    font_size_body: f64 = 12.0,
    position: Position = .top_right,
    background_color: Color = .{ .r = 0.18, .g = 0.18, .b = 0.18, .a = 1.0 },
    low_color: Color = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 },
    normal_color: Color = .{ .r = 0.27, .g = 0.52, .b = 0.95, .a = 1.0 },
    critical_color: Color = .{ .r = 0.9, .g = 0.2, .b = 0.2, .a = 1.0 },
};

pub fn load(allocator: std.mem.Allocator) !Config {
    var config = Config{};

    // build path to ~/.config/zignotify/config
    const home = std.posix.getenv("HOME") orelse return config;
    const path = try std.fmt.allocPrint(allocator, "{s}/.config/zignotify/config", .{home});
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return config,
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        // skip empty lines and comments
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // split on '='
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "width")) {
            config.width = std.fmt.parseInt(u32, val, 10) catch continue;
        } else if (std.mem.eql(u8, key, "height")) {
            config.height = std.fmt.parseInt(u32, val, 10) catch continue;
        } else if (std.mem.eql(u8, key, "margin")) {
            config.margin = std.fmt.parseInt(u32, val, 10) catch continue;
        } else if (std.mem.eql(u8, key, "default_timeout")) {
            config.default_timeout = std.fmt.parseInt(i32, val, 10) catch continue;
        } else if (std.mem.eql(u8, key, "font_size_summary")) {
            config.font_size_summary = std.fmt.parseFloat(f64, val) catch continue;
        } else if (std.mem.eql(u8, key, "font_size_body")) {
            config.font_size_body = std.fmt.parseFloat(f64, val) catch continue;
        } else if (std.mem.eql(u8, key, "position")) {
            if (std.mem.eql(u8, val, "top_right")) config.position = .top_right else if (std.mem.eql(u8, val, "top_left")) config.position = .top_left else if (std.mem.eql(u8, val, "bottom_right")) config.position = .bottom_right else if (std.mem.eql(u8, val, "bottom_left")) config.position = .bottom_left;
        } else if (std.mem.eql(u8, key, "background_color")) {
            config.background_color = parseColor(val) catch continue;
        } else if (std.mem.eql(u8, key, "low_color")) {
            config.low_color = parseColor(val) catch continue;
        } else if (std.mem.eql(u8, key, "normal_color")) {
            config.normal_color = parseColor(val) catch continue;
        } else if (std.mem.eql(u8, key, "critical_color")) {
            config.critical_color = parseColor(val) catch continue;
        }
    }

    return config;
}

fn parseColor(val: []const u8) !Color {
    var parts = std.mem.splitScalar(u8, val, ',');
    const r = try std.fmt.parseFloat(f64, std.mem.trim(u8, parts.next() orelse return error.InvalidColor, " "));
    const g = try std.fmt.parseFloat(f64, std.mem.trim(u8, parts.next() orelse return error.InvalidColor, " "));
    const b = try std.fmt.parseFloat(f64, std.mem.trim(u8, parts.next() orelse return error.InvalidColor, " "));
    const a = try std.fmt.parseFloat(f64, std.mem.trim(u8, parts.next() orelse return error.InvalidColor, " "));

    return Color{ .r = r, .g = g, .b = b, .a = a };
}

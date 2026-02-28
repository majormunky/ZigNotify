const std = @import("std");
const c = @cImport({
    @cInclude("sys/inotify.h");
});

pub const Watcher = struct {
    fd: i32,
    wd: i32,

    pub fn init(path: [:0]const u8) !Watcher {
        const fd = c.inotify_init1(c.IN_NONBLOCK);
        if (fd < 0) return error.InotifyInitFailed;

        const wd = c.inotify_add_watch(fd, path, c.IN_MODIFY | c.IN_CREATE);
        if (wd < 0) return error.InotifyAddWatchFailed;

        std.log.info("Watching config file for changes", .{});
        return .{ .fd = fd, .wd = wd };
    }

    pub fn deinit(self: *Watcher) void {
        _ = std.posix.close(@intCast(self.fd));
    }

    // returns true if the config file was modified
    pub fn check(self: *Watcher) bool {
        var buf: [4096]u8 align(@alignOf(c.inotify_event)) = undefined;
        const n = std.posix.read(@intCast(self.fd), &buf) catch return false;
        return n > 0;
    }
};

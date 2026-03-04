const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "munknotify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/gdk-pixbuf-2.0" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/glib-2.0" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/lib/glib-2.0/include" });

    // Try Ubuntu path first, fall back to Arch path
    const ubuntu_path = "/usr/lib/x86_64-linux-gnu/libsystemd.so";
    const arch_path = "/usr/lib/libsystemd.so";

    const ubuntu_exists = if (std.fs.accessAbsolute(ubuntu_path, .{})) |_| true else |_| false;

    const systemd_lib = if (ubuntu_exists) ubuntu_path else arch_path;

    exe.addObjectFile(.{ .cwd_relative = systemd_lib });

    if (ubuntu_exists) {
        exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
    }
    exe.addLibraryPath(.{ .cwd_relative = "/usr/lib" });

    exe.linkSystemLibrary("systemd");
    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("cairo");
    exe.linkSystemLibrary("gdk-pixbuf-2.0");
    exe.linkLibC();

    exe.addCSourceFile(.{ .file = b.path("src/vtable.c"), .flags = &.{ "-Wno-builtin-macro-redefined", "-I/usr/include" } });
    exe.addCSourceFile(.{ .file = b.path("src/wlr-layer-shell-unstable-v1.c"), .flags = &.{ "-Wno-builtin-macro-redefined", "-I/usr/include" } });
    exe.addCSourceFile(.{ .file = b.path("src/xdg-shell.c"), .flags = &.{ "-Wno-builtin-macro-redefined", "-I/usr/include" } });
    exe.addIncludePath(.{ .cwd_relative = "src" });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run munknotify");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/config.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

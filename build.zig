const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zignotify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.addObjectFile(.{ .cwd_relative = "/usr/lib/libsystemd.so" });
    exe.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/gdk-pixbuf-2.0" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/glib-2.0" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/lib/glib-2.0/include" });

    if (exe.rootModuleTarget().os.tag == .linux) {
        exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        exe.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    }

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
    const run_step = b.step("run", "Run zignotify");
    run_step.dependOn(&run_cmd.step);
}

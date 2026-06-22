const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wing_dep = b.dependency("wing", .{
        .target = target,
        .optimize = optimize,
    });
    const wing_mod = wing_dep.module("wing");

    // Pull wing's transitive deps so the server entrypoint can drive talon's
    // HTTP server and zio's runtime directly (same pattern as wing/build.zig).
    const talon_dep = wing_dep.builder.dependency("talon", .{
        .target = target,
        .optimize = optimize,
    });
    const talon_mod = talon_dep.module("talon");
    const zio_mod = talon_dep.builder.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    }).module("zio");

    // mantle (MySQL driver) depends on the same `../zio` package as wing/talon,
    // so Zig dedupes the module graph to a single zio instance — the runtime
    // started in server.zig and mantle's pool share one scheduler.
    const mantle_mod = b.dependency("mantle", .{
        .target = target,
        .optimize = optimize,
    }).module("mantle");

    const exe = b.addExecutable(.{
        .name = "wing_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wing", .module = wing_mod },
                .{ .name = "talon", .module = talon_mod },
                .{ .name = "zio", .module = zio_mod },
                .{ .name = "mantle", .module = mantle_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

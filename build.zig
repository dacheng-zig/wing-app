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

    // UUIDv7: entity ids (db/id.zig) and, via wing-trace, Crockford Base32
    // request ids.
    const uuid_mod = b.dependency("uuid", .{
        .target = target,
        .optimize = optimize,
    }).module("uuid");

    // wing-trace (lib/wing-trace): task-scoped trace ids + trace-aware logging.
    // Kept a plain module (not a package) so zio stays the single instance
    // deduped through talon; promote to a path dependency when it moves to its
    // own repository.
    const wing_trace_mod = b.createModule(.{
        .root_source_file = b.path("lib/wing-trace/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zio", .module = zio_mod },
            .{ .name = "uuid", .module = uuid_mod },
        },
    });

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
                .{ .name = "wing_trace", .module = wing_trace_mod },
                .{ .name = "uuid", .module = uuid_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Offline OpenAPI spec dump (no DB, no server): `zig build openapi`.
    const openapi_gen = b.addExecutable(.{
        .name = "openapi_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/openapi_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wing", .module = wing_mod },
                .{ .name = "talon", .module = talon_mod },
                .{ .name = "zio", .module = zio_mod },
                .{ .name = "mantle", .module = mantle_mod },
                .{ .name = "wing_trace", .module = wing_trace_mod },
                .{ .name = "uuid", .module = uuid_mod },
            },
        }),
    });
    const openapi_run = b.addRunArtifact(openapi_gen);
    const openapi_step = b.step("openapi", "Print the assembled OpenAPI 3.1 spec to stdout");
    openapi_step.dependOn(&openapi_run.step);

    // Unit tests: the dependency-free auth units plus the openapi package
    // (see src/tests.zig). The openapi units reflect over wing's public
    // extractor types, so the test module imports `wing`.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wing", .module = wing_mod },
                .{ .name = "uuid", .module = uuid_mod },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // wing-trace's tests need their own compile: test collection stops at
    // module boundaries, so importing the module from tests.zig would not
    // pick them up.
    const trace_tests = b.addTest(.{ .root_module = wing_trace_mod });
    test_step.dependOn(&b.addRunArtifact(trace_tests).step);
}

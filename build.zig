const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const http3_mod = b.createModule(.{
        .root_source_file = b.path("src/http3/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const qpack_mod = b.createModule(.{
        .root_source_file = b.path("src/qpack/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/server/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addStaticLibrary(.{
        .name = "zhttp3",
        .root_module = http3_mod,
    });

    b.installArtifact(lib);

    _ = qpack_mod;
    _ = server_mod;

    const unit_tests = b.addTest(.{
        .root_module = http3_mod,
    });

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

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

    const lib = b.addLibrary(.{
        .name = "zhttp3",
        .root_module = http3_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    _ = server_mod;

    const test_step = b.step("test", "Run unit tests");

    const http3_tests = b.addTest(.{ .root_module = http3_mod });
    test_step.dependOn(&b.addRunArtifact(http3_tests).step);

    const qpack_tests = b.addTest(.{ .root_module = qpack_mod });
    test_step.dependOn(&b.addRunArtifact(qpack_tests).step);
}

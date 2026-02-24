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

    // Individual test modules — each pulls in its transitive imports.
    const varint_mod = b.createModule(.{
        .root_source_file = b.path("src/http3/varint.zig"),
        .target = target,
        .optimize = optimize,
    });
    const frame_mod = b.createModule(.{
        .root_source_file = b.path("src/http3/frame.zig"),
        .target = target,
        .optimize = optimize,
    });
    const settings_mod = b.createModule(.{
        .root_source_file = b.path("src/http3/settings.zig"),
        .target = target,
        .optimize = optimize,
    });
    const stream_h3_mod = b.createModule(.{
        .root_source_file = b.path("src/http3/stream.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");

    const http3_tests = b.addTest(.{ .root_module = http3_mod });
    test_step.dependOn(&b.addRunArtifact(http3_tests).step);

    const varint_tests = b.addTest(.{ .root_module = varint_mod });
    test_step.dependOn(&b.addRunArtifact(varint_tests).step);

    const frame_tests = b.addTest(.{ .root_module = frame_mod });
    test_step.dependOn(&b.addRunArtifact(frame_tests).step);

    const settings_tests = b.addTest(.{ .root_module = settings_mod });
    test_step.dependOn(&b.addRunArtifact(settings_tests).step);

    const stream_h3_tests = b.addTest(.{ .root_module = stream_h3_mod });
    test_step.dependOn(&b.addRunArtifact(stream_h3_tests).step);

    const qpack_tests = b.addTest(.{ .root_module = qpack_mod });
    test_step.dependOn(&b.addRunArtifact(qpack_tests).step);
}

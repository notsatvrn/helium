const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) anyerror!void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // DEPENDENCIES

    const zg = b.dependency("zg", .{});
    const code_point_mod = zg.module("code_point");

    const static_map = b.dependency("static-map", .{});
    const static_map_mod = static_map.module("static-map");

    const zig_gc = b.dependency("zig-gc", .{});
    const zig_gc_mod = zig_gc.module("gc");

    // MODULE

    const mod = b.addModule("helium", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "code_point", .module = code_point_mod },
            .{ .name = "static-map", .module = static_map_mod },
            .{ .name = "gc", .module = zig_gc_mod },
        },
    });

    // RUNTIME

    const exe = b.addExecutable(.{
        .name = "helium",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .version = try std.SemanticVersion.parse("0.0.1"),
    });

    exe.root_module.addImport("helium", mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // TESTS

    //const tests = b.addTest(.{
    //    .name = "test",
    //    .root_source_file = b.path("src/tests.zig"),
    //    .target = target,
    //    .optimize = optimize,
    //});

    //tests.root_module.addImport("helium", mod);

    //const tests_step = b.step("test", "Run all tests");
    //tests_step.dependOn(&b.addRunArtifact(tests).step);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const httpz_dep = b.dependency("httpz", .{ .target = target, .optimize = optimize });
    const httpz_mod = httpz_dep.module("httpz");

    const qjs_sources = [_][]const u8{
        "deps/quickjs/quickjs.c",
        "deps/quickjs/libregexp.c",
        "deps/quickjs/libunicode.c",
        "deps/quickjs/dtoa.c",
        "src/views/quickjs_shim.c",
        "src/views/regex_shim.c",
    };
    const qjs_flags = [_][]const u8{ "-O2", "-D_GNU_SOURCE" };

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addCSourceFiles(.{ .files = &qjs_sources, .flags = &qjs_flags });
    exe_mod.addIncludePath(b.path("deps/quickjs"));
    exe_mod.linkSystemLibrary("m", .{});
    exe_mod.addImport("httpz", httpz_mod);
    const exe = b.addExecutable(.{
        .name = "zouch",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run zouch");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addCSourceFiles(.{ .files = &qjs_sources, .flags = &qjs_flags });
    test_mod.addIncludePath(b.path("deps/quickjs"));
    test_mod.linkSystemLibrary("m", .{});
    test_mod.addImport("httpz", httpz_mod);
    // `zig build test -Dtest-filter=rev` compiles only the tests whose name
    // contains "rev". The filter is a compile-time option of the test step in
    // Zig 0.17: the test runner has no `--test-filter` flag, so forwarding it
    // to the binary panics with "unrecognized command line argument".
    const test_filters: []const []const u8 = if (b.option([]const u8, "test-filter", "Only run tests whose name contains this substring")) |filter|
        &.{filter}
    else
        &.{};
    const tests = b.addTest(.{ .root_module = test_mod, .filters = test_filters });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

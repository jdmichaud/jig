const std = @import("std");
const readline = @import("readline");

pub fn create_executable_and_run_step(b: *std.Build, target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode, exe_name: []const u8, source: []const u8,
    jig: *std.Build.Module, jam: *std.Build.Module, readline_dep: *std.Build.Dependency,
    libreadline_dep: *std.Build.Dependency, test_filter: []const []const u8) void {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "jig", .module = jig },
            .{ .name = "jam", .module = jam },
        },
    });

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = exe_mod,
    });
    exe.root_module.addImport("jam", jam);
    exe.root_module.addImport("readline", readline_dep.module("readline"));
    exe.root_module.addImport("history", readline_dep.module("history"));
    exe.step.dependOn(libreadline_dep.builder.getInstallStep());
    exe.linkLibrary(readline_dep.artifact("lib"));
    exe.root_module.linkSystemLibrary("curses", .{});

    b.installArtifact(exe);

    const step = b.step(exe_name, "Run the app");

    const cmd = b.addRunArtifact(exe);
    step.dependOn(&cmd.step);

    cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = exe_mod,
        .target = target,
        .optimize = optimize,
        .filters = test_filter,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    var buffer: [256]u8 = undefined;
    const name = std.fmt.bufPrint(&buffer, "test-{s}", .{ exe_name }) catch unreachable;
    const test_step = b.step(name, "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}

pub fn build(b: *std.Build) void {
    const test_filter = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("jig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const jam = b.dependency("jam", .{}).module("js");
    const readline_dep = b.dependency("readline", .{});
    const libreadline_dep = readline_dep.builder.dependency("libreadline", .{});

    create_executable_and_run_step(b, target, optimize, "json", "src/json.zig", mod, jam, readline_dep, libreadline_dep, test_filter);
    create_executable_and_run_step(b, target, optimize, "interpreter", "src/interpreter.zig", mod, jam, readline_dep, libreadline_dep, test_filter);

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .target = target,
        .optimize = optimize,
        .filters = test_filter,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}

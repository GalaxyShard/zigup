const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = b.option(bool, "llvm", "Use LLVM/LLD or self-hosted backend");

    const zigup_exe_native = addZigupExe(b, target, optimize, false);
    zigup_exe_native.main.use_llvm = use_llvm;
    zigup_exe_native.main.use_lld = use_llvm;
    zigup_exe_native.tests.use_llvm = use_llvm;
    zigup_exe_native.tests.use_lld = use_llvm;

    b.installArtifact(zigup_exe_native.main);

    const run_step = b.step("run", "Run the app");
    {
        const run_cmd = b.addRunArtifact(zigup_exe_native.main);
        run_cmd.step.dependOn(b.getInstallStep());
        run_step.dependOn(&run_cmd.step);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }

    const test_step = b.step("test", "Test the executable");
    const run_tests = b.addRunArtifact(zigup_exe_native.tests);
    test_step.dependOn(&run_tests.step);

    const ci_step = b.step("ci", "The build/test step to run on the CI");
    ci_step.dependOn(b.getInstallStep());
    ci_step.dependOn(test_step);
    try ci(b, ci_step);

    const zigup_dry = addZigupExe(b, target, optimize, true);
    const check_step = b.step("check", "Check for errors");
    check_step.dependOn(&zigup_dry.main.step);
}

const ZigupExe = struct {
    main: *std.Build.Step.Compile,
    tests: *std.Build.Step.Compile,
};
fn addZigupExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dry_run: bool,
) ZigupExe {

    const known_folders = b.dependency("known-folders", .{}).module("known-folders");

    const git2 = b.dependency("git2", .{
        .target = target,
        .optimize = optimize,
    });
    const header_module = git2.module("git2_header");

    const zigup = b.addExecutable(.{
        .name = "zigup",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zigup.root_module.addImport("known-folders", known_folders);
    zigup.root_module.addImport("git2", header_module);
    if (!dry_run) {
        zigup.linkLibrary(git2.artifact("git2"));
    }


    if (target.result.os.tag == .windows) {
        const win32exelink = b.addExecutable(.{
            .name = "win32exelink",
            .root_source_file = b.path("util/win32exelink.zig"),
            .target = target,
            .optimize = optimize,
        });
        const module = b.createModule(.{
            .root_source_file = win32exelink.getEmittedBin(),
        });
        zigup.root_module.addImport("win32exelink", module);
    }
    const tests = b.addTest(.{
        .name = "zigup-test",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    return .{
        .main = zigup,
        .tests = tests,
    };
}

fn ci(
    b: *std.Build,
    ci_step: *std.Build.Step,
) !void {
    const ci_targets = [_][]const u8{
        "x86_64-linux-musl",
        "aarch64-linux-musl",
        "riscv64-linux-musl",
        "powerpc64le-linux-musl",
        "powerpc-linux-musl",
        "arm-linux-musl",

        "x86_64-windows-gnu",
        "aarch64-windows-gnu",

        "aarch64-macos",
        "x86_64-macos",
    };

    const make_archive_step = b.step("archive", "Create CI archives");
    ci_step.dependOn(make_archive_step);

    const archive_helper = b.addExecutable(.{
        .name = "archive-helper",
        .root_source_file = b.path("util/archive.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .ReleaseFast,
    });

    for (ci_targets) |ci_target_str| {
        const target = b.resolveTargetQuery(try std.Target.Query.parse(
            .{ .arch_os_abi = ci_target_str },
        ));

        const zigup_exe = addZigupExe(b, target, .ReleaseSafe, false);
        const zigup_exe_install = b.addInstallArtifact(zigup_exe.main, .{
            .dest_dir = .{ .override = .{ .custom = ci_target_str } },
        });
        ci_step.dependOn(&zigup_exe_install.step);

        const run_tests = b.addRunArtifact(zigup_exe.tests);
        run_tests.skip_foreign_checks = true;
        ci_step.dependOn(&run_tests.step);


        const output_name = b.fmt("zigup-{s}.gz", .{ci_target_str});
        const archive = b.addRunArtifact(archive_helper);

        archive.addFileArg(zigup_exe.main.getEmittedBin());
        const output_archive = archive.addOutputFileArg(output_name);

        const output = try std.fs.path.join(b.allocator, &.{ ci_target_str, output_name });
        defer b.allocator.free(output);

        const install_archive = b.addInstallFile(output_archive, output);
        ci_step.dependOn(&install_archive.step);
    }
}
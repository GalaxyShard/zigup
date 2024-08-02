const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigup_exe_native = blk: {
        const exe = addZigupExe(b, target, optimize);
        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        break :blk exe;
    };

    const test_step = b.step("test", "test the executable");
    {
        const exe = b.addExecutable(.{
            .name = "test",
            .root_source_file = b.path("test.zig"),
            .target = target,
            .optimize = optimize,
        });
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.addArtifactArg(zigup_exe_native);
        run_cmd.addDirectoryArg(b.path("scratch/native"));
        test_step.dependOn(&run_cmd.step);
    }

    const ci_step = b.step("ci", "The build/test step to run on the CI");
    ci_step.dependOn(b.getInstallStep());
    ci_step.dependOn(test_step);
//     ci_step.dependOn(unzip_step);
//     ci_step.dependOn(zip_step);
//     try ci(b, ci_step, test_step, host_zip_exe);
}

fn addZigupExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
) *std.Build.Step.Compile {

    const known_folders = b.dependency("known-folders", .{}).module("known-folders");
    const exe = b.addExecutable(.{
        .name = "zigup",
        .root_source_file = b.path("zigup.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("known-folders", known_folders);

    if (target.result.os.tag == .windows) {
        const win32exelink = b.addExecutable(.{
            .name = "win32exelink",
            .root_source_file = b.path("win32exelink.zig"),
            .target = target,
            .optimize = optimize,
        });
        const module = b.createModule(.{
            .root_source_file = win32exelink.getEmittedBin(),
        });
        exe.root_module.addImport("win32exelink", module);
    }
    return exe;
}

// fn ci(
//     b: *std.Build,
//     ci_step: *std.Build.Step,
//     test_step: *std.Build.Step,
//     host_zip_exe: *std.Build.Step.Compile,
// ) !void {
//     const ci_targets = [_][]const u8{
//         "x86_64-linux",
//         "x86_64-macos",
//         "x86_64-windows",
//         "aarch64-linux",
//         "aarch64-macos",
//         "arm-linux",
//         "riscv64-linux",
//         "powerpc-linux",
//         "powerpc64le-linux",
//     };
//
//     const make_archive_step = b.step("archive", "Create CI archives");
//     ci_step.dependOn(make_archive_step);
//
//     var previous_test_step = test_step;
//
//     for (ci_targets) |ci_target_str| {
//         const target = b.resolveTargetQuery(try std.Target.Query.parse(
//             .{ .arch_os_abi = ci_target_str },
//         ));
//         const optimize: std.builtin.OptimizeMode =
//             // Compile in ReleaseSafe on Windows for faster extraction
//             if (target.result.os.tag == .windows) .ReleaseSafe else .Debug;
//         const zigup_exe = addZigupExe(b, target, optimize);
//         const zigup_exe_install = b.addInstallArtifact(zigup_exe, .{
//             .dest_dir = .{ .override = .{ .custom = ci_target_str } },
//         });
//         ci_step.dependOn(&zigup_exe_install.step);
//
//         const test_exe = b.addExecutable(.{
//             .name = b.fmt("test-{s}", .{ci_target_str}),
//             .root_source_file = b.path("test.zig"),
//             .target = target,
//             .optimize = optimize,
//         });
//         const run_cmd = b.addRunArtifact(test_exe);
//         run_cmd.addArtifactArg(zigup_exe);
//         run_cmd.addDirectoryArg(b.path(b.fmt("scratch/{s}", .{ci_target_str})));
//
//         // This doesn't seem to be working, so I've added a pre-check below
//         run_cmd.failing_to_execute_foreign_is_an_error = false;
//         const os_compatible = (builtin.os.tag == target.result.os.tag);
//         const arch_compatible = (builtin.cpu.arch == target.result.cpu.arch);
//         if (os_compatible and arch_compatible) {
//             ci_step.dependOn(&run_cmd.step);
//
//             // prevent tests from running at the same time so their output
//             // doesn't mangle each other.
//             run_cmd.step.dependOn(previous_test_step);
//             previous_test_step = &run_cmd.step;
//         }
//
//         if (builtin.os.tag == .linux) {
//             make_archive_step.dependOn(makeCiArchiveStep(b, ci_target_str, target.result, zigup_exe_install, host_zip_exe));
//         }
//     }
// }
//
// fn makeCiArchiveStep(
//     b: *std.Build,
//     ci_target_str: []const u8,
//     target: std.Target,
//     exe_install: *std.Build.Step.InstallArtifact,
//     host_zip_exe: *std.Build.Step.Compile,
// ) *std.Build.Step {
//     const install_path = b.getInstallPath(.prefix, ".");
//
//     if (target.os.tag == .windows) {
//         const out_zip_file = b.pathJoin(&.{
//             install_path,
//             b.fmt("zigup-{s}.zip", .{ci_target_str}),
//         });
//         const zip = b.addRunArtifact(host_zip_exe);
//         zip.addArg(out_zip_file);
//         zip.addArg("zigup.exe");
//         zip.addArg("zigup.pdb");
//         zip.cwd = .{ .cwd_relative = b.getInstallPath(
//             exe_install.dest_dir.?,
//             ".",
//         ) };
//         zip.step.dependOn(&exe_install.step);
//         return &zip.step;
//     }
//
//     const targz = b.pathJoin(&.{
//         install_path,
//         b.fmt("zigup-{s}.tar.gz", .{ci_target_str}),
//     });
//     const tar = b.addSystemCommand(&.{
//         "tar",
//         "-czf",
//         targz,
//         "zigup",
//     });
//     tar.cwd = .{ .cwd_relative = b.getInstallPath(
//         exe_install.dest_dir.?,
//         ".",
//     ) };
//     tar.step.dependOn(&exe_install.step);
//     return &tar.step;
// }

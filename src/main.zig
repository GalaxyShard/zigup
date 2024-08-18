const std = @import("std");
const builtin = @import("builtin");

const known_folders = @import("known-folders");

// HACK: keep this for ZLS completion, otherwise use the other definition
// const git2 = @cImport({ @cInclude("git2.h"); });
const git2 = @import("git2");

const Allocator = std.mem.Allocator;
const cli = @import("cli.zig");
const Config = @import("config.zig");

const LazyVersion = @import("lazy-version.zig");
const download = @import("download.zig");
const version_index = @import("version-index.zig");
const zls_git = @import("zls-git.zig");

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};


fn getDefaultInstallDir(alloc: Allocator) ![]u8 {
    const data_dir = (try known_folders.getPath(alloc, .data)) orelse return error.NoDataDirectory;
    defer alloc.free(data_dir);
    const install_dir = try std.fs.path.join(alloc, &[_][]const u8{ data_dir, "zigup" });


    std.log.debug("default install directory: '{s}'", .{install_dir});
    return install_dir;
}

pub fn main() !void {
    // TODO: see if this can be removed (related: https://github.com/ziglang/zig/issues/8943)
    if (builtin.os.tag == .windows) {
        _ = try std.os.windows.WSAStartup(2, 2);
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const raw_args = try std.process.argsAlloc(alloc);
    var parsed_cli = try cli.parseCliArgs(alloc, raw_args);
    std.process.argsFree(alloc, raw_args);
    defer parsed_cli.deinit(alloc);

    const resolved_install_dir = parsed_cli.config.install_dir orelse try getDefaultInstallDir(alloc);
    const resolved_config: Config.Resolved = .{
        .install_dir = resolved_install_dir,

        .zig_symlink = parsed_cli.config.zig_symlink
            orelse try std.fs.path.join(alloc, &.{ resolved_install_dir, comptime "zig" ++ builtin.target.exeFileExt() }),

        .zls_symlink = parsed_cli.config.zls_symlink
            orelse try std.fs.path.join(alloc, &.{ resolved_install_dir, comptime "zls" ++ builtin.target.exeFileExt() }),
    };
    defer resolved_config.deinit(alloc);
    parsed_cli.config = .{}; // don't deinit twice

    switch (parsed_cli.action) {
        .download_default => |arg| {
            var version = try LazyVersion.init(alloc, arg.version);
            defer version.deinit();
            try fetchVersion(alloc, resolved_config, &version, .set_default);
        },
        .fetch => |arg| {
            var version = try LazyVersion.init(alloc, arg.version);
            defer version.deinit();
            try fetchVersion(alloc, resolved_config, &version, .leave_default);
        },
        .keep => |arg| {
            var version = try LazyVersion.init(alloc, arg.version);
            defer version.deinit();
            try keepVersion(resolved_config, &version);
        },
        .default => |arg| {
            if (arg.version) |version| {
                var lazy_version = try LazyVersion.init(alloc, version);
                defer lazy_version.deinit();

                try setDefaultVersion(alloc, resolved_config, &lazy_version);
            } else {
                try printDefaultVersion(alloc, resolved_config);
            }
        },
        .clean => |arg| {
            if (std.mem.eql(u8, arg.version, "outdated")) {
                try cleanOutdatedVersions(alloc, resolved_config);
            } else {
                var version = try LazyVersion.init(alloc, arg.version);
                defer version.deinit();

                try cleanVersion(resolved_config, &version);
            }
        },

        .run => |args| {
            var version = try LazyVersion.init(alloc, args.version);
            defer version.deinit();

            _ = try runCompiler(alloc, resolved_config, &version, null, args.zig_args);
        },

        .list => {
            try listVersions(alloc, resolved_config);
        },
        .fetch_index => {
            var cache_dir: std.fs.Dir = known_folders.open(alloc, .cache, .{})
                catch { return error.NoCacheDirectory; }
                orelse return error.NoCacheDirectory;
            defer cache_dir.close();

            var download_index = try version_index.fetchAndCache(alloc, cache_dir, .zig);
            defer download_index.deinit(alloc);

            try std.io.getStdOut().writeAll(download_index.text);
        },
        .fetch_mach_index => {
            var cache_dir: std.fs.Dir = known_folders.open(alloc, .cache, .{})
                catch { return error.NoCacheDirectory; }
                orelse return error.NoCacheDirectory;
            defer cache_dir.close();

            var download_index = try version_index.fetchAndCache(alloc, cache_dir, .mach);
            defer download_index.deinit(alloc);

            try std.io.getStdOut().writeAll(download_index.text);
        },
        .set_install_dir => |arg| {
            try Config.setDefault(alloc, .install_dir, arg.path);
        },
        .set_zig_symlink => |arg| {
            try Config.setDefault(alloc, .zig_symlink, arg.path);
        },
        .set_zls_symlink => |arg| {
            try Config.setDefault(alloc, .zls_symlink, arg.path);
        },
    }
}


pub fn runCompiler(alloc: Allocator, config: Config.Resolved, version: *LazyVersion, override_cwd: ?[]const u8, args: []const []const u8) !u8 {
    const id = try version.resolveId(config);
    const compiler_path = try std.fs.path.join(alloc, &[_][]const u8{ config.install_dir, id });
    defer alloc.free(compiler_path);

    std.fs.cwd().access(compiler_path, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.log.err("compiler '{s}' does not exist, fetch it first with: zigup fetch {0s}", .{ id });
            std.process.exit(1);
        },
        else => {},
    };

    var argv = std.ArrayList([]const u8).init(alloc);
    defer argv.deinit();

    try argv.append(try std.fs.path.join(alloc, &.{ compiler_path, "files", comptime "zig" ++ builtin.target.exeFileExt() }));
    try argv.appendSlice(args);

    // TODO: consider using "execve" on linux, except when compiling zls
    var proc = std.process.Child.init(argv.items, alloc);
    proc.cwd = override_cwd;
    const ret_val = try proc.spawnAndWait();
    switch (ret_val) {
        .Exited => |code| return code,
        else => |result| {
            std.log.err("compiler exited with {}", .{result});
            return error.FailedCompile;
        },
    }
}

const SetDefault = enum { set_default, leave_default };

fn handleIdErrorAndExit(version: *const LazyVersion, e: LazyVersion.ResolveError) noreturn {
    switch (e) {
        error.InvalidVersion => {
            std.log.err("Invalid version {s}", .{version.raw});
        },
        error.NoInstalledVersions => {
            std.log.err("No installed versions", .{});
        },
        else => {
            std.log.err("Unable to resolve version id: {s}", .{@errorName(e)});
        },
    }
    std.process.exit(1);
}
fn fetchVersion(alloc: Allocator, config: Config.Resolved, version: *LazyVersion, set_default: SetDefault) !void {
    // TODO: detect interuptions
    const version_id = version.resolveId(config) catch |e| handleIdErrorAndExit(version, e);
    const url = try version.resolveUrl(config);

    const compiler_dir = try std.fs.path.join(alloc, &[_][]const u8{ config.install_dir, version_id });
    defer alloc.free(compiler_dir);
    try installCompiler(alloc, compiler_dir, url);

    installZls(alloc, config, version, compiler_dir) catch |e| {
        std.log.err("Failed to install Zls: {s}", .{@errorName(e)});
    };

    if (set_default == .set_default) {
        try setDefaultVersion(alloc, config, version);
    }
}

fn listVersions(alloc: Allocator, config: Config.Resolved) !void {
    var install_dir = std.fs.cwd().openDir(config.install_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer install_dir.close();


    const FoundVersion = struct {
        string: []u8,
        is_kept: bool,
        pub fn deinit(self: @This(), alloc0: Allocator) void {
            alloc0.free(self.string);
        }
        pub fn ascending(_: void, lhs: @This(), rhs: @This()) bool {
            return std.mem.lessThan(u8, lhs.string, rhs.string);
        }
    };
    var versions = std.ArrayList(FoundVersion).init(alloc);
    defer {
        for (versions.items) |v| v.deinit(alloc);
        versions.deinit();
    }

    var it = install_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory)
            continue;
        if (!std.mem.startsWith(u8, entry.name, "zig-"))
            continue;
        if (std.mem.endsWith(u8, entry.name, ".installing"))
            continue;

        var version_dir = try install_dir.openDir(entry.name, .{});
        defer version_dir.close();

        version_dir.access(".keep", .{}) catch |e| switch (e) {
            error.FileNotFound => {
                try versions.append(.{
                    .string = try alloc.dupe(u8, entry.name),
                    .is_kept = false,
                });
//                 try stdout.print("{s}\n", .{entry.name});
                continue;
            },
            else => |e2| return e2,
        };
        try versions.append(.{
            .string = try alloc.dupe(u8, entry.name),
            .is_kept = true,
        });
//         try stdout.print("{s} (kept)\n", .{entry.name});
    }
    std.mem.sort(FoundVersion, versions.items, {}, FoundVersion.ascending);

    const stdout = std.io.getStdOut().writer();
    for (versions.items) |version| {
        if (version.is_kept) {
            try stdout.print("{s} (kept)\n", .{ version.string });
        } else {
            try stdout.print("{s}\n", .{ version.string });
        }
    }
}

fn keepVersion(config: Config.Resolved, version: *LazyVersion) !void {
    const version_id = version.resolveId(config) catch |e| handleIdErrorAndExit(version, e);
    var install_dir = try std.fs.cwd().openDir(config.install_dir, .{ .iterate = true });
    defer install_dir.close();

    var compiler_dir = install_dir.openDir(version_id, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.log.info("compiler {s} not installed", .{version_id});
            std.process.exit(1);
        },
        else => return e,
     };
    defer compiler_dir.close();

    var keep_fd = compiler_dir.createFile(".keep", .{}) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        else => |e2| return e2,
    };
    keep_fd.close();
    std.log.info("created '{s}{c}{s}{c}{s}'", .{ config.install_dir, std.fs.path.sep, version_id, std.fs.path.sep, ".keep" });
}
fn cleanVersion(config: Config.Resolved, version: *LazyVersion) !void {
    // TODO: if deleting symlinked, make sure to clean up the symlink
    const version_id = version.resolveId(config) catch |e| handleIdErrorAndExit(version, e);

    var install_dir = std.fs.cwd().openDir(config.install_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer install_dir.close();

    std.log.info("deleting '{s}{c}{s}'", .{ config.install_dir, std.fs.path.sep, version_id });
    try install_dir.deleteTree(version_id);
}
fn cleanOutdatedVersions(alloc: Allocator, config: Config.Resolved) !void {
    // TODO: if deleting symlinked, make sure to clean up the symlink
    const latest = LazyVersion.latestInstalledVersion(alloc, config.install_dir, .no_filter)
        catch |e| switch (e) {
            error.NoInstalledVersions => null,
            else => return e,
        };
    defer if (latest) |l| alloc.free(l);

    const latest_stable = LazyVersion.latestInstalledVersion(alloc, config.install_dir, .stable)
        catch |e| switch (e) {
            error.NoInstalledVersions => null,
            else => return e,
        };
    defer if (latest_stable) |l| alloc.free(l);

    var install_dir = std.fs.cwd().openDir(config.install_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer install_dir.close();

    var iter = install_dir.iterate();

    while (try iter.next()) |entry| {
        if (entry.kind != .directory
            or !std.mem.startsWith(u8, entry.name, "zig-")
            or (latest != null and std.mem.eql(u8, entry.name, latest.?))
            or (latest_stable != null and std.mem.eql(u8, entry.name, latest_stable.?))
        ) {
            continue;
        }

        const keep_file = try std.fs.path.join(alloc, &.{ entry.name, ".keep" });
        defer alloc.free(keep_file);

        if (install_dir.access(keep_file, .{})) {
            continue;
        } else |_| {}

        std.log.info("deleting '{s}{c}{s}'", .{ config.install_dir, std.fs.path.sep, entry.name });
        try install_dir.deleteTree(entry.name);
    }

}

fn installPathToVersion(target_path: []const u8) []const u8 {
    // file tree:
    //      $install-dir/zig-<version>/files/zig
    return std.fs.path.basename(std.fs.path.dirname(std.fs.path.dirname(target_path) orelse return "") orelse return "");
}

fn getDefaultVersion(alloc: Allocator, config: Config.Resolved) !?[]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = .{ undefined } ** std.fs.max_path_bytes;

    if (builtin.os.tag == .windows) {
        var file = std.fs.openFileAbsolute(config.zig_symlink, .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer file.close();

        // file path is embedded in executable
        try file.seekTo(win32exelink.exe_offset);
        const len = try file.readAll(buffer);
        if (len != buffer.len) {
            std.log.err("path link file '{s}' is possibly corrupted", .{ config.zig_symlink });
            std.process.exit(1);
        }
        // slice until null terminator
        const target_exe = std.mem.sliceTo(buffer, 0);
        return try alloc.dupe(u8, installPathToVersion(target_exe));
    } else {
        const default_zig_path = std.fs.readLinkAbsolute(config.zig_symlink, &buffer) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer alloc.free(default_zig_path);
        // Linux (and possibly other systems) truncates the output to the size of the buffer if it overflows
        // https://github.com/ziglang/zig/issues/19137
        if (default_zig_path.len == buffer.len) {
            std.log.err("path to default zig is too long", .{});
            std.process.exit(1);
        }
        return try alloc.dupe(u8, installPathToVersion(default_zig_path));
    }
}

fn printDefaultVersion(alloc: Allocator, config: Config.Resolved) !void {
    const default_compiler_opt = try getDefaultVersion(alloc, config);
    defer if (default_compiler_opt) |default_compiler| alloc.free(default_compiler);

    const stdout = std.io.getStdOut().writer();
    if (default_compiler_opt) |default_compiler| {
        try stdout.print("{s}\n", .{default_compiler});
    } else {
        try stdout.writeAll("<no default version>\n");
    }
}

fn setDefaultVersion(alloc: Allocator, config: Config.Resolved, version: *LazyVersion) !void {
    const version_id = try version.resolveId(config);

    const source_zig = try std.fs.path.join(alloc, &.{
        config.install_dir, version_id, "files", comptime "zig" ++ builtin.target.exeFileExt()
    });
    defer alloc.free(source_zig);

    std.fs.cwd().access(source_zig, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("compiler '{s}' is not installed", .{ version_id });
            std.process.exit(1);
        },
        else => |e| return e,
    };

    const source_zls = try std.fs.path.join(alloc, &.{
        config.install_dir, version_id, comptime "zls" ++ builtin.target.exeFileExt()
    });
    defer alloc.free(source_zls);

    std.log.debug("making symlink of {s} in {s}", .{ source_zig, config.zig_symlink });
    std.log.debug("making symlink of {s} in {s}", .{ source_zls, config.zls_symlink });

    // TODO: why not use a regular symlink on windows?
    if (builtin.os.tag == .windows) {
        createExeLink(source_zig, config.zig_symlink) catch {
            std.log.err("Unable to symlink {s} to {s}", .{source_zig, config.zig_symlink});
        };
        createExeLink(source_zls, config.zls_symlink) catch {
            std.log.err("Unable to symlink {s} to {s}", .{source_zls, config.zls_symlink});
        };
    } else {
        std.fs.cwd().deleteFile(config.zig_symlink) catch |e| switch (e) {
            error.FileNotFound => {},
            else => |e1| return e1,
        };
        std.fs.cwd().symLink(source_zig, config.zig_symlink, .{}) catch {
            std.log.err("Unable to symlink {s} to {s}", .{source_zig, config.zig_symlink});
        };


        std.fs.cwd().deleteFile(config.zls_symlink) catch |e| switch (e) {
            error.FileNotFound => {},
            else => |e1| return e1,
        };
        std.fs.cwd().symLink(source_zls, config.zls_symlink, .{}) catch {
            std.log.err("Unable to symlink {s} to {s}", .{source_zls, config.zls_symlink});
        };
    }
}

const win32exelink = struct {
    const content = @embedFile("win32exelink");
    const exe_offset: usize = if (builtin.os.tag != .windows) 0 else blk: {
        @setEvalBranchQuota(content.len * 2);
        const marker = "!!!THIS MARKS THE zig_exe_string MEMORY!!#";
        const offset = std.mem.indexOf(u8, content, marker) orelse {
            @compileError("win32exelink is missing the marker: " ++ marker);
        };
        if (std.mem.indexOf(u8, content[offset + 1 ..], marker) != null) {
            @compileError("win32exelink contains multiple markers (not implemented)");
        }
        break :blk offset + marker.len;
    };
};
fn createExeLink(link_target: []const u8, path_link: []const u8) !void {
    const file = std.fs.cwd().createFile(path_link, .{}) catch |err| switch (err) {
        error.IsDir => {
            std.log.err(
                "unable to create the exe link, the path '{s}' is a directory",
                .{ path_link},
            );
            return error.OverwritesDirectory;
        },
        else => |e| return e,
    };
    defer file.close();
    try file.writer().writeAll(win32exelink.content[0..win32exelink.exe_offset]);
    try file.writer().writeAll(link_target);
    try file.writer().writeAll(win32exelink.content[win32exelink.exe_offset + link_target.len ..]);
}

fn installCompiler(alloc: Allocator, compiler_dir: []const u8, url: []const u8) !void {
    if (std.fs.cwd().access(compiler_dir, .{})) {
        std.log.info("compiler '{s}' already installed", .{compiler_dir});
        return;
    } else |e| {
        if (e != error.FileNotFound) {
            return e;
        }
    }

    const installing_dir = try std.mem.concat(alloc, u8, &.{ compiler_dir, ".installing" });
    defer alloc.free(installing_dir);
    try std.fs.cwd().deleteTree(installing_dir);
    try std.fs.cwd().makePath(installing_dir);

    const archive_basename = std.fs.path.basename(url);

    const archive = try std.fs.path.join(alloc, &.{ installing_dir, archive_basename });
    defer alloc.free(archive);
    std.log.info("downloading '{s}' to '{s}'", .{ url, archive });

    {
        const file = try std.fs.cwd().createFile(archive, .{});
        const possible_error = download.download(alloc, url, file.writer());
        // NOTE: close the file before handling errors
        //       as it will delete the parent directory of this file
        file.close();

        possible_error catch |e| {
            std.log.err("download '{s}' failed: {s}", .{ url, @errorName(e) });
            // clean up failed install
            try std.fs.cwd().deleteTree(installing_dir);
            std.process.exit(1);
        };
    }

    var archive_root_dir: []const u8 = undefined;

    if (std.mem.endsWith(u8, archive_basename, ".tar.xz")) {
        std.log.info("extracting {s} into {s}", .{ archive, installing_dir });
        archive_root_dir = archive_basename[0 .. archive_basename.len - ".tar.xz".len];

        var file = try std.fs.cwd().openFile(archive, .{});
        defer file.close();

        var dir = try std.fs.cwd().openDir(installing_dir, .{});
        defer dir.close();

        var tar = try std.compress.xz.decompress(alloc, file.reader());
        try std.tar.pipeToFileSystem(dir, tar.reader(), .{});

    } else if (std.mem.endsWith(u8, archive_basename, ".zip")) {
        std.log.info("extracting {s} into {s}", .{ archive, installing_dir });
        archive_root_dir = archive_basename[0 .. archive_basename.len - ".zip".len];

        var file = try std.fs.cwd().openFile(archive, .{});
        defer file.close();

        var dir = try std.fs.cwd().openDir(installing_dir, .{});
        defer dir.close();

        try std.zip.extract(dir, file.seekableStream(), .{});
    } else {
        std.log.err("unknown archive extension '{s}'", .{archive_basename});
        return error.UnknownArchiveExtension;
    }
    try std.fs.cwd().deleteFile(archive);

    const extracted_dir = try std.fs.path.join(alloc, &.{ installing_dir, archive_root_dir });
    defer alloc.free(extracted_dir);
    const normalized_dir = try std.fs.path.join(alloc, &.{ installing_dir, "files" });
    defer alloc.free(normalized_dir);
    try std.fs.cwd().rename(extracted_dir, normalized_dir);

    // finish installation by renaming the install dir
    try std.fs.cwd().rename(installing_dir, compiler_dir);
}

fn installZls(alloc: Allocator, config: Config.Resolved, version: *LazyVersion, compiler_path: []const u8) !void {
    const bin_path = try std.fs.path.join(alloc, &.{
        compiler_path, comptime "zls" ++ builtin.target.exeFileExt()
    });
    defer alloc.free(bin_path);

    const version_id = try version.resolveId(config);
    if (std.fs.cwd().access(bin_path, .{})) {
        std.log.info("zls '{s}' already installed", .{bin_path});

        const version_num = try std.SemanticVersion.parse(version_id["zig-".len ..]);
        if (version_num.pre == null) {
            return;
        }
        const try_rebuild = zls_git.promptBool("Attempt to rebuild Zls? (y/N): ", false);
        if (!try_rebuild) {
            return;
        }
    } else |e| {
        if (e != error.FileNotFound) {
            return e;
        }
        std.log.info("zls '{s}' not installed", .{bin_path});
    }

    const zls_repo_path = try std.fs.path.joinZ(alloc, &.{ config.install_dir, "zls-repo" });
    defer alloc.free(zls_repo_path);


    try zls_git.checkErr(git2.git_libgit2_init());

    if (std.fs.cwd().accessZ(zls_repo_path, .{})) {
        std.log.info("using already downloaded zls repository", .{});

        const check_updates = zls_git.promptBool("Fetch Zls commits and updates? (Y/n): ", true);
        if (check_updates) {
            zls_git.fetchCommits(alloc, zls_repo_path) catch |e| {
                switch (e) {
                    error.FailedOpen => {
                        std.log.err("Failed to open Zls repository. It may need to be deleted ({s})", .{ zls_repo_path });
                    },
                    error.MissingRemote => {
                        std.log.err("Failed to find remote Zls repository. It may need to be deleted ({s})", .{ zls_repo_path });
                    },
                    error.FailedFetch => {
                        std.log.err("Failed to fetch commits. Check your internet or delete the repo to refresh ({s})", .{ zls_repo_path });
                    },
                    error.Git2Failed => {
                        std.log.err("git2 failed", .{});
                    },
                }
                return error.FailedUpdate;
            };
        }
    } else |_| {
        zls_git.cloneRepo(alloc, zls_repo_path) catch {
            std.log.err("Failed to clone zls to {s}. Check your internet or delete the repo to refresh", .{ zls_repo_path });
            return error.FailedClone;
        };
    }
    const oid = try resolveZlsCommit(alloc, config, version, zls_repo_path);
    zls_git.checkout(alloc, zls_repo_path, oid) catch |e| {
        switch (e) {
            error.FailedOpen => {
                std.log.err("Failed to open Zls repository. It may need to be deleted ({s})", .{ zls_repo_path });
            },
            error.FailedCommitLookup => {
                const str = git2.git_oid_tostr_s(&oid);
                std.log.err("Invalid commit {s}", .{ std.mem.span(str) });
            },
            error.FailedCheckoutTree, error.FailedDetachHead => {
                std.log.err("Failed to fetch commits. Check your internet or delete the repo to refresh ({s})", .{ zls_repo_path });
            },
            error.Git2Failed => {
                std.log.err("git2 failed", .{});
            },
        }
        return error.FailedCheckout;
    };


    try zls_git.checkErr(git2.git_libgit2_shutdown());

    // TODO: make release mode configurable
    if (0 != try runCompiler(alloc, config, version, zls_repo_path, &.{"build", "--release=safe"})) {
        std.log.err("Failed to compile zls", .{});
        return error.FailedCompile;
    }

    var zls_repo = try std.fs.cwd().openDir(zls_repo_path, .{});
    defer zls_repo.close();

    var bin_dir = try std.fs.cwd().openDir(compiler_path, .{});
    defer bin_dir.close();

    bin_dir.deleteFile(comptime "zls" ++ builtin.target.exeFileExt()) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
    zls_repo.copyFile(
        comptime "zig-out/bin/zls" ++ builtin.target.exeFileExt(),
        bin_dir,
        comptime "zls" ++ builtin.target.exeFileExt(),
        .{}
    ) catch {
        std.log.err("failed to copy zls to {s}", .{compiler_path});
        return;
    };
}

fn resolveZlsCommit(alloc: Allocator, config: Config.Resolved, version: *LazyVersion, repo_dir: [:0]const u8) !git2.git_oid {
    const id = try version.resolveId(config);
    const version_num = id["zig-".len ..];

    const c_version_num = try alloc.dupeZ(u8, version_num);
    defer alloc.free(c_version_num);

    if (zls_git.findReference(alloc, repo_dir, c_version_num)) |oid| {
        const str = git2.git_oid_tostr_s(&oid);
        std.log.info("tagged release found: {s}, {s}", .{ version_num, std.mem.span(str) });
        return oid;
    } else |_| {
        std.log.info("tagged release not found", .{});
    }


    if (version.release == .master) {
        const use_master = zls_git.promptBool("Use the latest master release of Zls? (Y/n): ", true);
        if (use_master) {
            std.log.info("using zls origin/master", .{});
            if (zls_git.findReference(alloc, repo_dir, "origin/master")) |oid| {
                const str = git2.git_oid_tostr_s(&oid);

                std.log.info("master commit found: {s}", .{std.mem.span(str)});
                return oid;
            } else |_| {
                std.log.info("origin/master reference not found", .{});
            }
        }
    }
    // TODO: suggest using the nearest commit after the compiler release date
    var zls_version = std.ArrayList(u8).init(alloc);
    while (true) {
        zls_version.clearRetainingCapacity();

        try std.io.getStdOut().writeAll("Unable to find a Zls version to install\nEnter a version (SHA1 hash or master): ");

        const stdin = std.io.getStdIn();
        stdin.reader().streamUntilDelimiter(zls_version.writer(), '\n', 256) catch |e| {
            if (e == error.StreamTooLong) {
                try stdin.reader().skipUntilDelimiterOrEof('\n');
                continue;
            } else {
                return error.UnableToResolve;
            }
        };

        if (std.mem.eql(u8, zls_version.items, "master")) {
            if (zls_git.findReference(alloc, repo_dir, "origin/master")) |oid| {
                const str = git2.git_oid_tostr_s(&oid);

                std.log.info("master commit found: {s}", .{std.mem.span(str)});
                return oid;
            } else |_| {
                std.log.err("origin/master not found", .{});
            }
        }

        try zls_version.append(0);
        const c_string = zls_version.items[0..zls_version.items.len-1 :0];

        if (zls_git.findCommit(alloc, repo_dir, c_string)) |oid| {
            return oid;
        } else |_| {
            std.log.info("commit not found", .{});
        }
    }
//     const resolved_date = version.resolveDate(config) catch |e| switch (e) {
//         error.NoDate => null,
//         else => return e,
//     };
}

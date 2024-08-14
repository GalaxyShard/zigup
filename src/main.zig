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
    // TODO: what is this?
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
        .zig_symlink = parsed_cli.config.zig_symlink orelse try std.fs.path.join(alloc, &.{ resolved_install_dir, "zig" }),
        .zls_symlink = parsed_cli.config.zls_symlink orelse try std.fs.path.join(alloc, &.{ resolved_install_dir, "zls" }),
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

            _ = try runCompiler(alloc, resolved_config, &version, args.zig_args);
        },

        .list => {
            try listVersions(resolved_config);
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


pub fn runCompiler(alloc: Allocator, config: Config.Resolved, version: *LazyVersion, args: []const []const u8) !u8 {
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

    // TODO: use "execve" if on linux
    var proc = std.process.Child.init(argv.items, alloc);
    const ret_val = try proc.spawnAndWait();
    switch (ret_val) {
        .Exited => |code| return code,
        else => |result| {
            std.log.err("compiler exited with {}", .{result});
            return 0xff;
        },
    }
}

const SetDefault = enum { set_default, leave_default };

fn promptZlsVersion(alloc: Allocator) ![]u8 {
    try std.io.getStdOut().writeAll("Unable to find a Zls version to install\nEnter a version (master, commit hash or YYYY-MM-DD): ");

    const stdin = std.io.getStdIn();
    var version = std.ArrayList(u8).init(alloc);
    try stdin.reader().streamUntilDelimiter(version.writer(), '\n', 256);

    return version.toOwnedSlice();
}

fn fetchVersion(alloc: Allocator, config: Config.Resolved, version: *LazyVersion, set_default: SetDefault) !void {
    // TODO: detect interuptions
    const version_id = try version.resolveId(config);
    const url = try version.resolveUrl(config);

    const compiler_dir = try std.fs.path.join(alloc, &[_][]const u8{ config.install_dir, version_id });
    defer alloc.free(compiler_dir);
    try installCompiler(alloc, compiler_dir, url);

    try installZls(alloc, config, version, compiler_dir);

    if (set_default == .set_default) {
        try setDefaultVersion(alloc, config, version);
    }
}

fn listVersions(config: Config.Resolved) !void {
    var install_dir = std.fs.cwd().openDir(config.install_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer install_dir.close();

    const stdout = std.io.getStdOut().writer();
    var it = install_dir.iterate();

    while (try it.next()) |entry| {
        if (entry.kind != .directory)
            continue;
        if (!std.mem.startsWith(u8, entry.name, "zig-"))
            continue;
        if (std.mem.endsWith(u8, entry.name, ".installing"))
            continue;

        var version = try install_dir.openDir(entry.name, .{});
        defer version.close();

        version.access(".keep", .{}) catch |e| switch (e) {
            error.FileNotFound => {
                try stdout.print("{s}\n", .{entry.name});
                continue;
            },
            else => |e2| return e2,
        };
        try stdout.print("{s} (kept)\n", .{entry.name});

    }
}

fn keepVersion(config: Config.Resolved, version: *LazyVersion) !void {
    const version_id = try version.resolveId(config);
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
    const version_id = try version.resolveId(config);

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

//     const source_zls = try std.fs.path.join(alloc, &.{
//         config.install_dir, version_id, "zls" ++ builtin.target.exeFileExt()
//     });
//     defer alloc.free(source_zls);

    std.log.debug("making symlink of {s} in {s}", .{ source_zig, config.zig_symlink });
//     std.log.debug("making symlink of {s} in {s}", .{ source_zls, config.zls_symlink });

    // TODO: why can't windows use a regular symlink?
    if (builtin.os.tag == .windows) {
        try createExeLink(source_zig, config.zig_symlink);
//         try createExeLink(source_zls, config.zls_symlink);
    } else {
        std.fs.cwd().deleteFile(config.zig_symlink) catch |e| switch (e) {
            error.FileNotFound => {},
            else => |e1| return e1,
        };
        try std.fs.cwd().symLink(source_zig, config.zig_symlink, .{});
//         try std.fs.cwd().symLink(source_zls, config.zls_symlink, .{});
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
            std.process.exit(1);
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
    var archive_root_dir: []const u8 = undefined;

    // download and extract archive
    {
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
        try std.fs.cwd().deleteTree(archive);
    }

    const extracted_dir = try std.fs.path.join(alloc, &.{ installing_dir, archive_root_dir });
    defer alloc.free(extracted_dir);
    const normalized_dir = try std.fs.path.join(alloc, &.{ installing_dir, "files" });
    defer alloc.free(normalized_dir);
    try std.fs.cwd().rename(extracted_dir, normalized_dir);

    // finish installation by renaming the install dir
    try std.fs.cwd().rename(installing_dir, compiler_dir);
}

fn installZls(alloc: Allocator, config: Config.Resolved, version: *LazyVersion, compiler_dir: []const u8) !void {
    const bin_path = try std.mem.concat(alloc, u8, &.{ compiler_dir, "zls" });
    defer alloc.free(bin_path);

    if (std.fs.cwd().access(bin_path, .{})) {
        std.log.info("zls '{s}' already installed", .{compiler_dir});
        return;
    } else |e| {
        if (e != error.FileNotFound) {
            return e;
        }
    }


    // TODO: find which Zls commit to checkout
    // Use release tags if possible, possibly ask user if the master branch should be used
    _ = version;
//     const resolved_date = version.resolveDate(config) catch |e| switch (e) {
//         error.NoDate => null,
//         else => return e,
//     };
//     const version_id = try version.resolveId(config);
//     const commit = blk: {
//         if (resolved_date) |r| {
//             break :blk try alloc.dupe(u8, r);
//         }
//     };
//     const commit = if (resolved_date) |r| try alloc.dupe(u8, r) else try promptZlsVersion(alloc);
//     defer alloc.free(commit);


    const zls_repo_path = try std.fs.path.joinZ(alloc, &.{ config.install_dir, "zls-repo" });
    defer alloc.free(zls_repo_path);

    try zls_git.checkErr(git2.git_libgit2_init());

    if (std.fs.cwd().accessZ(zls_repo_path, .{})) {
        std.log.info("using already downloaded zls repository", .{});

        const check_updates = zls_git.promptBool("Fetch Zls commits and updates? (Y/n): ", true);
        if (check_updates) {
            try zls_git.fetchZlsCommits(alloc, zls_repo_path);
        }
    } else |_| {
        try zls_git.cloneZlsRepo(alloc, zls_repo_path);
    }
//     try zls_git.checkoutZls(commit);

    try zls_git.checkErr(git2.git_libgit2_shutdown());

}

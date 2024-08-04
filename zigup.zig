const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

// TODO: see if removing this breaks anything
// const fixdeletetree = @import("fixdeletetree.zig");

const known_folders = @import("known-folders");

const arch = switch (builtin.cpu.arch) {
    .x86 => "i386",
    .x86_64 => "x86_64",
    .aarch64 => "aarch64",
    .arm => "armv7a",
    .riscv64 => "riscv64",
    .powerpc64le => "powerpc64le",
    .powerpc => "powerpc",
    else => @compileError("Unsupported CPU Architecture"),
};
const os = switch (builtin.os.tag) {
    .windows => "windows",
    .linux => "linux",
    .macos => "macos",
    .freebsd => "freebsd",
    else => @compileError("Unsupported OS"),
};
const json_platform = arch ++ "-" ++ os;

var global_enable_log = true;
fn loginfo(comptime fmt: []const u8, args: anytype) void {
    if (global_enable_log) {
        std.debug.print(fmt ++ "\n", args);
    }
}

const DownloadResult = union(enum) {
    ok: void,
    err: []u8,
    pub fn deinit(self: DownloadResult, allocator: Allocator) void {
        switch (self) {
            .ok => {},
            .err => |e| allocator.free(e),
        }
    }
};
fn download(allocator: Allocator, url: []const u8, writer: anytype) !DownloadResult {
    const uri = std.Uri.parse(url) catch |err| std.debug.panic(
        "failed to parse url '{s}' with {s}", .{url, @errorName(err)}
    );

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    client.initDefaultProxies(allocator) catch |err| return .{ .err = try std.fmt.allocPrint(
        allocator, "failed to query the HTTP proxy settings with {s}", .{ @errorName(err) }
    ) };

    var header_buffer: [4096]u8 = undefined;
    var request = client.open(.GET, uri, .{
        .server_header_buffer = &header_buffer,
        .keep_alive = false,
    }) catch |err| return .{ .err = try std.fmt.allocPrint(
        allocator, "failed to connect to the HTTP server with {s}", .{ @errorName(err) }
    ) };

    defer request.deinit();

    request.send() catch |err| return .{ .err = try std.fmt.allocPrint(
        allocator, "failed to send the HTTP request with {s}", .{ @errorName(err) }
    ) };
    request.wait() catch |err| return .{ .err = try std.fmt.allocPrint(
        allocator, "failed to read the HTTP response headers with {s}", .{ @errorName(err) }
    ) };

    if (request.response.status != .ok) return .{ .err = try std.fmt.allocPrint(
        allocator,
        "HTTP server replied with unsuccessful response '{d} {s}'",
        .{ @intFromEnum(request.response.status), request.response.status.phrase() orelse "" },
    ) };

    // TODO: we take advantage of request.response.content_length

    var buf: [4096]u8 = undefined;
    while (true) {
        const len = request.reader().read(&buf) catch |err| return .{ .err = try std.fmt.allocPrint(
            allocator, "failed to read the HTTP response body with {s}'", .{ @errorName(err) }
        ) };
        if (len == 0)
            return .ok;
        writer.writeAll(buf[0..len]) catch |err| return .{ .err = try std.fmt.allocPrint(
            allocator, "failed to write the HTTP response body with {s}'", .{ @errorName(err) }
        ) };
    }
}

const DownloadStringResult = union(enum) {
    ok: []u8,
    err: []u8,

};
fn downloadToString(allocator: Allocator, url: []const u8) !DownloadStringResult {
    var response_array_list = try std.ArrayList(u8).initCapacity(allocator, 20 * 1024); // 20 KB (modify if response is expected to be bigger)
    defer response_array_list.deinit();

    switch (try download(allocator, url, response_array_list.writer())) {
        .ok => return .{ .ok = try response_array_list.toOwnedSlice() },
        .err => |e| return .{ .err = e },
    }
}

fn getDefaultInstallDir(allocator: Allocator) ![]const u8 {
    const data_dir = (try known_folders.getPath(allocator, .data)) orelse return error.NoDataDirectory;
    defer allocator.free(data_dir);
    const install_dir = try std.fs.path.join(allocator, &[_][]const u8{ data_dir, "zigup" });


    loginfo("install directory '{s}'", .{install_dir});
    return install_dir;
}

fn print_help() !void {
    try std.io.getStdOut().writeAll(
        \\Download and manage Zig compilers and ZLS.
        \\
        \\Common Usage:
        \\
        \\  zigup VERSION                 Download and set this compiler version and zls as default
        \\                                May be set to any version number, stable, master, mach-[VERSION], mach-latest, or latest-installed
        \\
        \\  zigup fetch VERSION           Download VERSION compiler
        \\  zigup default [VERSION]       Get or set the default compiler
        \\  zigup list                    List installed compiler versions
        \\  zigup clean   [VERSION]       Delete the given compiler version if specified; otherwise, clean all compilers
        \\                                That aren't the default, master, or marked to keep.
        \\  zigup keep VERSION            Mark a compiler to be kept during clean
        \\  zigup run VERSION ARGS...     Run the given VERSION of the compiler with the given ARGS...

        \\  zigup set-install-dir DIR         Set the default installation directory
        \\  zigup set-zig-symlink FILE_PATH   Set the default symlink path (see --zig-symlink)
        \\  zigup set-zls-symlink FILE_PATH   Set the default symlink path (see --zls-symlink)
        \\
        \\  zigup fetch-index             Download and print the index.json
        \\  zigup fetch-mach-index        Download and print the index.json
        \\
        \\Common Options:
        \\  --install-dir DIR             Install zig compilers in DIR
        \\  --zig-symlink FILE_PATH       Path where the `zig` symlink will be placed, pointing to the default compiler
        \\                                This will typically be a file path within a PATH directory so that the user can just run `zig`
        \\  --zls-symlink FILE_PATH       Path where the `zls` symlink will be placed, pointing to the default language server
        \\                                This will typically be a file path within a PATH directory so that the user can just run `zig`
        \\
        \\  -h, --help                    Display this help text
    );
}

const CliAction = union(enum) {
    const RawVersion = struct { version: []const u8 };
    const OptionalVersion = struct { version: ?[]const u8 };
    const RawPath = struct { path: []const u8 };


    download_default: RawVersion,

    fetch: RawVersion,
    default: OptionalVersion,
    list: void,
    clean: OptionalVersion,

    keep: RawVersion,
    run: struct { version: []const u8, zig_args: []const []const u8 },

    set_install_dir: RawPath,
    set_zig_symlink: RawPath,
    set_zls_symlink: RawPath,

    fetch_index: void,
    fetch_mach_index: void,

    pub fn deinit(self: CliAction, alloc: Allocator) void {
        switch (self) {
            .download_default, .fetch, .keep => |a| alloc.free(a.version),
            .default, .clean => |a| if (a.version) |v| alloc.free(v),

            .run => |a| {
                alloc.free(a.version);
                for (a.zig_args) |arg| { alloc.free(arg); }
                alloc.free(a.zig_args);
            },
            .set_install_dir, .set_zig_symlink, .set_zls_symlink => |a| {
                alloc.free(a.path);
            },

            .list, .fetch_index, .fetch_mach_index => {},
        }
    }
};
const Cli = struct {
    config: ZigupConfig,
    action: CliAction,

    pub fn deinit(self: Cli, alloc: Allocator) void {
        self.config.deinit(alloc);
        self.action.deinit(alloc);
    }
};
const IndexDownloads = struct {
    mach: ?std.json.Parsed(std.json.Value),
    zig: ?std.json.Parsed(std.json.Value),

    pub fn getZig(self: *IndexDownloads, alloc: Allocator) !*std.json.Parsed(std.json.Value) {
        if (self.zig) |_| return &self.zig.?;

        const index = try fetchDownloadIndex(alloc, .zig);
        self.zig = index.json;
        return &self.zig.?;
    }
    pub fn getMach(self: *IndexDownloads, alloc: Allocator) !*std.json.Parsed(std.json.Value) {
        if (self.mach) |_| return &self.mach.?;

        const index = try fetchDownloadIndex(alloc, .mach);
        self.mach = index.json;
        return &self.mach.?;
    }
    pub fn deinit(self: IndexDownloads) void {
        if (self.mach) |m| m.deinit();
        if (self.zig) |z| z.deinit();
    }
};

pub fn main() !void {
    // TODO: what is this?
    if (builtin.os.tag == .windows) {
        _ = try std.os.windows.WSAStartup(2, 2);
    }

//     var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const raw_args = try std.process.argsAlloc(alloc);
    var cli = try parseCliArgs(alloc, raw_args);
    std.process.argsFree(alloc, raw_args);
    defer cli.deinit(alloc);

    const resolved_config: ResolvedZigupConfig = .{
        .install_dir = cli.config.install_dir orelse try getDefaultInstallDir(alloc),
        .zig_symlink = cli.config.zig_symlink,
        .zls_symlink = cli.config.zls_symlink,
    };
    defer resolved_config.deinit(alloc);
    cli.config = .{};

    var index_downloads: IndexDownloads = .{
        .mach = null,
        .zig = null,
    };
    defer index_downloads.deinit();

    switch (cli.action) {
        .download_default => |arg| {
            const version = try resolveVersion(alloc, &index_downloads, resolved_config, arg.version);
            defer version.deinit(alloc);
            try fetchCompiler(alloc, resolved_config, version, .set_default);
        },
        .fetch => |arg| {
            const version = try resolveVersion(alloc, &index_downloads, resolved_config, arg.version);
            defer version.deinit(alloc);
            try fetchCompiler(alloc, resolved_config, version, .leave_default);
        },
        .keep => |arg| {
            const version = try resolveVersion(alloc, &index_downloads, resolved_config, arg.version);
            defer version.deinit(alloc);
            try keepCompiler(resolved_config, version);
        },

        .default => |arg| {
            if (arg.version) |version| {
                const resolved_version = try resolveVersion(alloc, &index_downloads, resolved_config, version);
                defer resolved_version.deinit(alloc);

                const compiler_dir = try std.fs.path.join(alloc, &[_][]const u8{ resolved_config.install_dir, resolved_version.string });
                defer alloc.free(compiler_dir);
                try setDefaultCompiler(alloc, compiler_dir, .verify_existence);
            } else {
                try printDefaultCompiler(alloc);
            }
        },
        .clean => |arg| {
            if (arg.version) |version| {
                const resolved_version = try resolveVersion(alloc, &index_downloads, resolved_config, version);
                defer resolved_version.deinit(alloc);

                try cleanCompiler(alloc, resolved_config, resolved_version);
            } else {
                // TODO: either get rid of this and clean all compilers or warn earlier
                std.log.warn("no version to clean", .{});
            }
        },

        .run => |args| {
            const version = try resolveVersion(alloc, &index_downloads, resolved_config, args.version);
            defer version.deinit(alloc);

            _ = try runCompiler(alloc, resolved_config, version, args.zig_args);
        },

        .list => {
            try listCompilers(resolved_config);
        },
        .fetch_index => {
            var download_index = try fetchDownloadIndex(alloc, .zig);
            defer download_index.deinit(alloc);

            try std.io.getStdOut().writeAll(download_index.text);
        },
        .fetch_mach_index => {
            var download_index = try fetchDownloadIndex(alloc, .mach);
            defer download_index.deinit(alloc);

            try std.io.getStdOut().writeAll(download_index.text);
        },
        .set_install_dir => |arg| {
            try setDefaultConfig(alloc, .install_dir, arg.path);
        },
        .set_zig_symlink => |arg| {
            try setDefaultConfig(alloc, .zig_symlink, arg.path);
        },
        .set_zls_symlink => |arg| {
            try setDefaultConfig(alloc, .zls_symlink, arg.path);
        },
    }
}

fn parseCliArgs(alloc: Allocator, args: []const []const u8) !Cli {
    if (args.len < 2) {
        try print_help();
        std.process.exit(0);
    }
    var config: ZigupConfig = .{};
    errdefer config.deinit(alloc);

    var non_option_args: [2]?[]const u8 = .{ null, null };

    for (1 .. args.len) |i| {
        const arg = args[i];

        if (std.mem.eql(u8, "--install-dir", arg)) {
            if (args.len <= i+1) {
                std.log.err("option '{s}' requires an argument", .{arg});
                std.process.exit(1);
            } else {
                // allocate before freeing, so if allocating errors, everything is cleaned up
                const new = try alloc.dupe(u8, args[i+1]);
                if (config.install_dir) |a| alloc.free(a);
                config.install_dir = new;
            }

        } else if (std.mem.eql(u8, "--zig-symlink", arg)) {
            if (args.len <= i+1) {
                std.log.err("option '{s}' requires an argument", .{arg});
                std.process.exit(1);
            } else {
                const new = try alloc.dupe(u8, args[i+1]);
                if (config.zig_symlink) |a| alloc.free(a);
                config.zig_symlink = new;
            }

        } else if (std.mem.eql(u8, "--zls-symlink", arg)) {
            if (args.len <= i+1) {
                std.log.err("option '{s}' requires an argument", .{arg});
                std.process.exit(1);
            } else {
                const new = try alloc.dupe(u8, args[i+1]);
                if (config.zls_symlink) |a| alloc.free(a);
                config.zls_symlink = new;
            }

        } else if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
            try print_help();
            std.process.exit(0);

        } else if (std.mem.eql(u8, "run", arg)) {
            if (args.len <= i+1) {
                std.log.err("option '{s}' requires an argument", .{arg});
                std.process.exit(1);
            } else {
                const version = try alloc.dupe(u8, args[i+1]);
                const zig_args = try alloc.alloc([]u8, args.len - i - 2);
                for (args[i+2..], 0..) |zig_arg, j| {
                    zig_args[j] = try alloc.dupe(u8, zig_arg);
                }

                const action = .{ .run = .{
                    .version = version,
                    .zig_args = args[i+2..],
                } };
                // all arguments after run are passed to Zig
                return .{
                    .config = config,
                    .action = action,
                };
            }

        } else {
            for (0..non_option_args.len) |j| {
                if (non_option_args[j] == null) {
                    non_option_args[j] = arg;
                    break;
                }
            }
        }
    }



    const cmd = non_option_args[0] orelse {
        try print_help();
        std.process.exit(1);
    };
    var action: ?CliAction = null;
    if (std.mem.eql(u8, "fetch", cmd)) {
        const v = non_option_args[1] orelse {
            std.log.err("{s} requires an argument", .{cmd});
            return error.MissingArg;
        };
        action = .{ .fetch = .{
            .version = try alloc.dupe(u8, v)
        } };

    } else if (std.mem.eql(u8, "default", cmd)) {
        action = .{ .default = .{
            .version = if (non_option_args[1]) |v| try alloc.dupe(u8, v) else null
        } };

    } else if (std.mem.eql(u8, "list", cmd)) {
        action = .{ .list = {} };

    } else if (std.mem.eql(u8, "clean", cmd)) {
        action = .{ .clean = .{
            .version = if (non_option_args[1]) |v| try alloc.dupe(u8, v) else null
        } };

    } else if (std.mem.eql(u8, "keep", cmd)) {
        const version = non_option_args[1] orelse {
            std.log.err("{s} requires an argument", .{cmd});
            return error.MissingArg;
        };
        action = .{ .keep = .{ .version = try alloc.dupe(u8, version) } };

    } else if (std.mem.eql(u8, "fetch-index", cmd)) {
        action = .{ .fetch_index = {} };

    } else if (std.mem.eql(u8, "fetch-mach-index", cmd)) {
        action = .{ .fetch_mach_index = {} };

    } else if (std.mem.eql(u8, "set-zig-symlink", cmd)) {
        const v = non_option_args[1] orelse {
            std.log.err("{s} requires an argument", .{cmd});
            return error.MissingArg;
        };
        action = .{ .set_zig_symlink = .{
            .path = try alloc.dupe(u8, v)
        } };

    } else if (std.mem.eql(u8, "set-zls-symlink", cmd)) {
        const v = non_option_args[1] orelse {
            std.log.err("{s} requires an argument", .{cmd});
            return error.MissingArg;
        };
        action = .{ .set_zls_symlink = .{
            .path = try alloc.dupe(u8, v)
        } };

    } else if (std.mem.eql(u8, "set-install-dir", cmd)) {
        const v = non_option_args[1] orelse {
            std.log.err("{s} requires an argument", .{cmd});
            return error.MissingArg;
        };
        action = .{ .set_install_dir = .{
            .path = try alloc.dupe(u8, v)
        } };
    } else {
        const version = cmd;
        action = .{ .download_default = .{ .version = try alloc.dupe(u8, version) } };
    }
    return .{
        .config = config,
        .action = action.?,
    };
}



test "parseCliArgs: download & set default" {
    const cli = try parseCliArgs(std.testing.allocator, &.{
        "zigup", "0.13.0",
    });
    defer cli.deinit(std.testing.allocator);
    try std.testing.expect(cli.action == .download_default);
    try std.testing.expectEqualStrings(cli.action.download_default.version, "0.13.0");
}
test "parseCliArgs: fetch" {
    const cli = try parseCliArgs(std.testing.allocator, &.{
        "zigup", "fetch", "master", "--install-dir", "testing/path",
    });
    defer cli.deinit(std.testing.allocator);
    try std.testing.expect(cli.action == .fetch);
    try std.testing.expectEqualStrings(cli.action.fetch.version, "master");
    try std.testing.expectEqualStrings(cli.config.install_dir.?, "testing/path");
}
test "parseCliArgs: get default" {
    const cli = try parseCliArgs(std.testing.allocator, &.{
        "zigup", "default",
    });
    defer cli.deinit(std.testing.allocator);
    try std.testing.expect(cli.action == .default);
    try std.testing.expectEqual(cli.action.default.version, null);
}



const ConfigKey = enum { install_dir, zig_symlink, zls_symlink };
const ZigupConfig = struct {
    install_dir: ?[]const u8 = null,
    zig_symlink: ?[]const u8 = null,
    zls_symlink: ?[]const u8 = null,
    pub fn deinit(self: ZigupConfig, alloc: Allocator) void {
        if (self.install_dir) |dir| alloc.free(dir);
        if (self.zig_symlink) |symlink| alloc.free(symlink);
        if (self.zls_symlink) |symlink| alloc.free(symlink);
    }
};
const ResolvedZigupConfig = struct {
    install_dir: []const u8,
    zig_symlink: ?[]const u8 = null,
    zls_symlink: ?[]const u8 = null,
    pub fn deinit(self: ResolvedZigupConfig, alloc: Allocator) void {
        alloc.free(self.install_dir);
        if (self.zig_symlink) |symlink| alloc.free(symlink);
        if (self.zls_symlink) |symlink| alloc.free(symlink);
    }
};
fn parseConfigFile(alloc: Allocator, reader: anytype) !ZigupConfig {
    const contents = try reader.readAllAlloc(alloc, 4096*3);

    defer alloc.free(contents);
    var config: ZigupConfig = .{};

    var pairs = std.mem.splitScalar(u8, contents, '\n');
    while (pairs.next()) |pair| {
        var iter = std.mem.splitScalar(u8, pair, '=');

        const key = iter.first();
        const value = iter.next() orelse continue;

        if (std.mem.eql(u8, key, "install_dir")) {
            config.install_dir = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "zig_symlink")) {
            config.zig_symlink = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "zls_symlink")) {
            config.zls_symlink = try alloc.dupe(u8, value);
        } else {
            return error.ParseError;
        }
    }
    return config;
}
fn readConfig(alloc: Allocator) !ZigupConfig {
    var config_dir = (try known_folders.open(alloc, .local_configuration, .{})) orelse return error.NoConfigDirectory;
    defer config_dir.close();

    var config_file = try config_dir.openFile("zigup.conf", .{}) catch |e| switch (e) {
        error.FileNotFound => {},
        else => |err| return err,
    };
    defer config_file.close();

    return parseConfigFile(alloc, config_file.reader());
}
fn setDefaultConfig(alloc: Allocator, comptime key: ConfigKey, value: []const u8) !void {
    var config_dir = (try known_folders.open(alloc, .local_configuration, .{})) orelse return error.NoConfigDirectory;
    defer config_dir.close();

    var config_file = try config_dir.createFile("zigup.conf", .{ .read = true });
    defer config_file.close();

    var config = try parseConfigFile(alloc, config_file.reader());
    defer config.deinit(alloc);

    try config_file.seekTo(0);

    if (@field(config, @tagName(key))) |f| {
        alloc.free(f);
    }

    @field(config, @tagName(key)) = try alloc.dupe(u8, value);

    inline for (@typeInfo(@TypeOf(config)).Struct.fields) |field| {
        if (comptime std.mem.eql(u8, field.name, @tagName(key))) {

        }
        if (@field(config, field.name)) |f| {
            try config_file.writer().print(field.name ++ "={s}", .{ f });
        }
    }
}

const ResolvedVersion = struct {
    string: []const u8,
    url: ?[]const u8,

    pub fn deinit(self: ResolvedVersion, alloc: Allocator) void {
        alloc.free(self.string);
        if (self.url) |url| alloc.free(url);
    }
};
fn resolveVersion(alloc: Allocator, indexes: *IndexDownloads, config: ResolvedZigupConfig, raw_version: []const u8) !ResolvedVersion {
    if (std.mem.eql(u8, raw_version, "stable")) {
        var latest_found: ?std.SemanticVersion = null;
        var string = try std.ArrayList(u8).initCapacity(alloc, 8);
        var url = std.ArrayList(u8).init(alloc);

        var iter = (try indexes.getZig(alloc)).value.object.iterator();
        while (iter.next()) |pair| {
            if (std.SemanticVersion.parse(pair.key_ptr.*)) |version| {
                // ignore prereleases
                if (version.build != null or version.pre != null) {
                    continue;
                }
                if (latest_found == null or version.order(latest_found.?).compare(.gt)) {
                    latest_found = version;

                    string.clearRetainingCapacity();
                    try string.appendSlice(pair.key_ptr.*);

                    const compiler = pair.value_ptr.object.get(json_platform) orelse return error.UnsupportedSystem;
                    const tarball = compiler.object.get("tarball") orelse return error.InvalidIndexJson;

                    url.clearRetainingCapacity();
                    try url.appendSlice(tarball.string);

                }
            } else |_| {
                continue;
            }
        }

        return .{
            .string = try string.toOwnedSlice(),
            .url = try url.toOwnedSlice(),
        };

    } else if (std.mem.eql(u8, raw_version, "master")) {
        const master = (try indexes.getZig(alloc)).value.object.get("master") orelse return error.InvalidIndexJson;
        const version = master.object.get("version") orelse return error.InvalidIndexJson;

        const compiler = master.object.get(json_platform) orelse return error.UnsupportedSystem;
        const tarball = compiler.object.get("tarball") orelse return error.InvalidIndexJson;


        return .{
            .string = try alloc.dupe(u8, version.string),
            .url = try alloc.dupe(u8, tarball.string),
        };


    } else if (std.mem.eql(u8, raw_version, "latest-installed")) {

        const directory = try std.fs.cwd().openDir(config.install_dir, .{
            .iterate = true,
        });

        var latest_found: ?[]const u8 = null;

        var iter = directory.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;

            if (std.SemanticVersion.parse(entry.name)) |found_version| {
                if (latest_found) |latest| {
                    const latest_version = try std.SemanticVersion.parse(latest);

                    if (found_version.order(latest_version).compare(.gt)) {
                        alloc.free(latest);
                        latest_found = try alloc.dupe(u8, entry.name);
                    }
                } else {
                    latest_found = try alloc.dupe(u8, entry.name);
                }
            } else |_| {
                continue;
            }
        }
        return .{
            .string = latest_found orelse return error.NoInstalledVersions,
            .url = null,
        };

    } else if (std.mem.eql(u8, raw_version, "mach-latest")) {
        const mach_latest = (try indexes.getMach(alloc)).value.object.get("mach-latest") orelse return error.InvalidIndexJson;
        const version = mach_latest.object.get("version") orelse return error.InvalidIndexJson;

        const compiler = mach_latest.object.get(json_platform) orelse return error.UnsupportedSystem;
        const tarball = compiler.object.get("tarball") orelse return error.InvalidIndexJson;

        return .{
            .string = try alloc.dupe(u8, version.string),
            .url = try alloc.dupe(u8, tarball.string),
        };

    } else if (std.mem.endsWith(u8, raw_version, "-mach")) {
        const json = (try indexes.getMach(alloc)).value.object.get(raw_version) orelse return error.InvalidVersion;
        const compiler = json.object.get(json_platform) orelse return error.UnsupportedSystem;
        const tarball = compiler.object.get("tarball") orelse return error.InvalidIndexJson;
        return .{
            .string = try alloc.dupe(u8, raw_version),
            .url = try alloc.dupe(u8, tarball.string),
        };

    } else {

        const json = (try indexes.getZig(alloc)).value.object.get(raw_version) orelse return error.InvalidVersion;
        const compiler = json.object.get(json_platform) orelse return error.UnsupportedSystem;
        const tarball = compiler.object.get("tarball") orelse return error.InvalidIndexJson;
        return .{
            .string = try alloc.dupe(u8, raw_version),
            .url = try alloc.dupe(u8, tarball.string),
        };
    }
}

pub fn runCompiler(alloc: Allocator, config: ResolvedZigupConfig, version: ResolvedVersion, args: []const []const u8) !u8 {
    // disable log so we don't add extra output to whatever the compiler will output
    global_enable_log = false;

    const compiler_path = try std.fs.path.join(alloc, &[_][]const u8{ config.install_dir, version.string });
    defer alloc.free(compiler_path);


    std.fs.cwd().access(compiler_path, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.log.err("compiler '{s}' does not exist, fetch it first with: zigup fetch {0s}", .{ version.string });
            std.process.exit(1);
        },
        else => {},
    };

    var argv = std.ArrayList([]const u8).init(alloc);
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

fn fetchCompiler(alloc: Allocator, config: ResolvedZigupConfig, version: ResolvedVersion, set_default: SetDefault) !void {
    const compiler_dir = try std.fs.path.join(alloc, &[_][]const u8{ config.install_dir, version.string });
    defer alloc.free(compiler_dir);
    try installCompiler(alloc, compiler_dir, version.url orelse return error.NoVersionUrl);

    if (set_default == .set_default) {
        try setDefaultCompiler(alloc, compiler_dir, .existence_verified);
    }
}

const zig_index_url = "https://ziglang.org/download/index.json";
const mach_index_url = "https://machengine.org/zig/index.json";

const DownloadIndex = struct {
    text: []u8,
    json: std.json.Parsed(std.json.Value),
//     json: std.json.Parsed(IndexJson),
    pub fn deinit(self: DownloadIndex, allocator: Allocator) void {
        self.json.deinit();
        allocator.free(self.text);
    }
};

// const IndexJson = struct {
//     const TargetDownload = struct {
//         tarball: []const u8,
//         shasum: []const u8,
//         size: []const u8,
//     };
//     const Release = struct {
//         version: ?[]const u8,
//         date: []const u8,
//         docs: []const u8,
//         stdDocs: []const u8,
//         downloads: std.StringArrayHashMap(TargetDownload),
//
//         pub fn jsonParseFromValue(
//             alloc: Allocator,
//             source: std.json.Value,
//             options: std.json.ParseOptions
//         ) std.json.ParseFromValueError!Release {
// //             source.
//         }
//     };
//     releases: std.StringArrayHashMap(Release),
//
//     pub fn jsonParseFromValue(
//         alloc: Allocator,
//         source: std.json.Value,
//         options: std.json.ParseOptions
//     ) std.json.ParseFromValueError!IndexJson {
//         const self: IndexJson = .{
//             .releases = undefined,
//         };
//         self.releases = @TypeOf(self.releases).jsonParseFromValue(alloc, source, options);
//         return self;
//     }
// };

fn fetchDownloadIndex(alloc: Allocator, comptime url: enum { zig,mach }) !DownloadIndex {
    const url_string = switch (url) {
        .zig => zig_index_url,
        .mach => mach_index_url,
    };
    const text = switch (try downloadToString(alloc, url_string)) {
        .ok => |text| text,
        .err => |err| {
            std.log.err("download '{s}' failed: {s}", .{url_string, err});
            std.process.exit(1);
        },
    };
    errdefer alloc.free(text);

    var json = try std.json.parseFromSlice(std.json.Value, alloc, text, .{
//         .ignore_unknown_fields = true,
    });
    errdefer json.deinit();

    return DownloadIndex{ .text = text, .json = json };
}

fn listCompilers(config: ResolvedZigupConfig) !void {
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
        if (std.mem.endsWith(u8, entry.name, ".installing"))
            continue;
        try stdout.print("{s}\n", .{entry.name});
    }
}

fn keepCompiler(config: ResolvedZigupConfig, compiler_version: ResolvedVersion) !void {
    var install_dir = try std.fs.cwd().openDir(config.install_dir, .{ .iterate = true });
    defer install_dir.close();

    var compiler_dir = install_dir.openDir(compiler_version.string, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.log.err("compiler not found: {s}", .{compiler_version.string});
            std.process.exit(1);
        },
        else => return e,
    };
    var keep_fd = try compiler_dir.createFile("keep", .{});
    keep_fd.close();
    loginfo("created '{s}{c}{s}{c}{s}'", .{ config.install_dir, std.fs.path.sep, compiler_version.string, std.fs.path.sep, "keep" });
}

fn cleanCompiler(alloc: Allocator, config: ResolvedZigupConfig, version: ResolvedVersion) !void {
    _ = alloc;
    // TODO: if deleting symlinked, make sure to clean up the symlink

    var install_dir = std.fs.cwd().openDir(config.install_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer install_dir.close();

    loginfo("deleting '{s}{c}{s}'", .{ config.install_dir, std.fs.path.sep, version.string });
    try install_dir.deleteTree(version.string);
}
fn readDefaultCompiler(alloc: Allocator, buffer: *[std.fs.max_path_bytes + 1]u8) !?[]const u8 {
    _ = alloc;
    _ = buffer;
    @panic("Default compiler not implemented");
//     const path_link = try makeZigPathLinkString(allocator);
//     defer allocator.free(path_link);
//
//     if (builtin.os.tag == .windows) {
//         var file = std.fs.openFileAbsolute(path_link, .{}) catch |e| switch (e) {
//             error.FileNotFound => return null,
//             else => return e,
//         };
//         defer file.close();
//         try file.seekTo(win32exelink.exe_offset);
//         const len = try file.readAll(buffer);
//         if (len != buffer.len) {
//             std.log.err("path link file '{s}' is too small", .{path_link});
//             std.process.exit(1);
//         }
//         const target_exe = std.mem.sliceTo(buffer, 0);
//         return try allocator.dupe(u8, targetPathToVersion(target_exe));
//     }
//
//     const target_path = std.fs.readLinkAbsolute(path_link, buffer[0..std.fs.max_path_bytes]) catch |e| switch (e) {
//         error.FileNotFound => return null,
//         else => return e,
//     };
//     defer allocator.free(target_path);
//     return try allocator.dupe(u8, targetPathToVersion(target_path));
}
// fn targetPathToVersion(target_path: []const u8) []const u8 {
//     return std.fs.path.basename(std.fs.path.dirname(std.fs.path.dirname(target_path).?).?);
// }

fn getDefaultCompiler(allocator: Allocator) !?[]const u8 {
    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const slice_path = (try readDefaultCompiler(allocator, &buffer)) orelse return null;
    const path_to_return = try allocator.alloc(u8, slice_path.len);
    @memcpy(path_to_return, slice_path);
    return path_to_return;
}

fn printDefaultCompiler(allocator: Allocator) !void {
    const default_compiler_opt = try getDefaultCompiler(allocator);
    defer if (default_compiler_opt) |default_compiler| allocator.free(default_compiler);
    const stdout = std.io.getStdOut().writer();
    if (default_compiler_opt) |default_compiler| {
        try stdout.print("{s}\n", .{default_compiler});
    } else {
        try stdout.writeAll("<no-default>\n");
    }
}

const ExistVerify = enum { existence_verified, verify_existence };

fn setDefaultCompiler(allocator: Allocator, compiler_dir: []const u8, exist_verify: ExistVerify) !void {
    _ = allocator;
    _ = compiler_dir;
    _ = exist_verify;
    @panic("Default compiler not implemented");
//     switch (exist_verify) {
//         .existence_verified => {},
//         .verify_existence => {
//             var dir = std.fs.cwd().openDir(compiler_dir, .{}) catch |err| switch (err) {
//                 error.FileNotFound => {
//                     std.log.err("compiler '{s}' is not installed", .{std.fs.path.basename(compiler_dir)});
//                     std.process.exit(1);
//                 },
//                 else => |e| return e,
//             };
//             dir.close();
//         },
//     }
//
//     const path_link = try makeZigPathLinkString(allocator);
//     defer allocator.free(path_link);
//
//     const link_target = try std.fs.path.join(allocator, &[_][]const u8{ compiler_dir, "files", comptime "zig" ++ builtin.target.exeFileExt() });
//     defer allocator.free(link_target);
//     if (builtin.os.tag == .windows) {
//         try createExeLink(link_target, path_link);
//     } else {
//         _ = try loggyUpdateSymlink(link_target, path_link, .{});
//     }
//
//     try verifyPathLink(allocator, path_link);
}

/// Verify that path_link will work.  It verifies that `path_link` is
/// in PATH and there is no zig executable in an earlier directory in PATH.
fn verifyPathLink(allocator: Allocator, path_link: []const u8) !void {
    const path_link_dir = std.fs.path.dirname(path_link) orelse {
        std.log.err("invalid '--path-link' '{s}', it must be a file (not the root directory)", .{path_link});
        std.process.exit(1);
    };

    const path_link_dir_id = blk: {
        var dir = std.fs.cwd().openDir(path_link_dir, .{}) catch |err| {
            std.log.err("unable to open the path-link directory '{s}': {s}", .{ path_link_dir, @errorName(err) });
            std.process.exit(1);
        };
        defer dir.close();
        break :blk try FileId.initFromDir(dir, path_link);
    };

    if (builtin.os.tag == .windows) {
        const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return,
            else => |e| return e,
        };
        defer allocator.free(path_env);

        var free_pathext: ?[]const u8 = null;
        defer if (free_pathext) |p| allocator.free(p);

        const pathext_env = blk: {
            if (std.process.getEnvVarOwned(allocator, "PATHEXT")) |env| {
                free_pathext = env;
                break :blk env;
            } else |err| switch (err) {
                error.EnvironmentVariableNotFound => break :blk "",
                else => |e| return e,
            }
            break :blk "";
        };

        var path_it = std.mem.tokenizeScalar(u8, path_env, ';');
        while (path_it.next()) |path| {
            switch (try compareDir(path_link_dir_id, path)) {
                .missing => continue,
                // can't be the same directory because we were able to open and get
                // the file id for path_link_dir_id
                .access_denied => {},
                .match => return,
                .mismatch => {},
            }
            {
                const exe = try std.fs.path.join(allocator, &.{ path, "zig" });
                defer allocator.free(exe);
                try enforceNoZig(path_link, exe);
            }

            var ext_it = std.mem.tokenizeScalar(u8, pathext_env, ';');
            while (ext_it.next()) |ext| {
                if (ext.len == 0) continue;
                const basename = try std.mem.concat(allocator, u8, &.{ "zig", ext });
                defer allocator.free(basename);

                const exe = try std.fs.path.join(allocator, &.{ path, basename });
                defer allocator.free(exe);

                try enforceNoZig(path_link, exe);
            }
        }
    } else {
        var path_it = std.mem.tokenizeScalar(u8, std.posix.getenv("PATH") orelse "", ':');
        while (path_it.next()) |path| {
            switch (try compareDir(path_link_dir_id, path)) {
                .missing => continue,
                // can't be the same directory because we were able to open and get
                // the file id for path_link_dir_id
                .access_denied => {},
                .match => return,
                .mismatch => {},
            }
            const exe = try std.fs.path.join(allocator, &.{ path, "zig" });
            defer allocator.free(exe);
            try enforceNoZig(path_link, exe);
        }
    }

    std.log.err("the path link '{s}' is not in PATH", .{path_link});
    std.process.exit(1);
}

fn compareDir(dir_id: FileId, other_dir: []const u8) !enum { missing, access_denied, match, mismatch } {
    var dir = std.fs.cwd().openDir(other_dir, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.BadPathName => return .missing,
        error.AccessDenied => return .access_denied,
        else => |e| return e,
    };
    defer dir.close();
    return if (dir_id.eql(try FileId.initFromDir(dir, other_dir))) .match else .mismatch;
}

fn enforceNoZig(path_link: []const u8, exe: []const u8) !void {
    var file = std.fs.cwd().openFile(exe, .{}) catch |err| switch (err) {
        error.FileNotFound, error.IsDir => return,
        error.AccessDenied => return, // if there is a Zig it must not be accessible
        else => |e| return e,
    };
    defer file.close();

    // error only if it is an executable or if that can't be determined
    const meta = file.metadata() catch {
        std.log.err("zig compiler '{s}' is higher priority in PATH than the path-link '{s}'", .{ exe, path_link });
    };
    if (@TypeOf(meta.permissions().inner) == std.fs.File.PermissionsUnix) {
        if ((meta.permissions().inner.mode & 0o111) != 0) {
            std.log.err("zig compiler '{s}' is higher priority in PATH than the path-link '{s}'", .{ exe, path_link });
        }
    }
}

const FileId = struct {
    dev: if (builtin.os.tag == .windows) u32 else blk: {
        const st: std.posix.Stat = undefined;
        break :blk @TypeOf(st.dev);
    },
    ino: if (builtin.os.tag == .windows) u64 else blk: {
        const st: std.posix.Stat = undefined;
        break :blk @TypeOf(st.ino);
    },

    pub fn initFromFile(file: std.fs.File, filename_for_error: []const u8) !FileId {
        if (builtin.os.tag == .windows) {
            var info: std.os.windows.BY_HANDLE_FILE_INFORMATION = undefined;
            if (0 == std.os.windows.GetFileInformationByHandle(file.handle, &info)) {
                std.log.err("GetFileInformationByHandle on '{s}' failed, error={}", .{ filename_for_error, std.os.windows.kernel32.GetLastError() });
                std.process.exit(1);
            }
            return FileId{
                .dev = info.dwVolumeSerialNumber,
                .ino = (@as(u64, @intCast(info.nFileIndexHigh)) << 32) | @as(u64, @intCast(info.nFileIndexLow)),
            };
        }
        const st = try std.posix.fstat(file.handle);
        return FileId{
            .dev = st.dev,
            .ino = st.ino,
        };
    }

    pub fn initFromDir(dir: std.fs.Dir, name_for_error: []const u8) !FileId {
        if (builtin.os.tag == .windows) {
            return initFromFile(std.fs.File{ .handle = dir.fd }, name_for_error);
        }
        return initFromFile(std.fs.File{ .handle = dir.fd }, name_for_error);
    }

    pub fn eql(self: FileId, other: FileId) bool {
        return self.dev == other.dev and self.ino == other.ino;
    }
};

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
    if (path_link.len > std.fs.max_path_bytes) {
        std.debug.print("Error: path_link (size {}) is too large (max {})\n", .{ path_link.len, std.fs.max_path_bytes });
        std.process.exit(1);
    }
    const file = std.fs.cwd().createFile(path_link, .{}) catch |err| switch (err) {
        error.IsDir => {
            std.debug.print(
                "unable to create the exe link, the path '{s}' is a directory\n",
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

fn installCompiler(allocator: Allocator, compiler_dir: []const u8, url: []const u8) !void {

    if (std.fs.cwd().access(compiler_dir, .{})) |_| {
        loginfo("compiler '{s}' already installed", .{compiler_dir});
        return;
    } else |e| {
        if (e != error.FileNotFound) {
            return e;
        }
    }

    const installing_dir = try std.mem.concat(allocator, u8, &[_][]const u8{ compiler_dir, ".installing" });
    defer allocator.free(installing_dir);
    try std.fs.cwd().deleteTree(installing_dir);
    try std.fs.cwd().makePath(installing_dir);

    const archive_basename = std.fs.path.basename(url);
    var archive_root_dir: []const u8 = undefined;

    // download and extract archive
    {
        const archive = try std.fs.path.join(allocator, &[_][]const u8{ installing_dir, archive_basename });
        defer allocator.free(archive);
        loginfo("downloading '{s}' to '{s}'", .{ url, archive });

        switch (blk: {
            const file = try std.fs.cwd().createFile(archive, .{});
            // note: important to close the file before we handle errors below
            //       since it will delete the parent directory of this file
            defer file.close();
            break :blk try download(allocator, url, file.writer());
        }) {
            .ok => {},
            .err => |err| {
                std.log.err("download '{s}' failed: {s}", .{url, err});
                // this removes the installing dir if the http request fails so we dont have random directories
                try std.fs.cwd().deleteTree(installing_dir);
                std.process.exit(1);
            },
        }

        if (std.mem.endsWith(u8, archive_basename, ".tar.xz")) {
            loginfo("extracting {s} into {s}", .{ archive, installing_dir });
            archive_root_dir = archive_basename[0 .. archive_basename.len - ".tar.xz".len];

            var file = try std.fs.cwd().openFile(archive, .{});
            defer file.close();

            var dir = try std.fs.cwd().openDir(installing_dir, .{});
            defer dir.close();


            var tar = try std.compress.xz.decompress(allocator, file.reader());
            try std.tar.pipeToFileSystem(dir, tar.reader(), .{});
        } else {
            var recognized = false;
            if (builtin.os.tag == .windows) {
                if (std.mem.endsWith(u8, archive_basename, ".zip")) {
                    loginfo("extracting {s} into {s}", .{ archive, installing_dir });
                    recognized = true;
                    archive_root_dir = archive_basename[0 .. archive_basename.len - ".zip".len];

                    var installing_dir_opened = try std.fs.cwd().openDir(installing_dir, .{});
                    defer installing_dir_opened.close();


                    var timer = try std.time.Timer.start();
                    var archive_file = try std.fs.cwd().openFile(archive, .{});
                    defer archive_file.close();
                    try std.zip.extract(installing_dir_opened, archive_file.seekableStream(), .{});
                    const time = timer.read();
                    loginfo("extracted archive in {d:.2} s", .{@as(f32, @floatFromInt(time)) / @as(f32, @floatFromInt(std.time.ns_per_s))});
                }
            }

            if (!recognized) {
                std.log.err("unknown archive extension '{s}'", .{archive_basename});
                return error.UnknownArchiveExtension;
            }
        }
        try std.fs.cwd().deleteTree(archive);
    }

    {
        const extracted_dir = try std.fs.path.join(allocator, &[_][]const u8{ installing_dir, archive_root_dir });
        defer allocator.free(extracted_dir);
        const normalized_dir = try std.fs.path.join(allocator, &[_][]const u8{ installing_dir, "files" });
        defer allocator.free(normalized_dir);
        try std.fs.cwd().rename(extracted_dir, normalized_dir);
    }

    // TODO: write date information (so users can sort compilers by date)

    // finish installation by renaming the install dir
    try std.fs.cwd().rename(installing_dir, compiler_dir);
}

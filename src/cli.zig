const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const Config = @import("config.zig");

pub const ParseError = error{CannotPrintHelp, MissingArg} || Allocator.Error;

pub const CliAction = union(enum) {
    const RawVersion = struct { version: []const u8 };
    const OptionalVersion = struct { version: ?[]const u8 };
    const RawPath = struct { path: []const u8 };


    download_default: RawVersion,

    fetch: RawVersion,
    default: OptionalVersion,
    list: void,
    clean: RawVersion,
    keep: RawVersion,

    run: struct { version: []const u8, zig_args: []const []const u8 },

    set_install_dir: RawPath,
    set_zig_symlink: RawPath,
    set_zls_symlink: RawPath,

    fetch_index: void,
    fetch_mach_index: void,

    pub fn deinit(self: CliAction, alloc: Allocator) void {
        switch (self) {
            .download_default, .fetch, .keep, .clean => |a| alloc.free(a.version),
            .default => |a| if (a.version) |v| alloc.free(v),

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
pub const ParsedCli = struct {
    config: Config,
    action: CliAction,

    pub fn deinit(self: ParsedCli, alloc: Allocator) void {
        self.config.deinit(alloc);
        self.action.deinit(alloc);
    }
};

fn print_help() !void {
    std.io.getStdOut().writeAll(
        \\Download and manage Zig compilers and ZLS.
        \\
        \\Usage:
        \\
        \\  zigup <VERSION>               Download this version of zig/zls and set it as default
        \\                                May be set to any version number, stable, master, <VERSION>-mach, mach-latest, or latest-installed
        \\
        \\  zigup fetch <VERSION>         Download <VERSION> compiler
        \\  zigup default [VERSION]       Get or set the default compiler/zls (makes a symlink)
        \\  zigup list                    List installed versions
        \\  zigup run <VERSION> ARGS...   Run the given version of the compiler with the given ARGS...
        \\
        \\  zigup clean <VERSION>         Delete the given compiler/zls version
        \\  zigup clean outdated          Delete all but stable, latest-installed and manually kept versions
        \\  zigup keep <VERSION>          Mark a version to be kept during clean
        \\
        \\Configuration:
        \\  zigup set-install-dir <DIR>         Set the default installation directory
        \\  zigup set-zig-symlink <FILE_PATH>   Set the default symlink path (see --zig-symlink)
        \\  zigup set-zls-symlink <FILE_PATH>   Set the default symlink path (see --zls-symlink)
        \\
        \\  zigup fetch-index             Download and print the index.json
        \\  zigup fetch-mach-index        Download and print the index.json
        \\
        \\Options:
        \\  --install-dir <DIR>           Install zig compilers in <DIR>
        \\  --zig-symlink <FILE_PATH>     Path where the `zig` symlink will be placed, pointing to the default compiler
        \\                                This will typically be a file path within a PATH directory so that the user can just run `zig`
        \\                                Defaults to install-dir/zig
        \\
        \\  --zls-symlink <FILE_PATH>     Path where the `zls` symlink will be placed, pointing to the default language server
        \\                                This will typically be a file path within a PATH directory so that the user can just run `zig`
        \\                                Defaults to install-dir/zls
        \\
        \\  -h, --help                    Display this help text
        \\
    ) catch return error.CannotPrintHelp;
}

pub fn parseCliArgs(alloc: Allocator, args: []const []const u8) ParseError!ParsedCli {
    if (args.len < 2) {
        try print_help();
        std.process.exit(0);
    }
    var config: Config = .{};
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
                    .zig_args = zig_args,
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

    } else if (std.mem.eql(u8, "keep", cmd)) {
        const v = non_option_args[1] orelse {
            std.log.err("{s} requires an argument", .{cmd});
            return error.MissingArg;
        };
        action = .{ .keep = .{
            .version = try alloc.dupe(u8, v)
        } };

    } else if (std.mem.eql(u8, "clean", cmd)) {
        const v = non_option_args[1] orelse {
            std.log.err("{s} requires an argument", .{cmd});
            return error.MissingArg;
        };
        action = .{ .clean = .{
            .version = try alloc.dupe(u8, v)
        } };

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
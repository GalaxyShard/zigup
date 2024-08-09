const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const Config = @This();
const known_folders = @import("known-folders");

pub const Key = enum { install_dir, zig_symlink, zls_symlink };

install_dir: ?[]const u8 = null,
zig_symlink: ?[]const u8 = null,
zls_symlink: ?[]const u8 = null,

pub fn deinit(self: Config, alloc: Allocator) void {
    if (self.install_dir) |dir| alloc.free(dir);
    if (self.zig_symlink) |symlink| alloc.free(symlink);
    if (self.zls_symlink) |symlink| alloc.free(symlink);
}


pub const Resolved = struct {
    install_dir: []const u8,
    zig_symlink: []const u8,
    zls_symlink: []const u8,
    pub fn deinit(self: Resolved, alloc: Allocator) void {
        alloc.free(self.install_dir);
        alloc.free(self.zig_symlink);
        alloc.free(self.zls_symlink);
    }
};

pub fn parse(alloc: Allocator, reader: anytype) !Config {
    const contents = try reader.readAllAlloc(alloc, 4096*3);

    defer alloc.free(contents);
    var config: Config = .{};

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
pub fn read(alloc: Allocator) !Config {
    var config_dir: std.fs.Dir = known_folders.open(alloc, .local_configuration, .{})
        catch { return error.NoConfigDirectory; }
        orelse return error.NoConfigDirectory;
    defer config_dir.close();

    var config_file = config_dir.openFile("zigup.conf", .{}) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => |err| return err,
    };
    defer config_file.close();

    return parse(alloc, config_file.reader());
}
pub fn write(alloc: Allocator, config: Config) !void {
    var config_dir: std.fs.Dir = known_folders.open(alloc, .local_configuration, .{})
        catch { return error.NoConfigDirectory; }
        orelse return error.NoConfigDirectory;
    defer config_dir.close();

    var config_file = try config_dir.createFile("zigup.conf", .{});
    defer config_file.close();

    inline for (@typeInfo(@TypeOf(config)).Struct.fields) |field| {
        if (@field(config, field.name)) |f| {
            try config_file.writer().print(field.name ++ "={s}\n", .{ f });
        }
    }
}
pub fn setDefault(alloc: Allocator, comptime key: Config.Key, value: []const u8) !void {
    var config = try read(alloc);

    if (@field(config, @tagName(key))) |f| {
        alloc.free(f);
    }
    @field(config, @tagName(key)) = try alloc.dupe(u8, value);

    try write(alloc, config);
}
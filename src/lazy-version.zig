const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const version_index = @import("version-index.zig");
const Config = @import("config.zig");


const LazyVersion = @This();

const host_cpu_arch = switch (builtin.cpu.arch) {
    .x86 => "i386",
    .x86_64 => "x86_64",
    .aarch64 => "aarch64",
    .arm => "armv7a",
    .riscv64 => "riscv64",
    .powerpc64le => "powerpc64le",
    .powerpc => "powerpc",
    else => @compileError("Unsupported CPU Architecture"),
};
const host_os = switch (builtin.os.tag) {
    .windows => "windows",
    .linux => "linux",
    .macos => "macos",
    .freebsd => "freebsd",
    else => @compileError("Unsupported OS"),
};
const json_platform = host_cpu_arch ++ "-" ++ host_os;

alloc: Allocator,
raw: []const u8,

index: version_index.Indexes = .{ .mach = null, .zig = null },
id: ?[]const u8 = null,
url: ?[]const u8 = null,
date: ?[]const u8 = null,

resolve_error: ?ResolveError = null,

pub fn init(alloc: Allocator, raw_version: []const u8) !LazyVersion {
    const v = (
        if (std.mem.startsWith(u8, raw_version, "zig-"))
            raw_version["zig-".len ..]
        else
            raw_version
    );

    return .{
        .alloc = alloc,
        .raw = try alloc.dupe(u8, v),
    };
}
pub fn deinit(self: LazyVersion) void {
    self.alloc.free(self.raw);

    self.index.deinit();
    if (self.id) |a| self.alloc.free(a);
    if (self.url) |a| self.alloc.free(a);
    if (self.date) |a| self.alloc.free(a);
}
const ResolveError = error {
    NoDate,
    InvalidIndexJson,
    UnsupportedSystem,
    InvalidVersion,
} || Allocator.Error || version_index.GetIndexError || FindLatestError;

const FindLatestError = error {
    FailedInstallSearch,
    NoInstalledVersions,
} || Allocator.Error;

pub fn resolveAll(self: *LazyVersion, config: Config.Resolved) ResolveError!void {
    if (self.resolve_error) |e| {
        return e;
    }

    if (self.resolveAllInner(config)) {
        return;
    } else |e| {
        self.resolve_error = e;
        return e;
    }
}
fn urlFromId(alloc: Allocator, id: []const u8) ![]const u8 {
    const version = id["zig-".len..];
    return std.mem.concat(alloc, u8, &.{
        "https://ziglang.org/builds/zig-" ++ host_os ++ "-" ++ host_cpu_arch ++ "-",
        version,
        (if (builtin.os.tag == .windows) ".zip" else ".tar.xz"),
    });
}
fn resolveAllInner(self: *LazyVersion, config: Config.Resolved) ResolveError!void {
    if (std.mem.eql(u8, self.raw, "stable")) {
        try self.findStable();

    } else if (std.mem.eql(u8, self.raw, "master")) {
        try self.findFromIndex(.zig, .no_cache);

    } else if (std.mem.eql(u8, self.raw, "latest-installed")) {
        const latest_found = try latestInstalledVersion(self.alloc, config.install_dir, .no_filter);

        self.id = latest_found;
        self.url = try urlFromId(self.alloc, latest_found);
        // Unless latest-installed is master or a stable/nominated version, it is impossible to find the date/url without saving it during install
        // This should not be necessary anyways; date is only needed while installing zls
        return error.NoDate;

    } else if (std.mem.eql(u8, self.raw, "mach-latest")) {
        try self.findFromIndex(.mach, .no_cache);

    } else if (std.mem.endsWith(u8, self.raw, "-mach")) {
        try self.findFromIndex(.mach, .cache);

    } else {
        // validate this is a valid version number
        _ = std.SemanticVersion.parse(self.raw) catch return error.InvalidVersion;
        self.id = try std.mem.concat(self.alloc, u8, &.{ "zig-", self.raw });
        self.url = try urlFromId(self.alloc, self.id.?);

        self.findFromIndex(.zig, .cache) catch |e| switch (e) {
            error.InvalidVersion => {
                // No entry in index.json was found, but this is
                // a valid semantic version and may be a dev release
                // or the cache hasn't been cleared
                return error.NoDate;
            },
            else => return e,
        };
    }
}
pub fn resolveId(self: *LazyVersion, config: Config.Resolved) ResolveError![]const u8 {
    if (self.id) |v| {
        return v;
    }
    self.resolveAll(config) catch |e| switch (e) {
        error.NoDate => {},
        else => return e,
    };
    return self.id.?;
}
pub fn resolveUrl(self: *LazyVersion, config: Config.Resolved) ResolveError![]const u8 {
    if (self.url) |v| {
        return v;
    }
    self.resolveAll(config) catch |e| switch (e) {
        error.NoDate => {},
        else => return e,
    };
    return self.url.?;
}
pub fn resolveDate(self: *LazyVersion, config: Config.Resolved) ResolveError![]const u8 {
    if (self.date) |v| {
        return v;
    }
    try self.resolveAll(config);
    return self.date.?;
}

fn findStable(self: *LazyVersion) ResolveError!void {
    var latest_found: ?std.SemanticVersion = null;

    var id = try std.ArrayList(u8).initCapacity(self.alloc, "zig-0.00.0".len);
    var url = std.ArrayList(u8).init(self.alloc);
    var date = try std.ArrayList(u8).initCapacity(self.alloc, "0000-00-00".len);
    defer {
        id.deinit();
        url.deinit();
        date.deinit();
    }

    var iter = (try self.index.get(self.alloc, .zig, .no_cache)).value.object.iterator();
    while (iter.next()) |pair| {
        // note: version is invalidated alongside pair.key_ptr
        if (std.SemanticVersion.parse(pair.key_ptr.*)) |version| {
            // ignore prereleases
            if (version.pre != null) {
                continue;
            }
            if (latest_found == null or version.order(latest_found.?).compare(.gt)) {

                id.clearRetainingCapacity();
                try id.appendSlice("zig-");
                try id.appendSlice(pair.key_ptr.*);
                // parse it again; key_ptr and it's parsed semantic version is invalidated each iteration
                latest_found = std.SemanticVersion.parse(id.items["zig-".len ..])
                    catch unreachable;

                const new_date = pair.value_ptr.object.get("date")
                    orelse return error.InvalidIndexJson;

                date.clearRetainingCapacity();
                try date.appendSlice(new_date.string);

                const compiler = pair.value_ptr.object.get(json_platform)
                    orelse return error.UnsupportedSystem;
                const tarball = compiler.object.get("tarball")
                    orelse return error.InvalidIndexJson;

                url.clearRetainingCapacity();
                try url.appendSlice(tarball.string);

            }
        } else |_| {
            continue;
        }
    }
    self.id = try id.toOwnedSlice();
    self.url = try url.toOwnedSlice();
    self.date = try date.toOwnedSlice();
}
fn findFromIndex(
    self: *LazyVersion,
    comptime index_type: version_index.IndexType,
    may_cache: version_index.MayCache
) ResolveError!void {
    const index = try self.index.get(self.alloc, index_type, may_cache);
    if (index.value != .object) return error.InvalidIndexJson;

    const version_info = index.value.object.get(self.raw) orelse return error.InvalidVersion;
    if (version_info != .object) return error.InvalidIndexJson;

    const version_id = version_info.object.get("version");

    const date = version_info.object.get("date") orelse return error.InvalidIndexJson;
    if (date != .string) return error.InvalidIndexJson;

    const compiler = version_info.object.get(json_platform) orelse return error.UnsupportedSystem;
    if (compiler != .object) return error.InvalidIndexJson;

    const tarball = compiler.object.get("tarball") orelse return error.InvalidIndexJson;
    if (tarball != .string) return error.InvalidIndexJson;

    if (version_id) |v| {
        if (v != .string) return error.InvalidIndexJson;

        self.id = try std.mem.concat(self.alloc, u8, &.{ "zig-", v.string });
    } else {
        // "version" is not in the version info if the version is the key (self.raw)
        // validate this is a valid version number
        _ = std.SemanticVersion.parse(self.raw) catch return error.InvalidVersion;

        self.id = try std.mem.concat(self.alloc, u8, &.{ "zig-", self.raw });
    }
    self.url = try self.alloc.dupe(u8, tarball.string);
    self.date = try self.alloc.dupe(u8, date.string);
}

pub fn latestInstalledVersion(
    alloc: Allocator,
    install_dir: []const u8,
    filter: enum { no_filter, stable }
) FindLatestError ![]const u8 {
    var directory = std.fs.cwd().openDir(install_dir, .{
        .iterate = true,
    }) catch |e| switch (e) {
        error.FileNotFound => return error.NoInstalledVersions,
        else => return error.FailedInstallSearch,
    };
    defer directory.close();

    var latest_found: ?[]const u8 = null;

    var iter = directory.iterate();
    while (iter.next() catch return error.FailedInstallSearch) |entry| {
        if (entry.kind != .directory) continue;

        if (std.SemanticVersion.parse(entry.name["zig-".len ..])) |found_version| {
            if (filter == .stable and (found_version.pre != null)) {
                continue;
            }

            if (latest_found) |latest| {
                const latest_version = std.SemanticVersion.parse(latest["zig-".len ..])
                    catch unreachable;

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
    return latest_found orelse error.NoInstalledVersions;
}
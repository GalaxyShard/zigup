const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const known_folders = @import("known-folders");
const download = @import("download.zig");

const version_index = @This();

pub const MayCache = enum { always_cache, try_cache, never_cache };
pub const IndexType = enum { zig, mach };

pub const GetIndexError = error {
    NoCacheDirectory,
    DownloadFailed,
    WriteCacheFailed,
    ReadCacheFailed,
    ParseFailed,

} || Allocator.Error;

const zig_index_url = "https://ziglang.org/download/index.json";
const mach_index_url = "https://machengine.org/zig/index.json";



pub const Indexes = struct {
    const Type = std.json.Value;
    mach: ?std.json.Parsed(Type) = null,
    zig: ?std.json.Parsed(Type) = null,

    pub fn get(
        self: *Indexes,
        alloc: Allocator,
        comptime index_type: IndexType,
        use_cache: MayCache
    ) GetIndexError!*std.json.Parsed(Type) {
        const field = @tagName(index_type); // zig, mach
        const cache_file_path = "zigup/index-" ++ field ++ ".json";

        if (@field(self, field)) |_| return &@field(self, field).?;

        var cache_dir: std.fs.Dir = known_folders.open(alloc, .cache, .{})
            catch { return error.NoCacheDirectory; }
            orelse return error.NoCacheDirectory;
        defer cache_dir.close();


        if (use_cache == .never_cache) {
            return self.fetchAndCache(alloc, cache_dir, index_type);
        }
        if (cache_dir.openFile(cache_file_path, .{})) |cache_file| {
            defer cache_file.close();

            var reader = std.json.reader(alloc, cache_file.reader());
            const cached_json = std.json.parseFromTokenSource(Type, alloc, &reader, .{});

            if (cached_json) |json| {
                @field(self, field) = json;
                return &@field(self, field).?;
            } else |e| {
                std.log.err("failed to parse cached index: {}; refreshing", .{e});
                return self.fetchAndCache(alloc, cache_dir, index_type);
            }


        } else |e| switch (e) {
            error.FileNotFound => return self.fetchAndCache(alloc, cache_dir, index_type),
            else => return error.ReadCacheFailed,
        }
    }

    fn fetchAndCache(
        self: *Indexes,
        alloc: Allocator,
        cache_dir: std.fs.Dir,
        comptime index_type: IndexType
    ) GetIndexError!*std.json.Parsed(Type) {
        const field = @tagName(index_type); // zig, mach
        const index = try version_index.fetchAndCache(alloc, cache_dir, index_type);

        @field(self, field) = index.json;
        return &@field(self, field).?;
    }

    pub fn deinit(self: Indexes) void {
        if (self.mach) |m| m.deinit();
        if (self.zig) |z| z.deinit();
    }
};

const Index = struct {
    text: []u8,
    json: std.json.Parsed(Indexes.Type),
    pub fn deinit(self: Index, allocator: Allocator) void {
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
fn fetchIndex(alloc: Allocator, comptime index_type: IndexType) error{DownloadFailed,ParseFailed}!Index {
    const url_string = switch (index_type) {
        .zig => zig_index_url,
        .mach => mach_index_url,
    };
    const text = download.downloadToString(alloc, url_string)
        catch return error.DownloadFailed;
    errdefer alloc.free(text);

    var json = std.json.parseFromSlice(Indexes.Type, alloc, text, .{})
        catch return error.ParseFailed;
    errdefer json.deinit();

    return .{ .text = text, .json = json };
}
pub fn fetchAndCache(
    alloc: Allocator,
    cache_dir: std.fs.Dir,
    comptime index_type: IndexType
) GetIndexError!Index {
    const cache_file_path = "zigup/index-" ++ @tagName(index_type) ++ ".json";


    const index = try fetchIndex(alloc, index_type);
    errdefer index.deinit(alloc);

    cache_dir.makeDir("zigup") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return error.WriteCacheFailed,
    };

    const file = cache_dir.createFile(cache_file_path, .{})
        catch return error.WriteCacheFailed;
    defer file.close();

    file.writeAll(index.text) catch return error.WriteCacheFailed;
    return index;
}
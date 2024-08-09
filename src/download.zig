const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const DownloadError = error { ParseUrlFailed, DownloadFailed, ConnectionFailed }
    || Allocator.Error;

pub fn download(allocator: Allocator, url: []const u8, writer: anytype) DownloadError!void {
    const uri = std.Uri.parse(url) catch return error.ParseUrlFailed;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    client.initDefaultProxies(allocator) catch return error.DownloadFailed;

    var header_buffer: [4096]u8 = undefined;
    var request = client.open(.GET, uri, .{
        .server_header_buffer = &header_buffer,
        .keep_alive = false,
    }) catch return error.ConnectionFailed;

    defer request.deinit();

    request.send() catch return error.DownloadFailed;
    request.wait() catch return error.DownloadFailed;

    if (request.response.status != .ok) return error.DownloadFailed;

    // TODO: take advantage of request.response.content_length

    var buf: [4096]u8 = undefined;
    while (true) {
        const len = request.reader().read(&buf) catch return error.DownloadFailed;
        if (len == 0) return;

        writer.writeAll(buf[0..len]) catch return error.DownloadFailed;
    }
}

pub fn downloadToString(allocator: Allocator, url: []const u8) DownloadError![]u8 {
    var response_array_list = try std.ArrayList(u8).initCapacity(allocator, 20 * 1024); // 20 KB (modify if response is expected to be bigger)
    defer response_array_list.deinit();

    try download(allocator, url, response_array_list.writer());
    return response_array_list.toOwnedSlice();
}
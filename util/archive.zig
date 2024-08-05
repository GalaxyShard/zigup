const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    std.debug.assert(args.len == 3);

    const in_path = args[1];
    const out_path = args[2];

    const input = try std.fs.cwd().openFile(in_path, .{});
    defer input.close();

    const output = try std.fs.cwd().createFile(out_path, .{});
    defer output.close();

    try std.compress.gzip.compress(input.reader(), output.writer(), .{});
}
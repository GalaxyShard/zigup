const builtin = @import("builtin");
const std = @import("std");

const log = std.log.scoped(.zigexelink);

// NOTE: to prevent the exe from having multiple markers, there can't be a separate string literal
//       for the marker to get the length
// TODO: check if this creates two strings in the binary
const exe_marker_len = "!!!THIS MARKS THE zig_exe_string MEMORY!!#".len;

// I'm exporting this and making it mutable to make sure the compiler keeps it around
// and prevent it from evaluting its contents at comptime
export var zig_exe_string: [exe_marker_len + std.fs.max_path_bytes + 1]u8 =
    ("!!!THIS MARKS THE zig_exe_string MEMORY!!#" ++ ([1]u8{0} ** (std.fs.max_path_bytes + 1))).*;

const global = struct {
    var child: std.process.Child = undefined;
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
};

pub fn main() !u8 {
    // Sanity check that the exe_marker_len is right (note: not fullproof)
    std.debug.assert(zig_exe_string[exe_marker_len - 1] == '#');
    if (zig_exe_string[exe_marker_len] == 0) {
        log.err("the zig target executable has not been set in the exelink", .{});
        return 0xff; // fail
    }
    var zig_exe_len: usize = 1;
    while (zig_exe_string[exe_marker_len + zig_exe_len] != 0) {
        zig_exe_len += 1;
        if (exe_marker_len + zig_exe_len > std.fs.max_path_bytes) {
            log.err("the zig target execuable is either too big (over {}) or the exe is corrupt", .{std.fs.max_path_bytes});
            return 1;
        }
    }
    const zig_exe = zig_exe_string[exe_marker_len .. exe_marker_len + zig_exe_len :0];

    const args = try std.process.argsAlloc(global.arena);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "exelink")) {
        try std.io.getStdOut().writer().writeAll(zig_exe);
        return 0;
    }
    args[0] = zig_exe;

    // NOTE: create the process.child before calling SetConsoleCtrlHandler because it uses it
    global.child = std.process.Child.init(args, global.arena);

    if (std.os.windows.SetConsoleCtrlHandler(consoleCtrlHandler, true)) |_| {

    } else |err| {
        log.err("SetConsoleCtrlHandler failed, error={}", .{err});
        return 0xff; // fail
    }

    try global.child.spawn();
    return switch (try global.child.wait()) {
        .Exited => |e| e,
        .Signal => 0xff,
        .Stopped => 0xff,
        .Unknown => 0xff,
    };
}

fn consoleCtrlHandler(ctrl_type: u32) callconv(std.os.windows.WINAPI) std.os.windows.BOOL {
    //
    // NOTE: Do I need to synchronize this with the main thread?
    //
    const name: []const u8 = switch (ctrl_type) {
        std.os.windows.CTRL_C_EVENT => "Control-C",
        std.os.windows.CTRL_BREAK_EVENT => "Break",
        std.os.windows.CTRL_CLOSE_EVENT => "Close",
        std.os.windows.CTRL_LOGOFF_EVENT => "Logoff",
        std.os.windows.CTRL_SHUTDOWN_EVENT => "Shutdown",
        else => "Unknown",
    };
    // TODO: should we stop the process on a break event?
    log.info("caught ctrl signal {d} ({s}), stopping process...", .{ ctrl_type, name });
    const exit_code = switch (global.child.kill() catch |err| {
        log.err("failed to kill process, error={s}", .{@errorName(err)});
        std.process.exit(0xff);
    }) {
        .Exited => |e| e,
        .Signal => 0xff,
        .Stopped => 0xff,
        .Unknown => 0xff,
    };
    std.process.exit(exit_code);
    unreachable;
}

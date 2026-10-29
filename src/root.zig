const std = @import("std");
const Io = std.Io;

const win = std.os.windows;
const ntdll = win.ntdll;

pub const WatcherOptions = struct {
    recursive: bool = true,
    capture: win.FILE.NOTIFY.CHANGE,
};

pub const WatcherError = error{
    AsyncUnsupported,
    AccessDenied,
    Unexpected,
};

pub const Watcher = switch (@import("builtin").target.os.tag) {
    .windows => WatcherWindows,
    else => @compileError("Unsupported Operating System"),
};

const WatcherWindows = struct {
    dir: std.Io.Dir,
    options: WatcherOptions,

    pub fn init(dir: std.Io.Dir, options: WatcherOptions) Watcher {
        return .{ .dir = dir, .options = options };
    }

    pub fn next(watcher: *const @This(), buffer: []u8) ![]const u8 {
        var s_block: win.IO_STATUS_BLOCK = undefined;

        var helper_buffer: ([4096]u8) align(@alignOf(win.FILE.NOTIFY.CHANGE)) = undefined;

        const status = ntdll.NtNotifyChangeDirectoryFileEx(
            watcher.dir.handle,
            null,
            null,
            null,
            &s_block,
            &helper_buffer,
            @sizeOf(@TypeOf(helper_buffer)),
            watcher.options.capture,
            .fromBool(watcher.options.recursive),
            .Notify,
        );

        if (status == .PENDING) {
            var s_block_cancel: win.IO_STATUS_BLOCK = undefined;
            const cancel_status = ntdll.NtCancelIoFileEx(watcher.dir.handle, &s_block, &s_block_cancel);
            std.debug.assert(cancel_status == .SUCCESS);
            return error.AsyncUnsupported;
        }

        return switch (status) {
            .SUCCESS => brk: {
                const information: *win.FILE.NOTIFY.INFORMATION = @ptrCast(&helper_buffer);
                const data = information.fileName();
                const size = try std.unicode.utf16LeToUtf8(buffer, data);
                break :brk buffer[0..size];
            },
            .ACCESS_DENIED => error.AccessDenied,
            else => brk: {
                std.log.err("Unexpected NTSTATUS: {}", .{status});
                break :brk error.Unexpected;
            },
        };
    }
};

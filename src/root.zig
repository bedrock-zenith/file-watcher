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
    .windows => SyncWatcherWindows,
    else => @compileError("Unsupported Operating System"),
};

const SyncWatcherWindows = struct {
    dir: std.Io.Dir,
    options: WatcherOptions,
    buffer: []align(BufferAlignment) u8,

    pub fn next(watcher: *@This(), buffer: []u8) !WatcherNotification {
        var s_block: win.IO_STATUS_BLOCK = undefined;

        //var helper_buffer: ([32_768]u8) align(@alignOf(win.FILE.NOTIFY.CHANGE)) = undefined;

        const status = ntdll.NtNotifyChangeDirectoryFileEx(
            watcher.dir.handle,
            null,
            null,
            null,
            &s_block,
            watcher.buffer.ptr,
            @intCast(watcher.buffer.len),
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
                var ite: WatcherActionIterator = .{
                    .buffer = buffer,
                    .ptr = @ptrCast(watcher.buffer.ptr),
                    .index = 0,
                };

                const first = (try ite.next()) orelse return error.Unexpected;
                const second = try ite.next();

                break :brk switch (first.@"0") {
                    .create => .{ .created = first.@"1" },
                    .delete => .{ .deleted = first.@"1" },
                    .change => .{ .changed = first.@"1" },
                    .rename_old => .{
                        .renamed = .{
                            .old = first.@"1",
                            .new = (second orelse return error.Unexpected).@"1",
                        },
                    },
                    else => .{ .unknown = {} },
                };
            },
            .ACCESS_DENIED => error.AccessDenied,
            else => brk: {
                std.log.err("Unexpected NTSTATUS: {}", .{status});
                break :brk error.Unexpected;
            },
        };
    }
};

pub const WatcherAction = enum {
    create,
    delete,
    change,
    rename_old,
    rename_new,
    unknown,
};

pub const WatcherNotification = union(enum) {
    created: []const u8,
    deleted: []const u8,
    changed: []const u8,
    renamed: struct { old: []const u8, new: []const u8 },
    unknown: void,
};

pub const BufferAlignment: comptime_int = @alignOf(win.FILE.NOTIFY.CHANGE);
/// No synchronization primitives so this API is expected to be all called from single thread
pub const AsyncWatcherWindows = struct {
    handle: win.HANDLE,
    options: WatcherOptions,
    buffer: []align(BufferAlignment) u8,
    block: win.IO_STATUS_BLOCK = undefined,
    state: enum { init, pending, completed } = .init,

    pub fn init(dir: std.Io.Dir, options: WatcherOptions, buffer: []align(BufferAlignment) u8) error{Unexpected}!AsyncWatcherWindows {
        var handle: win.HANDLE = undefined;
        const object_attributes: win.OBJECT.ATTRIBUTES = .{
            .RootDirectory = dir.handle,
        };
        var status_block: win.IO_STATUS_BLOCK = undefined;
        const status = ntdll.NtOpenFile(
            &handle,
            .{
                .GENERIC = .{ .READ = true },
                .STANDARD = .{ .SYNCHRONIZE = true },
                .SPECIFIC = .{
                    .FILE_DIRECTORY = .{ .LIST = true, .TRAVERSE = true },
                },
            },
            &object_attributes,
            &status_block,
            .{ .DELETE = true, .READ = true, .WRITE = true },
            .{ .IO = .ASYNCHRONOUS },
        );
        if (status != .SUCCESS) {
            std.log.debug("Unexpected NT_STATUS {}", .{status});
            return error.Unexpected;
        }

        return .{
            .handle = handle,
            .options = options,
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *const AsyncWatcherWindows) void {
        std.debug.assert(self.state == .init);
        _ = ntdll.NtClose(self.handle);
    }

    pub fn notify(watcher: *@This()) !void {
        std.debug.assert(watcher.state == .init);
        const apcContext = null;
        const status = ntdll.NtNotifyChangeDirectoryFileEx(
            watcher.handle,
            null,
            @alignCast(&callback),
            apcContext,
            &watcher.block,
            watcher.buffer.ptr,
            @intCast(watcher.buffer.len),
            watcher.options.capture,
            .fromBool(watcher.options.recursive),
            .Notify,
        );

        return switch (status) {
            .PENDING => {
                watcher.state = .pending;
            },
            .SUCCESS => callback(apcContext, &watcher.block, undefined),
            .ACCESS_DENIED => error.AccessDenied,
            else => brk: {
                std.log.err("Unexpected NTSTATUS: {}", .{status});
                break :brk error.Unexpected;
            },
        };
    }

    pub fn wait(watcher: *@This(), timeout: std.Io.Duration) error{Timeout}!void {
        if (watcher.state != .pending) return;
        var duration: std.Io.Duration = timeout;
        const multiple = brk: {
            var frequency: i64 = 1;
            _ = ntdll.RtlQueryPerformanceFrequency(&frequency);
            break :brk @divFloor(1_000_000_000, frequency);
        };
        while (true) {
            if (duration.nanoseconds <= 0) return error.Timeout;

            var indefinite: i64 = -(@as(i64, @intCast(@divTrunc(duration.nanoseconds, 100) & 0x8FFF_FFFF_FFFF_FFFF)));
            if (indefinite >= 0) indefinite = 0;

            var counter_start: i64 = undefined;
            var counter_end: i64 = undefined;

            _ = ntdll.RtlQueryPerformanceCounter(&counter_start);
            const status = ntdll.NtDelayExecution(.TRUE, &indefinite);
            _ = ntdll.RtlQueryPerformanceCounter(&counter_end);

            const diff = @abs(counter_end - counter_start);
            duration.nanoseconds -= @as(i64, @bitCast(diff)) * multiple;

            if (status == .SUCCESS or status == .TIMEOUT) return error.Timeout;

            if (watcher.state == .completed) return;
            std.log.err("Expected NTSTATUS: {}, state: {}", .{ status, watcher.state });
        }
    }

    pub fn collect(watcher: *@This(), buffer: []u8) !WatcherNotification {
        std.debug.assert(watcher.state == .completed);
        watcher.state = .init;

        const status = watcher.block.u.Status;
        if (status == .CANCELLED) {
            return error.Canceled;
        }

        var ite: WatcherActionIterator = .{
            .buffer = buffer,
            .ptr = @ptrCast(watcher.buffer.ptr),
            .index = 0,
        };

        const first = (try ite.next()) orelse return error.Unexpected;
        const second = try ite.next();

        return switch (first.@"0") {
            .create => .{ .created = first.@"1" },
            .delete => .{ .deleted = first.@"1" },
            .change => .{ .changed = first.@"1" },
            .rename_old => .{
                .renamed = .{
                    .old = first.@"1",
                    .new = (second orelse return error.Unexpected).@"1",
                },
            },
            else => .{ .unknown = {} },
        };
    }

    pub fn next(watcher: *@This()) void {
        switch (watcher.state) {
            .initialized => notify(watcher),
            .pending => {
                const indefinite: i64 = std.math.minInt(i64);
                const status = ntdll.NtDelayExecution(.TRUE, &indefinite);
                std.log.err("Expected NTSTATUS: {}, state: {}", .{ status, watcher.state });
            },
            .completed => {},
        }
    }

    pub fn cancel(watcher: *@This()) void {
        //std.debug.assert(watcher.state == .pending);

        var result_block: win.IO_STATUS_BLOCK = undefined;
        _ = ntdll.NtCancelIoFileEx(watcher.handle, &watcher.block, &result_block);

        if (result_block.u.Status == .SUCCESS) {
            wait(watcher, .max) catch {};
        }
    }

    fn callback(_: ?*anyopaque, block: *win.IO_STATUS_BLOCK, _: win.ULONG) callconv(.c) void {
        const parent: *@This() = @fieldParentPtr("block", block);
        parent.state = .completed;
    }
};

pub const WatcherActionIterator = struct {
    ptr: ?*win.FILE.NOTIFY.INFORMATION,
    buffer: []u8,
    index: usize,

    pub fn next(iter: *WatcherActionIterator) !?struct { WatcherAction, []const u8 } {
        const current = iter.ptr orelse return null;

        if (current.NextEntryOffset == 0) {
            iter.ptr = null;
        } else {
            const raw_addr = @intFromPtr(current);
            iter.ptr = @ptrFromInt(raw_addr + @as(usize, @intCast(current.NextEntryOffset)));
        }

        const path = current.fileName();

        var iterator: std.unicode.Wtf16LeIterator = .{
            .bytes = @as([*]u8, @ptrCast(path.ptr))[0..(path.len * 2)],
            .i = 0,
        };

        const start = iter.index;
        while (iterator.nextCodepoint()) |codepoint| {
            var length = try std.unicode.utf8CodepointSequenceLength(codepoint);
            if (iter.buffer.len < length + iter.index) {
                return error.BufferOverflow;
            }
            length = try std.unicode.wtf8Encode(codepoint, iter.buffer[iter.index..]);

            iter.index +%= @intCast(length);
        }

        return switch (current.Action) {
            1 => .{ WatcherAction.create, iter.buffer[start..iter.index] },
            2 => .{ WatcherAction.delete, iter.buffer[start..iter.index] },
            3 => .{ WatcherAction.change, iter.buffer[start..iter.index] },
            4 => .{ WatcherAction.rename_old, iter.buffer[start..iter.index] },
            5 => .{ WatcherAction.rename_new, iter.buffer[start..iter.index] },
            else => .{ WatcherAction.unknown, &.{} },
        };
    }
};

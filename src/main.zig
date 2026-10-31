const std = @import("std");
const Io = std.Io;

const file_watcher = @import("file_watcher");

pub fn main(init: std.process.Init) !void {
    try sync(init);
}

pub fn sync(init: std.process.Init) !void {
    const dir: std.Io.Dir = try .openDir(.cwd(), init.io, ".", .{
        .iterate = true,
        .access_sub_paths = true,
        .follow_symlinks = false,
    });

    var internal_data_buffer: [2048]u8 align(file_watcher.BufferAlignment) = undefined;

    // has to be run on single thread
    var watcher: file_watcher.Watcher = .{
        .dir = dir,
        .options = .{
            .recursive = true,
            .capture = .{
                .FILE_NAME = true,
                .LAST_WRITE = true,
                .CREATION = true,
            },
        },
        .buffer = &internal_data_buffer,
    };

    while (true) {
        var path_buffer: [2048]u8 = undefined;
        const notif = try watcher.next(&path_buffer);
        std.log.info("information: {any}", .{notif});
    }
}

pub fn async(init: std.process.Init) !void {
    const dir: std.Io.Dir = try .openDir(.cwd(), init.io, ".", .{
        .iterate = true,
        .access_sub_paths = true,
        .follow_symlinks = false,
    });

    var buffer: [2048]u8 align(file_watcher.BufferAlignment) = undefined;

    // has to be run on single thread
    var watcher: file_watcher.AsyncWatcherWindows = try .init(dir, .{
        .recursive = true,
        .capture = .{
            .FILE_NAME = true,
            .LAST_WRITE = true,
            .CREATION = true,
        },
    }, &buffer);
    defer watcher.deinit();
    defer watcher.cancel();

    try watcher.notify();

    while (true) {

        // You can specify reasonable timeout and catch the timeout to perform additional checks for debounce and other stuff
        watcher.wait(.max) catch unreachable;

        var path: [2048]u8 = undefined;
        const data = try watcher.collect(&path);
        std.log.info("information: {any}", .{data});
        try watcher.notify();
    }
}

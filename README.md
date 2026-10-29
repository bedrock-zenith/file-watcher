# file-watcher

General Purpose implementation of Watching files (currently windows only)

## Example

```zig
const std = @import("std");
const Io = std.Io;

const file_watcher = @import("file_watcher");

pub fn main(init: std.process.Init) !void {
    const dir: std.Io.Dir = try .openDir(.cwd(), init.io, ".", .{
        .iterate = true,
        .access_sub_paths = true,
        .follow_symlinks = false,
    });

    const watcher: file_watcher.Watcher = .init(dir, .{
        .recursive = true,
        .capture = .{
            .FILE_NAME = true,
            .DIR_NAME = true,
            //.SIZE = true,
            .LAST_WRITE = true,
            //.LAST_ACCESS = false,
            .CREATION = true,
            //EA: bool = false,
            //SECURITY: bool = false,
            //STREAM_NAME: bool = false,
            //STREAM_SIZE: bool = false,s
            //STREAM_WRITE: bool = false,
            //Reserved12: u20 = 0,
        },
    });
    var buff: [256]u8 = undefined;
    while (true) {
        const unicode = try watcher.next(&buff);

        std.log.info("here: {s}", .{unicode});
    }
}
```

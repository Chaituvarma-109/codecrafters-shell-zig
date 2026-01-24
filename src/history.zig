const std: type = @import("std");

const Io: type = std.Io;
const mem: type = std.mem;
const fs: type = std.fs;

var last_written_idx: usize = 0;
var hst_arr: std.ArrayList([]u8) = .empty;

pub fn deinit(alloc: mem.Allocator) void {
    for (hst_arr.items) |val| alloc.free(val);
    hst_arr.deinit(alloc);
}

pub fn get_len() !usize {
    return hst_arr.items.len;
}

pub fn get_item_at_index(idx: usize) ![]const u8 {
    return hst_arr.items[idx];
}

pub fn append_hst(alloc: mem.Allocator, cmd: []u8) !void {
    try hst_arr.append(alloc, cmd);
}

pub fn handleHistory(argv: [][]const u8, stdout: *Io.Writer) !void {
    var limit: usize = 1000;
    const hst_len: usize = hst_arr.items.len;
    if (argv.len > 1) {
        limit = @intCast(try std.fmt.parseInt(u32, argv[1], 10));
    }
    const start_idx = @max(0, hst_len - @min(limit, hst_len));

    for (hst_arr.items[start_idx..], start_idx + 0..) |value, i| {
        try stdout.print("{d:>5}  {s}\n", .{ i, value });
    }
    try stdout.flush();
}

pub fn readHistory(alloc: mem.Allocator, hst_file_path: []const u8) !void {
    const bytes: []u8 = try fs.cwd().readFileAlloc(alloc, hst_file_path, std.math.maxInt(usize));
    defer alloc.free(bytes);

    var bytes_iter = mem.splitScalar(u8, bytes, '\n');

    while (bytes_iter.next()) |val| {
        if (val.len == 0) continue;
        const val_dup: []u8 = try alloc.dupe(u8, val);
        hst_arr.append(alloc, val_dup) catch {
            alloc.free(val_dup);
            continue;
        };
    }
}

pub fn writeHistory(hst_file_path: []const u8, append: bool) !void {
    const f = try fs.cwd().createFile(hst_file_path, .{ .truncate = !append });
    defer f.close();

    if (append) try f.seekFromEnd(0);

    var buff: [1024]u8 = undefined;
    var wr = f.writerStreaming(&buff);

    const idx: usize = if (append) last_written_idx else 0;

    for (hst_arr.items[idx..]) |value| {
        try wr.interface.writeAll(value);
        try wr.interface.writeAll("\n");
    }

    try wr.interface.flush();

    last_written_idx = hst_arr.items.len;
}

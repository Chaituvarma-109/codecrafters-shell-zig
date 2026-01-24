const std: type = @import("std");

const mem: type = std.mem;
const posix: type = std.posix;
const fs: type = std.fs;

const consts: type = @import("consts.zig");
const hst: type = @import("history.zig");

const builtins: [6][]const u8 = consts.builtins;

fn enableRawMode(stdin: fs.File) !posix.termios {
    const orig_term: posix.termios = try posix.tcgetattr(stdin.handle);
    var raw: posix.termios = orig_term;

    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;

    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    try posix.tcsetattr(stdin.handle, .FLUSH, raw);

    return orig_term;
}

fn disableRawMode(stdin: fs.File, orig: posix.termios) !void {
    try posix.tcsetattr(stdin.handle, .FLUSH, orig);
}

fn handleCompletions(alloc: mem.Allocator, cmd: []const u8) !std.ArrayList([]const u8) {
    var matches: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (matches.items) |match| alloc.free(match);
        matches.deinit(alloc);
    }

    for (builtins) |value| {
        if (mem.startsWith(u8, value, cmd)) {
            const dup: []u8 = try alloc.dupe(u8, value);
            try matches.append(alloc, dup);
        }
    }

    const paths: [:0]const u8 = posix.getenv("PATH") orelse return matches;
    var path_iter = mem.splitScalar(u8, paths, ':');

    while (path_iter.next()) |dir_path| {
        if (dir_path.len == 0) continue;

        var directory: fs.Dir = try fs.openDirAbsolute(dir_path, .{ .iterate = true });
        defer directory.close();

        var iter = directory.iterate();

        while (iter.next() catch continue) |entry| {
            if (entry.kind == .file or entry.kind == .sym_link) {
                if (mem.startsWith(u8, entry.name, cmd)) {
                    const stat = directory.statFile(entry.name) catch continue;
                    if (stat.mode & 0o111 != 0) {
                        var exists: bool = false;
                        for (matches.items) |value| {
                            if (mem.eql(u8, value, entry.name)) {
                                exists = true;
                                break;
                            }
                        }
                        if (!exists) {
                            const dup: []u8 = alloc.dupe(u8, entry.name) catch continue;
                            matches.append(alloc, dup) catch {
                                alloc.free(dup);
                                continue;
                            };
                        }
                    }
                }
            }
        }
    }

    return matches;
}

fn longestCommonPrefix(matches: [][]const u8) []const u8 {
    if (matches.len == 0) return "";
    if (matches.len == 1) return matches[0];

    const first: []const u8 = matches[0];
    var prefix_len: usize = 0;

    outer: for (first, 0..) |char, i| {
        for (matches[1..]) |str| {
            if (i >= str.len or str[i] != char) {
                break :outer;
            }
        }
        prefix_len = i + 1;
    }

    return first[0..prefix_len];
}

pub fn readline(alloc: mem.Allocator, prompt: []const u8) !?[]const u8 {
    var line_buff: std.ArrayList(u8) = .empty;
    errdefer line_buff.deinit(alloc);

    const infile: fs.File = try fs.cwd().openFile("/dev/tty", .{ .mode = .read_write });
    defer infile.close();

    var buff: [1]u8 = undefined;
    var fr = infile.reader(&buff);
    const r = &fr.interface;

    var wbuff: [1024]u8 = undefined;
    var fwr = infile.writer(&wbuff);
    const stdout = &fwr.interface;

    const term: posix.termios = try enableRawMode(infile);
    defer disableRawMode(infile, term) catch {};

    var tab_count: usize = 0;
    var arr: usize = 0;

    try stdout.writeAll(prompt);
    try stdout.flush();

    while (true) {
        const char: u8 = try r.takeByte();

        switch (char) {
            '[' => {
                const ch: u8 = try r.takeByte();
                switch (ch) {
                    'A' => {
                        const hst_len: usize = try hst.get_len();
                        if (arr < hst_len) {
                            for (line_buff.items) |_| {
                                try stdout.writeAll("\x08 \x08");
                            }

                            line_buff.clearRetainingCapacity();

                            const index: usize = hst_len - arr - 1;
                            const item: []const u8 = try hst.get_item_at_index(index);
                            try stdout.writeAll(" ");
                            try stdout.writeAll(item);
                            try stdout.flush();

                            try line_buff.appendSlice(alloc, item);
                            arr += 1;
                        }
                    },
                    'B' => {
                        const hst_len: usize = try hst.get_len();
                        if (arr > 0) {
                            for (line_buff.items) |_| {
                                try stdout.writeAll("\x08 \x08");
                            }

                            line_buff.clearRetainingCapacity();
                            arr -= 1;

                            if (arr > 0) {
                                const index: usize = hst_len - arr;
                                const item: []const u8 = try hst.get_item_at_index(index);
                                try stdout.writeAll(" ");
                                try stdout.writeAll(item);

                                try line_buff.appendSlice(alloc, item);
                            }

                            try stdout.flush();
                        }
                    },
                    else => {},
                }
            },
            std.ascii.control_code.lf, std.ascii.control_code.cr => {
                try stdout.writeAll("\n");
                try stdout.flush();
                if (line_buff.items.len != 0) {
                    return try line_buff.toOwnedSlice(alloc);
                } else {
                    try stdout.writeAll(prompt);
                    try stdout.flush();
                }
            },
            std.ascii.control_code.ht => {
                tab_count += 1;

                const partials: []u8 = line_buff.items;
                var matches = try handleCompletions(alloc, partials);
                defer {
                    for (matches.items) |m| {
                        alloc.free(m);
                    }
                    matches.deinit(alloc);
                }

                switch (matches.items.len) {
                    0 => {
                        try stdout.writeAll("\x07");
                        try stdout.flush();
                    },
                    1 => {
                        const rem: []const u8 = matches.items[0];

                        try stdout.writeAll(rem[partials.len..]);
                        try stdout.writeAll(" ");
                        try stdout.flush();

                        try line_buff.appendSlice(alloc, rem[partials.len..]);
                        try line_buff.append(alloc, ' ');

                        tab_count = 0;
                    },
                    else => {
                        const lcp: []const u8 = longestCommonPrefix(matches.items);
                        if (lcp.len > partials.len) {
                            const remaining: []const u8 = lcp[partials.len..];

                            try stdout.writeAll(remaining);
                            try stdout.flush();

                            try line_buff.appendSlice(alloc, remaining);
                            tab_count = 0;
                        } else {
                            if (tab_count == 1) {
                                try stdout.writeAll("\x07");
                                try stdout.flush();
                            } else if (tab_count >= 2) {
                                mem.sort([]const u8, matches.items, {}, struct {
                                    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                                        return mem.order(u8, a, b) == .lt;
                                    }
                                }.lessThan);

                                try stdout.writeAll("\n");

                                for (matches.items, 0..) |match, i| {
                                    try stdout.writeAll(match);
                                    if (i < matches.items.len - 1) {
                                        try stdout.writeAll("  ");
                                    }
                                }

                                try stdout.print("\n{s}", .{prompt});
                                try stdout.writeAll(partials);
                                try stdout.flush();

                                tab_count = 0;
                            }
                        }
                    },
                }
            },
            std.ascii.control_code.del, std.ascii.control_code.bs => {
                if (line_buff.items.len > 0) {
                    _ = line_buff.pop();
                    try stdout.writeAll("\x08 \x08");
                    try stdout.flush();
                }
                tab_count = 0;
            },
            32...90, 92...126 => {
                try line_buff.append(alloc, char);
                try stdout.writeAll(&[_]u8{char});
                try stdout.flush();

                tab_count = 0;
            },
            else => {
                try line_buff.append(alloc, char);
                tab_count = 0;
            },
        }
    }
}

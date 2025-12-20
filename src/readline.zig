const std: type = @import("std");
const consts: type = @import("consts.zig");

const builtins = consts.builtins;

fn enableRawMode(stdin: std.fs.File) !std.posix.termios {
    const orig_term = try std.posix.tcgetattr(stdin.handle);
    var raw = orig_term;

    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;

    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

    try std.posix.tcsetattr(stdin.handle, .FLUSH, raw);

    return orig_term;
}

fn disableRawMode(stdin: std.fs.File, orig: std.posix.termios) !void {
    try std.posix.tcsetattr(stdin.handle, .FLUSH, orig);
}

fn handleCompletions(alloc: std.mem.Allocator, cmd: []const u8) !std.ArrayList([]const u8) {
    var matches: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (matches.items) |match| alloc.free(match);
        matches.deinit(alloc);
    }

    for (builtins) |value| {
        if (std.mem.startsWith(u8, value, cmd)) {
            const dup: []u8 = try alloc.dupe(u8, value);
            try matches.append(alloc, dup);
        }
    }

    const paths: [:0]const u8 = std.posix.getenv("PATH") orelse return matches;
    var path_iter = std.mem.splitScalar(u8, paths, ':');

    while (path_iter.next()) |dir_path| {
        if (dir_path.len == 0) continue;

        var directory = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
        defer directory.close();

        var iter = directory.iterate();

        while (iter.next() catch continue) |entry| {
            if (entry.kind == .file or entry.kind == .sym_link) {
                if (std.mem.startsWith(u8, entry.name, cmd)) {
                    const stat = directory.statFile(entry.name) catch continue;
                    if (stat.mode & 0o111 != 0) {
                        var exists: bool = false;
                        for (matches.items) |value| {
                            if (std.mem.eql(u8, value, entry.name)) {
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

pub fn readline(alloc: std.mem.Allocator, hst_lst: std.ArrayList([]u8)) !?[]const u8 {
    const stdout = std.fs.File.stdout();

    var line_buff: std.ArrayList(u8) = .empty;
    errdefer line_buff.deinit(alloc);

    const infile = try std.fs.cwd().openFile("/dev/tty", .{ .mode = .read_write });
    defer infile.close();

    const term = try enableRawMode(infile);
    defer disableRawMode(infile, term) catch {};

    var buff: [1]u8 = undefined;
    var tab_count: usize = 0;
    var arr: usize = 0;

    while (true) {
        const n: usize = try infile.read(&buff);
        if (n == 0) return null;

        const char: u8 = buff[0];

        switch (char) {
            std.ascii.control_code.esc => {
                var buf: [2]u8 = undefined;
                _ = try infile.read(&buf);
                switch (buf[0]) {
                    '[' => {
                        switch (buf[1]) {
                            'A' => {
                                if (arr < hst_lst.items.len) {
                                    for (line_buff.items) |_| {
                                        try stdout.writeAll("\x08 \x08");
                                    }

                                    line_buff.clearRetainingCapacity();

                                    const index: usize = hst_lst.items.len - arr - 1;
                                    try stdout.writeAll(hst_lst.items[index]);

                                    try line_buff.appendSlice(alloc, hst_lst.items[index]);
                                    arr += 1;
                                }
                            },
                            'B' => {
                                if (arr > 0) {
                                    for (line_buff.items) |_| {
                                        try stdout.writeAll("\x08 \x08");
                                    }

                                    line_buff.clearRetainingCapacity();
                                    arr -= 1;

                                    if (arr > 0) {
                                        const index: usize = hst_lst.items.len - arr;
                                        try stdout.writeAll(hst_lst.items[index]);

                                        try line_buff.appendSlice(alloc, hst_lst.items[index]);
                                    }
                                }
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            },
            std.ascii.control_code.lf, std.ascii.control_code.cr => {
                try stdout.writeAll("\n");
                return try line_buff.toOwnedSlice(alloc);
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
                    0 => try stdout.writeAll("\x07"),
                    1 => {
                        const rem: []const u8 = matches.items[0];

                        try stdout.writeAll(rem[partials.len..]);
                        try stdout.writeAll(" ");

                        try line_buff.appendSlice(alloc, rem[partials.len..]);
                        try line_buff.append(alloc, ' ');

                        tab_count = 0;
                    },
                    else => {
                        const lcp: []const u8 = longestCommonPrefix(matches.items);
                        if (lcp.len > partials.len) {
                            const remaining: []const u8 = lcp[partials.len..];

                            try stdout.writeAll(remaining);

                            try line_buff.appendSlice(alloc, remaining);
                            tab_count = 0;
                        } else {
                            if (tab_count == 1) {
                                try stdout.writeAll("\x07");
                            } else if (tab_count >= 2) {
                                std.mem.sort([]const u8, matches.items, {}, struct {
                                    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                                        return std.mem.order(u8, a, b) == .lt;
                                    }
                                }.lessThan);

                                try stdout.writeAll("\n");

                                for (matches.items, 0..) |match, i| {
                                    try stdout.writeAll(match);
                                    if (i < matches.items.len - 1) {
                                        try stdout.writeAll("  ");
                                    }
                                }

                                try stdout.writeAll("\n$ ");
                                try stdout.writeAll(partials);

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
                }
                tab_count = 0;
            },
            32...126 => {
                try line_buff.append(alloc, char);
                try stdout.writeAll(&[_]u8{char});

                tab_count = 0;
            },
            else => {
                try line_buff.append(alloc, char);
                tab_count = 0;
            },
        }
    }
}

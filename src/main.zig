const std = @import("std");
const clib = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("readline/readline.h");
});

const builtins = [_][]const u8{ "exit", "echo", "type", "pwd" };

pub fn main() !void {
    // Uncomment this block to pass the first stage
    const stdout = std.io.getStdOut().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const buff = try alloc.alloc(u8, 1024);
    defer alloc.free(buff);

    completion_path = std.posix.getenv("PATH");
    clib.rl_attempted_completion_function = &completion;

    // defer {
    //     if (gpa.detectLeaks()) {
    //         std.debug.print("Memory leak detected!\n", .{});
    //     } else {
    //         std.debug.print("No leaks!\n", .{});
    //     }
    // }

    while (true) {
        // try stdout.print("$ ", .{});
        // const stdin = std.io.getStdIn().reader();
        const line = clib.readline("$ ");
        defer clib.free(line);
        const ln_len = std.mem.len(line);
        const user_input: []u8 = line[0..ln_len];

        const cmds = try parse_inp(alloc, user_input);
        defer {
            for (cmds) |cmd| {
                alloc.free(cmd);
            }
            alloc.free(cmds);
        }

        var index: ?usize = null;
        var target: u8 = 1;
        var append = false;

        for (cmds, 0..) |cm, i| {
            if (std.mem.eql(u8, cm, ">") or std.mem.eql(u8, cm, "1>") or std.mem.eql(u8, cm, "2>")) {
                index = i;
                if (cm.len == 2) {
                    target = cm[0] - '0';
                }
                break;
            }

            if (std.mem.eql(u8, cm, ">>") or std.mem.eql(u8, cm, "1>>") or std.mem.eql(u8, cm, "2>>")) {
                append = true;
                index = i;
                if (cm.len == 3) {
                    target = cm[0] - '0';
                }
                break;
            }
        }

        var outf: ?std.fs.File = null;
        var errf: ?std.fs.File = null;
        var out = stdout;
        var argv = cmds;

        if (index) |ind| {
            argv = cmds[0..ind];
            if (target == 1) {
                outf = try std.fs.cwd().createFile(cmds[ind + 1], .{ .truncate = !append });

                if (outf) |file| {
                    if (append) try file.seekFromEnd(0);

                    out = file.writer();
                }
            } else {
                errf = try std.fs.cwd().createFile(cmds[ind + 1], .{ .truncate = !append });

                if (errf) |file| {
                    if (append) try file.seekFromEnd(0);
                }
            }
        }

        defer if (outf) |file| file.close();
        defer if (errf) |file| file.close();

        // std.debug.print("index: {d}\ntarget: {any}\n", .{ index, target });

        const cmd = argv[0];

        if (std.mem.eql(u8, cmd, "exit")) {
            std.posix.exit(0);
        } else if (std.mem.eql(u8, cmd, "cd")) {
            const home: []const u8 = "HOME";
            var arg: []const u8 = argv[1];
            if (std.mem.eql(u8, argv[1], "~")) {
                arg = std.posix.getenv(home) orelse "";
            }
            std.posix.chdir(arg) catch {
                try stdout.print("cd: {s}: No such file or directory\n", .{arg});
            };
        } else if (std.mem.eql(u8, cmd, "pwd")) {
            const pwd = try std.process.getCwd(buff);

            try stdout.print("{s}\n", .{pwd});
        } else if (std.mem.eql(u8, cmd, "echo")) {
            if (argv.len < 2) return;
            for (argv[1 .. argv.len - 1]) |arg| {
                try out.print("{s} ", .{arg});
            }
            try out.print("{s}\n", .{argv[argv.len - 1]});
        } else if (std.mem.eql(u8, cmd, "type")) {
            var found: bool = false;
            const args = argv[1];
            for (builtins) |builtin| {
                if (std.mem.eql(u8, builtin, args)) {
                    try stdout.print("{s} is a shell builtin\n", .{args});
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (try typeBuilt(args, buff)) |p| {
                    try stdout.print("{s} is {s}\n", .{ args, p });
                } else {
                    try stdout.print("{s}: not found\n", .{args});
                }
            }
        } else {
            if (try typeBuilt(cmd, buff)) |_| {
                // var argv = std.ArrayList([]const u8).init(alloc);
                // defer argv.deinit();

                // for (cmds) |arg| {
                //     try argv.append(arg);
                // }

                var res = std.process.Child.init(argv, alloc);
                res.stdin_behavior = .Inherit;
                res.stdout_behavior = .Inherit;
                res.stderr_behavior = .Inherit;

                if (outf) |file| {
                    res.stdout_behavior = .Pipe;
                    try res.spawn();

                    try file.writeFileAllUnseekable(res.stdout.?, .{});
                } else if (errf) |file| {
                    res.stderr_behavior = .Pipe;

                    try res.spawn();

                    try file.writeFileAllUnseekable(res.stderr.?, .{});
                } else {
                    res.stdout_behavior = .Inherit;

                    try res.spawn();
                }
                // defer {
                //     alloc.free(res.stdout);
                //     alloc.free(res.stderr);
                // }
                // try stdout.print("{s}", .{res.stdout});
                _ = try res.wait();
            } else {
                try stdout.print("{s}: command not found\n", .{cmd});
            }
        }
    }
}

fn typeBuilt(args: []const u8, buff: []u8) !?[]const u8 {
    const env_path = std.posix.getenv("PATH");
    var folders = std.mem.tokenizeAny(u8, env_path.?, ":");

    while (folders.next()) |folder| {
        const full_path = try std.fmt.bufPrint(buff, "{s}/{s}", .{ folder, args });
        std.fs.accessAbsolute(full_path, .{ .mode = .read_only }) catch continue;
        return full_path;
    }

    return null;
}

fn parse_inp(alloc: std.mem.Allocator, args: []const u8) ![][]const u8 {
    var tokens = std.ArrayList([]const u8).init(alloc);
    defer tokens.deinit();

    var pos: usize = 0;
    while (pos < args.len) {
        if (args[pos] == ' ') {
            pos += 1;
            continue;
        }

        var token = std.ArrayList(u8).init(alloc);
        defer token.deinit();
        while (pos < args.len and args[pos] != ' ') {
            switch (args[pos]) {
                '\'', '"' => {
                    const quote = args[pos];
                    pos += 1;

                    while (args[pos] != quote) {
                        if (quote == '"' and args[pos] == '\\' and switch (args[pos + 1]) {
                            '"', '\\', '$', '\n' => true,
                            else => false,
                        }) {
                            pos += 1;
                        }
                        try token.append(args[pos]);
                        pos += 1;
                    }
                    if (pos < args.len) pos += 1;
                },

                '\\' => {
                    try token.append(args[pos + 1]);
                    pos += 2;
                },

                else => {
                    try token.append(args[pos]);
                    pos += 1;
                },
            }
        }
        if (token.items.len > 0) {
            try tokens.append(try token.toOwnedSlice());
        }
    }

    return try tokens.toOwnedSlice();
}

fn completion(text: [*c]const u8, start: c_int, _: c_int) callconv(.c) [*c][*c]u8 {
    var matches: [*c][*c]u8 = null;

    if (start == 0) {
        matches = clib.rl_completion_matches(text, &custom_completion);
    }
    return matches;
}

var completion_index: usize = undefined;
var text_len: usize = undefined;
var completion_path: ?[]const u8 = null; // To be assigned the value of $PATH
var path_iterator: ?std.mem.TokenIterator(u8, .scalar) = null;
var dir_iterator: ?std.fs.Dir.Iterator = null;
var iteration: enum {
    None,
    Builtins,
    Path,
} = .None;
// var Builtins = true;
fn custom_completion(text: [*c]const u8, state: c_int) callconv(.c) [*c]u8 {
    if (state == 0) {
        completion_index = 0;
        text_len = std.mem.len(text);
        iteration = .Builtins;
    }

    const txt = text[0..text_len];

    if (iteration == .Builtins) {
        while (completion_index < builtins.len) {
            const builtin_name = builtins[completion_index];
            completion_index += 1;

            if (std.mem.startsWith(u8, builtin_name, txt)) {
                return clib.strdup(builtin_name.ptr);
            }
        }
        // Builtins = false;
        if (completion_path == null) {
            iteration = .None;
        } else {
            iteration = .Path;

            path_iterator = std.mem.tokenizeScalar(u8, completion_path.?, ':');
        }
    }

    // if (!Builtins) {
    //     const env_path = std.posix.getenv("PATH");
    //     var path_iter = std.mem.tokenizeAny(u8, env_path.?, ":");
    //     const ztext: []const u8 = std.mem.span(text);

    //     while (path_iter.next()) |path| {
    //         var buf: [std.fs.max_path_bytes]u8 = undefined;
    //         const full_path = std.fmt.bufPrint(buf[0..], "{s}/{s}", .{ path, ztext }) catch continue;
    //         // const p = std.fs.realpath(path, &buf) catch continue;
    //         // std.debug.print("p: {s}\n", .{p});
    //         std.fs.accessAbsolute(full_path, .{ .mode = .read_only }) catch continue;
    //         // std.debug.print("accessAbsolute path: {s}\n", .{full_path});
    //         const dir = std.fs.openDirAbsolute(full_path, .{ .iterate = true }) catch continue;
    //         dir_iterator = dir.iterate();
    //         // continue :again;
    //         while (dir_iterator.?.next() catch unreachable) |entry| {
    //             // std.debug.print("dir: {s}\n", .{entry.name});
    //             switch (entry.kind) {
    //                 .file => {
    //                     // std.debug.print("entry name ptr: {s}\n", .{entry.name});
    //                     if (std.mem.eql(u8, entry.name, txt)) {
    //                         return clib.strdup(entry.name.ptr);
    //                     }
    //                 },

    //                 else => continue,
    //             }
    //         }
    //     }
    // }
    again: while (iteration == .Path) {
        if (dir_iterator == null) {
            if (path_iterator.?.next()) |path| {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const p = std.fs.realpath(path, &buf) catch continue :again;
                const dir = std.fs.openDirAbsolute(p, .{ .iterate = true }) catch continue :again;
                dir_iterator = dir.iterate();
                continue :again;
            } else {
                iteration = .None;

                path_iterator = null;

                break :again;
            }
        }

        while (dir_iterator.?.next() catch unreachable) |entry| {
            switch (entry.kind) {
                .file => {
                    if (std.mem.startsWith(u8, entry.name, txt))
                        return clib.strdup(entry.name.ptr);
                },

                else => continue,
            }
        } else {
            dir_iterator = null;
        }
    }

    return null;
}

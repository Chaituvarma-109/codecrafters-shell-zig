const std: type = @import("std");
const rdln: type = @import("readline.zig");
const consts: type = @import("consts.zig");

const builtins: [6][]const u8 = consts.builtins;
var completion_path: ?[]const u8 = null;
var home: ?[]const u8 = null;
var histfile: ?[]const u8 = null;
var paths_arr: std.ArrayList([]const u8) = undefined;
var last_written_idx: usize = 0;

const ParsedRedirect: type = struct {
    index: usize,
    fd_target: u8,
    filename: []const u8,
    append: bool,

    fn parsedredirect(cmds: [][]const u8) !?ParsedRedirect {
        for (cmds, 0..) |cm, i| {
            if (i + 1 >= cmds.len) return null;
            if (std.mem.eql(u8, cm, ">") or std.mem.eql(u8, cm, "1>")) {
                return ParsedRedirect{
                    .index = i,
                    .fd_target = 1,
                    .filename = cmds[i + 1],
                    .append = false,
                };
            }
            if (std.mem.eql(u8, cm, "2>")) {
                return ParsedRedirect{
                    .index = i,
                    .fd_target = 2,
                    .filename = cmds[i + 1],
                    .append = false,
                };
            }
            if (std.mem.eql(u8, cm, ">>") or std.mem.eql(u8, cm, "1>>")) {
                return ParsedRedirect{
                    .index = i,
                    .fd_target = 1,
                    .filename = cmds[i + 1],
                    .append = true,
                };
            }
            if (std.mem.eql(u8, cm, "2>>")) {
                return ParsedRedirect{
                    .index = i,
                    .fd_target = 2,
                    .filename = cmds[i + 1],
                    .append = true,
                };
            }
        }

        return null;
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const alloc: std.mem.Allocator = gpa.allocator();
    defer {
        const chk: std.heap.Check = gpa.deinit();
        if (chk == .leak) std.debug.print("memory leaked\n", .{});
    }

    const buff: []u8 = try alloc.alloc(u8, 1024);
    defer alloc.free(buff);

    var wbuf: [1024]u8 = undefined;
    const stdout_f = std.fs.File.stdout();
    var stdout_writer = stdout_f.writerStreaming(&wbuf);
    const stdout = &stdout_writer.interface;

    completion_path = std.posix.getenv("PATH");
    home = std.posix.getenv("HOME");

    paths_arr = .empty;
    defer {
        for (paths_arr.items) |path| {
            alloc.free(path);
        }
        paths_arr.deinit(alloc);
    }
    var paths_iter = std.mem.tokenizeAny(u8, completion_path.?, ":");
    while (paths_iter.next()) |path| {
        const path_copy: []u8 = try alloc.dupe(u8, path);
        errdefer alloc.free(path_copy);
        try paths_arr.append(alloc, path_copy);
    }

    histfile = std.posix.getenv("HISTFILE");

    var hst_arr: std.ArrayList([]u8) = .empty;
    defer {
        for (hst_arr.items) |value| {
            alloc.free(value);
        }
        hst_arr.deinit(alloc);
    }

    if (histfile) |file| {
        try readHistory(alloc, file, &hst_arr);
    }

    while (true) {
        const ln: []const u8 = try rdln.readline(alloc, hst_arr, "$ ") orelse unreachable;
        defer alloc.free(ln);

        const line: []u8 = try alloc.dupe(u8, ln);
        try hst_arr.append(alloc, line);

        if (std.mem.count(u8, ln, "|") > 0) {
            try executePipeCmds(alloc, ln, buff, stdout, &hst_arr);
            continue;
        }

        const parsed_cmds: [][]const u8 = try parseInp(alloc, ln); // { echo, Hello Maria, 1>, /tmp/foo/baz.md }
        defer {
            for (parsed_cmds) |cmd| {
                alloc.free(cmd);
            }
            alloc.free(parsed_cmds);
        }

        const redirect: ?ParsedRedirect = try .parsedredirect(parsed_cmds);
        const argv: [][]const u8 = if (redirect) |r| parsed_cmds[0..r.index] else parsed_cmds;

        const cmd: []const u8 = argv[0];

        if (redirect) |redir| {
            try executeWithRedirection(alloc, cmd, argv, redir, buff, stdout, &hst_arr);
        } else {
            const is_builtin: bool = try checkbuiltIn(cmd);

            if (is_builtin) {
                try executeBuiltin(alloc, cmd, argv, buff, stdout, &hst_arr);
            } else {
                if (try typeBuilt(cmd, buff, false)) |_| {
                    var res = std.process.Child.init(argv, alloc);
                    res.stdin_behavior = .Inherit;
                    res.stdout_behavior = .Inherit;
                    res.stderr_behavior = .Inherit;
                    try res.spawn();
                    _ = try res.wait();
                } else {
                    try stdout.print("{s}: command not found\n", .{cmd});
                    try stdout.flush();
                }
            }
        }
    }
}

fn parseInp(alloc: std.mem.Allocator, inp: []const u8) ![][]const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(alloc);

    var pos: usize = 0;

    while (pos < inp.len) {
        if (inp[pos] == ' ') {
            pos += 1;
            continue;
        }

        var token: std.ArrayList(u8) = .empty;
        defer token.deinit(alloc);
        while (pos < inp.len and inp[pos] != ' ') {
            switch (inp[pos]) {
                '\'', '"' => {
                    const quote: u8 = inp[pos];
                    pos += 1;

                    while (inp[pos] != quote) {
                        if (quote == '"' and inp[pos] == '\\' and switch (inp[pos + 1]) {
                            '"', '\\', '$', '\n' => true,
                            else => false,
                        }) {
                            pos += 1;
                        }
                        try token.append(alloc, inp[pos]);
                        pos += 1;
                    }
                    if (pos < inp.len) pos += 1;
                },
                '\\' => {
                    try token.append(alloc, inp[pos + 1]);
                    pos += 2;
                },
                else => {
                    try token.append(alloc, inp[pos]);
                    pos += 1;
                },
            }
        }
        if (token.items.len > 0) {
            try tokens.append(alloc, try token.toOwnedSlice(alloc));
        }
    }

    return tokens.toOwnedSlice(alloc);
}

fn executePipeCmds(alloc: std.mem.Allocator, inp: []const u8, buff: []u8, stdout: *std.Io.Writer, hst_arr: *std.ArrayList([]u8)) !void {
    var commands: std.ArrayList([]const u8) = .empty;
    defer commands.deinit(alloc);

    var cmd_iter = std.mem.splitScalar(u8, inp, '|');
    while (cmd_iter.next()) |cmd| {
        const trimmed_cmd: []const u8 = std.mem.trim(u8, cmd, " \t\r\n");
        try commands.append(alloc, trimmed_cmd);
    }

    if (commands.items.len == 0) return;

    // Multiple commands with pipes
    const pipes_count: usize = commands.items.len - 1;
    var pipes = try alloc.alloc([2]std.posix.fd_t, pipes_count);
    defer alloc.free(pipes);

    // Create all pipes
    for (0..pipes_count) |i| {
        const new_pipe = try std.posix.pipe();
        pipes[i][0] = new_pipe[0];
        pipes[i][1] = new_pipe[1];
    }

    var pids = try alloc.alloc(std.posix.pid_t, commands.items.len);
    defer alloc.free(pids);

    for (commands.items, 0..) |cmd_str, i| {
        // changed from parseCommand to parseInp function.
        const args: [][]const u8 = try parseInp(alloc, cmd_str);
        defer {
            for (args) |arg| {
                alloc.free(arg);
            }
            alloc.free(args);
        }

        if (args.len == 0) continue;
        const cmd: []const u8 = args[0];

        // Check if this is a builtin command
        const is_builtin: bool = try checkbuiltIn(cmd);

        // Fork a process for both external commands and builtins
        // This ensures consistent pipeline behavior
        const pid = try std.posix.fork();

        if (pid == 0) {
            // Child process

            // Set up input from previous command if not first command
            if (i > 0) {
                try std.posix.dup2(pipes[i - 1][0], std.posix.STDIN_FILENO);
            }

            // Set up output to next command if not last command
            if (i < commands.items.len - 1) {
                try std.posix.dup2(pipes[i][1], std.posix.STDOUT_FILENO);
            }

            // Close all pipe file descriptors in child
            for (0..pipes_count) |j| {
                std.posix.close(pipes[j][0]);
                std.posix.close(pipes[j][1]);
            }

            // Execute the builtin commands
            if (is_builtin) {
                try executeBuiltin(alloc, cmd, args, buff, stdout, hst_arr);

                try stdout.flush();
                std.posix.exit(0);
            } else {
                // Execute external command
                const exec_error = std.process.execv(alloc, args);
                if (exec_error != error.Success) {
                    std.debug.print("execv failed for {s}: {}\n", .{ cmd, exec_error });
                    std.posix.exit(1);
                }
            }
        } else {
            // Parent process
            pids[i] = pid;
        }
    }

    // Close all pipe ends in the parent
    for (pipes) |pipe| {
        std.posix.close(pipe[0]);
        std.posix.close(pipe[1]);
    }

    // Wait for all child processes
    for (pids) |pid| {
        _ = std.posix.waitpid(pid, 0);
    }
}

fn checkbuiltIn(cmd: []const u8) !bool {
    for (builtins) |builtin| {
        if (std.mem.eql(u8, builtin, cmd)) {
            return true;
        }
    }
    return false;
}

fn executeWithRedirection(alloc: std.mem.Allocator, cmd: []const u8, argv: [][]const u8, redir: ParsedRedirect, buff: []u8, stdout: *std.Io.Writer, hst_arr: *std.ArrayList([]u8)) !void {
    // Create directory if needed
    if (std.fs.path.dirname(redir.filename)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                return;
            }
        };
    }

    // Open file with appropriate flags
    const flags: std.posix.O = if (redir.append)
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }
    else
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };

    const fd = std.posix.open(redir.filename, flags, 0o666) catch |err| {
        try stdout.print("Failed to open {s}: {}\n", .{ redir.filename, err });
        try stdout.flush();
        return;
    };
    defer std.posix.close(fd);

    // Check if it's a builtin
    const is_builtin: bool = try checkbuiltIn(cmd);

    const pid = try std.posix.fork();

    if (is_builtin) {
        // For builtins, use fork to redirect output
        if (pid == 0) {
            // Child process
            if (redir.fd_target == 1) {
                try std.posix.dup2(fd, std.posix.STDOUT_FILENO);
            } else {
                try std.posix.dup2(fd, std.posix.STDERR_FILENO);
            }

            executeBuiltin(alloc, cmd, argv, buff, stdout, hst_arr) catch {};
            std.posix.exit(0);
        } else {
            // Parent process
            _ = std.posix.waitpid(pid, 0);
        }
    } else {
        // For external commands, use fork + exec
        _ = try typeBuilt(cmd, buff, true) orelse {
            try stdout.print("{s}: command not found\n", .{cmd});
            try stdout.flush();
            return;
        };

        if (pid == 0) {
            // Child process
            if (redir.fd_target == 1) {
                try std.posix.dup2(fd, std.posix.STDOUT_FILENO);
            } else {
                try std.posix.dup2(fd, std.posix.STDERR_FILENO);
            }

            const exec_error: std.process.ExecvError = std.process.execv(alloc, argv);
            try stdout.print("execv failed: {}\n", .{exec_error});
            try stdout.flush();
            std.posix.exit(1);
        } else {
            // Parent process
            _ = std.posix.waitpid(pid, 0);
        }
    }
    try stdout.flush();
}

fn executeBuiltin(alloc: std.mem.Allocator, cmd: []const u8, argv: [][]const u8, buff: []u8, stdout: *std.Io.Writer, hst_lst: *std.ArrayList([]u8)) !void {
    const append = false;
    if (std.mem.eql(u8, cmd, "exit")) {
        if (histfile) |file| {
            try writeHistory(file, hst_lst, append);
        }
        std.posix.exit(0);
    } else if (std.mem.eql(u8, cmd, "cd")) {
        var arg: []const u8 = argv[1];
        if (std.mem.eql(u8, argv[1], "~")) arg = home orelse "";

        std.posix.chdir(arg) catch {
            try stdout.print("{s}: No such file or directory\n", .{arg});
            try stdout.flush();
        };
    } else if (std.mem.eql(u8, cmd, "pwd")) {
        var pbuff: [std.fs.max_path_bytes]u8 = undefined;
        const cwd: []u8 = try std.process.getCwd(&pbuff);
        try stdout.print("{s}\n", .{cwd});
        try stdout.flush();
    } else if (std.mem.eql(u8, cmd, "echo")) {
        try handleEcho(argv, stdout);
    } else if (std.mem.eql(u8, cmd, "type")) {
        try handleType(buff, argv, stdout);
    } else if (std.mem.eql(u8, cmd, "history")) {
        if (argv.len == 3) {
            const arg: []const u8 = argv[1];
            const val: []const u8 = argv[2];

            if (std.mem.eql(u8, arg, "-r")) {
                // Read history from a file.
                try readHistory(alloc, val, hst_lst);
            } else if (std.mem.eql(u8, arg, "-w")) {
                // Write history to file.
                try writeHistory(val, hst_lst, append);
            } else if (std.mem.eql(u8, arg, "-a")) {
                // append history to a file.
                try writeHistory(val, hst_lst, !append);
            }
        } else {
            try handleHistory(argv, stdout, hst_lst);
        }
    }
}

fn typeBuilt(args: []const u8, buff: []u8, only_exec: bool) !?[]const u8 {
    for (paths_arr.items) |path| {
        const full_path: []u8 = try std.fmt.bufPrint(buff, "{s}/{s}", .{ path, args });

        if (only_exec) {
            std.posix.faccessat(std.os.linux.AT.FDCWD, full_path, std.os.linux.X_OK, 0) catch continue;
            return full_path;
        } else {
            std.fs.accessAbsolute(full_path, .{}) catch continue;
            return full_path;
        }
    }

    return null;
}

fn handleEcho(argv: [][]const u8, stdout: *std.Io.Writer) !void {
    if (argv.len < 2) return;
    for (argv[1 .. argv.len - 1]) |arg| {
        try stdout.print("{s} ", .{arg});
    }
    try stdout.print("{s}\n", .{argv[argv.len - 1]});
    try stdout.flush();
}

fn handleType(buff: []u8, argv: [][]const u8, stdout: *std.Io.Writer) !void {
    var found: bool = false;
    const cmd: []const u8 = argv[1];
    for (builtins) |builtin| {
        if (std.mem.eql(u8, builtin, cmd)) {
            try stdout.print("{s} is a shell builtin\n", .{cmd});
            found = true;
            break;
        }
    }
    if (!found) {
        if (try typeBuilt(cmd, buff, true)) |p| {
            try stdout.print("{s} is {s}\n", .{ cmd, p });
        } else {
            try stdout.print("{s}: not found\n", .{cmd});
        }
    }

    try stdout.flush();
}

fn handleHistory(argv: [][]const u8, stdout: *std.Io.Writer, hst_arr: *std.ArrayList([]u8)) !void {
    var limit: usize = 1000;
    const hst_len = hst_arr.items.len;
    if (argv.len > 1) {
        limit = @intCast(try std.fmt.parseInt(u32, argv[1], 10));
    }
    const start_idx = @max(0, hst_len - @min(limit, hst_len));

    for (hst_arr.items[start_idx..], start_idx + 0..) |value, i| {
        try stdout.print("{d:>5}  {s}\n", .{ i, value });
    }
    try stdout.flush();
}

fn readHistory(alloc: std.mem.Allocator, hst_file_path: []const u8, hst_lst: *std.ArrayList([]u8)) !void {
    const bytes = try std.fs.cwd().readFileAlloc(alloc, hst_file_path, std.math.maxInt(usize));
    defer alloc.free(bytes);

    var bytes_iter = std.mem.splitScalar(u8, bytes, '\n');

    while (bytes_iter.next()) |val| {
        if (val.len == 0) continue;
        const val_dup = try alloc.dupe(u8, val);
        hst_lst.append(alloc, val_dup) catch {
            alloc.free(val_dup);
            continue;
        };
    }
}

fn writeHistory(hst_file_path: []const u8, hst_lst: *std.ArrayList([]u8), append: bool) !void {
    const f = try std.fs.cwd().createFile(hst_file_path, .{ .truncate = !append });
    defer f.close();

    if (append) try f.seekFromEnd(0);

    var buff: [1024]u8 = undefined;
    var wr = f.writerStreaming(&buff);

    const idx: usize = if (append) last_written_idx else 0;

    for (hst_lst.items[idx..]) |value| {
        try wr.interface.writeAll(value);
        try wr.interface.writeAll("\n");
    }

    try wr.interface.flush();

    last_written_idx = hst_lst.items.len;
}

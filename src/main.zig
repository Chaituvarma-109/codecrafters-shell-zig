const std: type = @import("std");

const posix: type = std.posix;
const mem: type = std.mem;
const fs: type = std.fs;
const Io: type = std.Io;

const rdln: type = @import("readline.zig");
const hst: type = @import("history.zig");
const consts: type = @import("consts.zig");

const builtins: [6][]const u8 = consts.builtins;
var completion_path: ?[]const u8 = null;
var home: ?[]const u8 = null;
var histfile: ?[]const u8 = null;
var paths_arr: std.ArrayList([]const u8) = undefined;

const ParsedRedirect: type = struct {
    index: usize,
    fd_target: u8,
    filename: []const u8,
    append: bool,

    fn parsedredirect(cmds: [][]const u8) !?ParsedRedirect {
        for (cmds, 0..) |cm, i| {
            if (i + 1 >= cmds.len) return null;
            if (mem.eql(u8, cm, ">") or mem.eql(u8, cm, "1>")) {
                return ParsedRedirect{
                    .index = i,
                    .fd_target = 1,
                    .filename = cmds[i + 1],
                    .append = false,
                };
            }
            if (mem.eql(u8, cm, "2>")) {
                return ParsedRedirect{
                    .index = i,
                    .fd_target = 2,
                    .filename = cmds[i + 1],
                    .append = false,
                };
            }
            if (mem.eql(u8, cm, ">>") or mem.eql(u8, cm, "1>>")) {
                return ParsedRedirect{
                    .index = i,
                    .fd_target = 1,
                    .filename = cmds[i + 1],
                    .append = true,
                };
            }
            if (mem.eql(u8, cm, "2>>")) {
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
    const alloc: mem.Allocator = gpa.allocator();
    defer {
        const chk: std.heap.Check = gpa.deinit();
        if (chk == .leak) std.debug.print("memory leaked\n", .{});
    }

    const buff: []u8 = try alloc.alloc(u8, 1024);
    defer alloc.free(buff);

    var wbuf: [1024]u8 = undefined;
    const stdout_f = fs.File.stdout();
    var stdout_writer = stdout_f.writerStreaming(&wbuf);
    const stdout = &stdout_writer.interface;

    completion_path = posix.getenv("PATH");
    home = posix.getenv("HOME");

    paths_arr = .empty;
    defer {
        for (paths_arr.items) |path| {
            alloc.free(path);
        }
        paths_arr.deinit(alloc);
    }
    var paths_iter = mem.tokenizeAny(u8, completion_path.?, ":");
    while (paths_iter.next()) |path| {
        const path_copy: []u8 = try alloc.dupe(u8, path);
        errdefer alloc.free(path_copy);
        try paths_arr.append(alloc, path_copy);
    }

    histfile = posix.getenv("HISTFILE");

    if (histfile) |file| {
        try hst.readHistory(alloc, file);
    }

    while (true) {
        const ln: []const u8 = try rdln.readline(alloc, "$ ") orelse unreachable;
        defer alloc.free(ln);

        const line: []u8 = try alloc.dupe(u8, ln);
        try hst.append_hst(alloc, line);

        if (mem.count(u8, ln, "|") > 0) {
            try executePipeCmds(alloc, ln, buff, stdout);
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
            try executeWithRedirection(alloc, cmd, argv, redir, buff, stdout);
        } else {
            const is_builtin: bool = try checkbuiltIn(cmd);

            if (is_builtin) {
                try executeBuiltin(alloc, cmd, argv, buff, stdout);
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

fn parseInp(alloc: mem.Allocator, inp: []const u8) ![][]const u8 {
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

fn executePipeCmds(alloc: mem.Allocator, inp: []const u8, buff: []u8, stdout: *Io.Writer) !void {
    var commands: std.ArrayList([]const u8) = .empty;
    defer commands.deinit(alloc);

    var cmd_iter = mem.splitScalar(u8, inp, '|');
    while (cmd_iter.next()) |cmd| {
        const trimmed_cmd: []const u8 = mem.trim(u8, cmd, " \t\r\n");
        try commands.append(alloc, trimmed_cmd);
    }

    if (commands.items.len == 0) return;

    // Multiple commands with pipes
    const pipes_count: usize = commands.items.len - 1;
    var pipes = try alloc.alloc([2]posix.fd_t, pipes_count);
    defer alloc.free(pipes);

    // Create all pipes
    for (0..pipes_count) |i| {
        const new_pipe = try posix.pipe();
        pipes[i][0] = new_pipe[0];
        pipes[i][1] = new_pipe[1];
    }

    var pids = try alloc.alloc(posix.pid_t, commands.items.len);
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
        const pid: posix.pid_t = try posix.fork();

        if (pid == 0) {
            // Child process

            // Set up input from previous command if not first command
            if (i > 0) {
                try posix.dup2(pipes[i - 1][0], posix.STDIN_FILENO);
            }

            // Set up output to next command if not last command
            if (i < commands.items.len - 1) {
                try posix.dup2(pipes[i][1], posix.STDOUT_FILENO);
            }

            // Close all pipe file descriptors in child
            for (0..pipes_count) |j| {
                posix.close(pipes[j][0]);
                posix.close(pipes[j][1]);
            }

            // Execute the builtin commands
            if (is_builtin) {
                try executeBuiltin(alloc, cmd, args, buff, stdout);

                try stdout.flush();
                posix.exit(0);
            } else {
                // Execute external command
                const exec_error = std.process.execv(alloc, args);
                if (exec_error != error.Success) {
                    std.debug.print("execv failed for {s}: {}\n", .{ cmd, exec_error });
                    posix.exit(1);
                }
            }
        } else {
            // Parent process
            pids[i] = pid;
        }
    }

    // Close all pipe ends in the parent
    for (pipes) |pipe| {
        posix.close(pipe[0]);
        posix.close(pipe[1]);
    }

    // Wait for all child processes
    for (pids) |pid| {
        _ = posix.waitpid(pid, 0);
    }
}

fn checkbuiltIn(cmd: []const u8) !bool {
    for (builtins) |builtin| {
        if (mem.eql(u8, builtin, cmd)) {
            return true;
        }
    }
    return false;
}

fn executeWithRedirection(alloc: mem.Allocator, cmd: []const u8, argv: [][]const u8, redir: ParsedRedirect, buff: []u8, stdout: *Io.Writer) !void {
    // Create directory if needed
    if (fs.path.dirname(redir.filename)) |dir| {
        fs.cwd().makePath(dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                return;
            }
        };
    }

    // Open file with appropriate flags
    const flags: posix.O = if (redir.append)
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }
    else
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };

    const fd: posix.fd_t = posix.open(redir.filename, flags, 0o666) catch |err| {
        try stdout.print("Failed to open {s}: {}\n", .{ redir.filename, err });
        try stdout.flush();
        return;
    };
    defer posix.close(fd);

    // Check if it's a builtin
    const is_builtin: bool = try checkbuiltIn(cmd);

    const pid: posix.pid_t = try posix.fork();

    if (is_builtin) {
        // For builtins, use fork to redirect output
        if (pid == 0) {
            // Child process
            if (redir.fd_target == 1) {
                try posix.dup2(fd, posix.STDOUT_FILENO);
            } else {
                try posix.dup2(fd, posix.STDERR_FILENO);
            }

            executeBuiltin(alloc, cmd, argv, buff, stdout) catch {};
            posix.exit(0);
        } else {
            // Parent process
            _ = posix.waitpid(pid, 0);
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
                try posix.dup2(fd, posix.STDOUT_FILENO);
            } else {
                try posix.dup2(fd, posix.STDERR_FILENO);
            }

            const exec_error: std.process.ExecvError = std.process.execv(alloc, argv);
            try stdout.print("execv failed: {}\n", .{exec_error});
            try stdout.flush();
            posix.exit(1);
        } else {
            // Parent process
            _ = posix.waitpid(pid, 0);
        }
    }
    try stdout.flush();
}

fn executeBuiltin(alloc: mem.Allocator, cmd: []const u8, argv: [][]const u8, buff: []u8, stdout: *Io.Writer) !void {
    const append: bool = false;
    if (mem.eql(u8, cmd, "exit")) {
        if (histfile) |file| {
            try hst.writeHistory(file, append);
        }
        posix.exit(0);
    } else if (mem.eql(u8, cmd, "cd")) {
        var arg: []const u8 = argv[1];
        if (mem.eql(u8, argv[1], "~")) arg = home orelse "";

        posix.chdir(arg) catch {
            try stdout.print("{s}: No such file or directory\n", .{arg});
            try stdout.flush();
        };
    } else if (mem.eql(u8, cmd, "pwd")) {
        var pbuff: [fs.max_path_bytes]u8 = undefined;
        const cwd: []u8 = try std.process.getCwd(&pbuff);
        try stdout.print("{s}\n", .{cwd});
        try stdout.flush();
    } else if (mem.eql(u8, cmd, "echo")) {
        try handleEcho(argv, stdout);
    } else if (mem.eql(u8, cmd, "type")) {
        try handleType(buff, argv, stdout);
    } else if (mem.eql(u8, cmd, "history")) {
        if (argv.len == 3) {
            const arg: []const u8 = argv[1];
            const val: []const u8 = argv[2];

            if (mem.eql(u8, arg, "-r")) {
                // Read history from a file.
                try hst.readHistory(alloc, val);
            } else if (mem.eql(u8, arg, "-w")) {
                // Write history to file.
                try hst.writeHistory(val, append);
            } else if (mem.eql(u8, arg, "-a")) {
                // append history to a file.
                try hst.writeHistory(val, !append);
            }
        } else {
            try hst.handleHistory(argv, stdout);
        }
    }
}

fn typeBuilt(args: []const u8, buff: []u8, only_exec: bool) !?[]const u8 {
    for (paths_arr.items) |path| {
        const full_path: []u8 = try std.fmt.bufPrint(buff, "{s}/{s}", .{ path, args });

        if (only_exec) {
            posix.faccessat(std.os.linux.AT.FDCWD, full_path, std.os.linux.X_OK, 0) catch continue;
            return full_path;
        } else {
            fs.accessAbsolute(full_path, .{}) catch continue;
            return full_path;
        }
    }

    return null;
}

fn handleEcho(argv: [][]const u8, stdout: *Io.Writer) !void {
    if (argv.len < 2) return;
    for (argv[1 .. argv.len - 1]) |arg| {
        try stdout.print("{s} ", .{arg});
    }
    try stdout.print("{s}\n", .{argv[argv.len - 1]});
    try stdout.flush();
}

fn handleType(buff: []u8, argv: [][]const u8, stdout: *Io.Writer) !void {
    var found: bool = false;
    const cmd: []const u8 = argv[1];
    for (builtins) |builtin| {
        if (mem.eql(u8, builtin, cmd)) {
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

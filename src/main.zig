const std = @import("std");
const clib = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("readline/history.h");
    @cInclude("readline/readline.h");
});

const hst_path: []const u8 = ".shell_history";
const stdout = std.io.getStdOut().writer();
const builtins = [_][]const u8{ "exit", "echo", "type", "pwd", "history" };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const buff = try alloc.alloc(u8, 1024);
    defer alloc.free(buff);

    std.posix.access(hst_path, std.posix.F_OK) catch {
        const file = try std.fs.cwd().createFile(hst_path, .{ .read = true });
        defer file.close();
    };

    clib.using_history();
    _ = clib.read_history(".shell_history");
    defer {
        clib.clear_history();
    }

    completion_path = std.posix.getenv("PATH");
    clib.rl_attempted_completion_function = &completion;

    while (true) {
        const line = clib.readline("$ ");
        defer clib.free(line);
        const ln_len = std.mem.len(line);
        const user_input: []u8 = line[0..ln_len];
        clib.add_history(line);
        _ = clib.write_history(".shell_history");

        if (std.mem.count(u8, user_input, "|") > 0) {
            try executePipeCmds(alloc, user_input, buff);
            continue;
        }

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

        const cmd = argv[0];

        if (std.mem.eql(u8, cmd, "exit")) {
            try handleExit();
        } else if (std.mem.eql(u8, cmd, "cd")) {
            try handleCd(argv);
        } else if (std.mem.eql(u8, cmd, "pwd")) {
            try handlePwd(buff);
        } else if (std.mem.eql(u8, cmd, "echo")) {
            if (argv.len < 2) return;
            for (argv[1 .. argv.len - 1]) |arg| {
                try out.print("{s} ", .{arg});
            }
            try out.print("{s}\n", .{argv[argv.len - 1]});
        } else if (std.mem.eql(u8, cmd, "type")) {
            try handleType(argv, buff);
        } else if (std.mem.eql(u8, cmd, "history")) {
            try handleHistory(argv);
        } else {
            if (try typeBuilt(cmd, buff)) |_| {
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
                _ = try res.wait();
            } else {
                try stdout.print("{s}: command not found\n", .{cmd});
            }
        }
    }
}

fn handleExit() !void {
    std.posix.exit(0);
}

fn handleHistory(args: [][]const u8) !void {
    const hst_len: c_int = clib.history_length;

    if (args.len > 1) {
        const limit = std.fmt.parseInt(c_int, args[1], 10) catch {
            try stdout.print("history: {s}: numeric argument required\n", .{args[1]});
            return;
        };

        if (limit <= 0) return;
        const start_idx = @max(1, hst_len - limit + 1);

        var i: c_int = start_idx;
        while (i <= hst_len) : (i += 1) {
            const entry = clib.history_get(i);
            if (entry != null) {
                const line = entry.*.line;
                if (line != null) {
                    try stdout.print("{d:>5}  {s}\n", .{ @as(u32, @intCast(i)), line });
                }
            }
        }
    } else {
        var i: c_int = 0;
        while (i <= hst_len) : (i += 1) {
            const entry = clib.history_get(i);
            if (entry != null) {
                const line = entry.*.line;
                if (line != null) {
                    try stdout.print("{d:>5}  {s}\n", .{ @as(u32, @intCast(i)), line });
                }
            }
        }
    }
}

fn handleType(argv: [][]const u8, buff: []u8) !void {
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
}

fn handlePwd(buff: []u8) !void {
    const pwd = try std.process.getCwd(buff);

    try stdout.print("{s}\n", .{pwd});
}

fn handleCd(argv: [][]const u8) !void {
    const home: []const u8 = "HOME";
    var arg: []const u8 = argv[1];
    if (std.mem.eql(u8, argv[1], "~")) {
        arg = std.posix.getenv(home) orelse "";
    }
    std.posix.chdir(arg) catch {
        try stdout.print("cd: {s}: No such file or directory\n", .{arg});
    };
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
var completion_path: ?[]const u8 = null;
var path_iterator: ?std.mem.TokenIterator(u8, .scalar) = null;
var dir_iterator: ?std.fs.Dir.Iterator = null;
var Builtins = true;

fn custom_completion(text: [*c]const u8, state: c_int) callconv(.c) [*c]u8 {
    if (state == 0) {
        completion_index = 0;
        text_len = std.mem.len(text);
    }

    const txt = text[0..text_len];

    if (Builtins) {
        while (completion_index < builtins.len) {
            const builtin_name = builtins[completion_index];
            completion_index += 1;

            if (std.mem.startsWith(u8, builtin_name, txt)) {
                return clib.strdup(builtin_name.ptr);
            }
        }
        Builtins = false;
        path_iterator = std.mem.tokenizeScalar(u8, completion_path.?, ':');
    }

    again: while (!Builtins) {
        if (dir_iterator == null) {
            if (path_iterator.?.next()) |path| {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const p = std.fs.realpath(path, &buf) catch continue :again;
                const dir = std.fs.openDirAbsolute(p, .{ .iterate = true }) catch continue :again;
                dir_iterator = dir.iterate();
                continue :again;
            } else {
                Builtins = true;
                path_iterator = null;
                break :again;
            }
        }

        while (dir_iterator.?.next() catch unreachable) |entry| {
            switch (entry.kind) {
                .file => {
                    if (std.mem.startsWith(u8, entry.name, txt)) {
                        return clib.strdup(entry.name.ptr);
                    }
                },

                else => continue,
            }
        } else {
            dir_iterator = null;
        }
    }

    return null;
}

fn executePipeCmds(alloc: std.mem.Allocator, inp: []const u8, buff: []u8) !void {
    var commands = std.ArrayList([]const u8).init(alloc);
    defer commands.deinit();

    var cmd_iter = std.mem.splitScalar(u8, inp, '|');
    while (cmd_iter.next()) |cmd| {
        const trimmed_cmd = std.mem.trim(u8, cmd, " \t\r\n");
        try commands.append(trimmed_cmd);
    }

    if (commands.items.len == 0) return;

    // try restoreDefaultSignalHandlers();
    // defer setupSignalHandlers() catch {};

    // Multiple commands with pipes
    const pipes_count = commands.items.len - 1;
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
        const args = try parse_inp(alloc, cmd_str);
        defer {
            for (args) |arg| {
                alloc.free(arg);
            }
            alloc.free(args);
        }

        if (args.len == 0) continue;
        const cmd = args[0];

        // Check if this is a builtin command
        var is_builtin = false;
        for (builtins) |builtin| {
            if (std.mem.eql(u8, builtin, cmd)) {
                is_builtin = true;
                break;
            }
        }

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

            // Execute the command
            if (is_builtin) {
                // Handle builtin commands
                if (std.mem.eql(u8, cmd, "exit")) {
                    try handleExit();
                } else if (std.mem.eql(u8, cmd, "cd")) {
                    try handleCd(args);
                } else if (std.mem.eql(u8, cmd, "pwd")) {
                    try handlePwd(buff);
                } else if (std.mem.eql(u8, cmd, "echo")) {
                    if (args.len < 2) std.posix.exit(0);
                    for (args[1 .. args.len - 1]) |arg| {
                        _ = stdout.print("{s} ", .{arg}) catch {};
                    }
                    _ = stdout.print("{s}\n", .{args[args.len - 1]}) catch {};
                } else if (std.mem.eql(u8, cmd, "type")) {
                    try handleType(args, buff);
                }
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

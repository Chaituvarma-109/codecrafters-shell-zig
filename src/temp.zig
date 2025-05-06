const std = @import("std");

const builtin = @import("builtin");

const commands = enum {
    exit,

    echo,

    type,

    pwd,

    cd,
};

pub fn main() !u8 {

    // Uncomment this block to pass the first stage

    const stdout = std.io.getStdOut().writer();

    var shell_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer shell_arena.deinit();

    const shell_allocator = shell_arena.allocator();

    const paths = try std.process.getEnvVarOwned(shell_allocator, "PATH");

    const buffer = try shell_allocator.alloc(u8, 1024);

    const executable_path_buffer = try shell_allocator.alloc(u8, 256);

    const OriginalTerminalMode = union(enum) {
        windows: u32,

        linux: std.os.linux.termios,
    };

    var original_mode: OriginalTerminalMode = undefined;

    if (builtin.os.tag == .windows) {
        original_mode = .{ .windows = try setRawModeWindows() };
    } else {
        original_mode = .{ .linux = undefined };

        try setRawModeLinux(&original_mode.linux);
    }

    defer if (builtin.os.tag == .windows) restoreModeWindows(original_mode.windows) else restoreModeLinux(&original_mode.linux);

    while (true) {
        var command_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

        defer command_arena.deinit();

        const command_allocator = command_arena.allocator();

        try stdout.print("$ ", .{});

        const user_input = try pollUntilNewline(buffer, paths);

        const trimmed_input = std.mem.trimRight(u8, user_input, "\n\r\t ");

        const full_argv = try splitArgs(command_allocator, trimmed_input);

        if (full_argv.len == 0) {
            continue;
        }

        var redirect_index: ?usize = null;

        var redirect_target: u8 = 1;

        var append = false;

        for (full_argv[0 .. full_argv.len - 1], 0..) |arg, index| {
            if (std.mem.eql(u8, arg, ">") or std.mem.eql(u8, arg, "1>") or std.mem.eql(u8, arg, "2>")) {
                redirect_index = index;

                if (arg.len == 2) {
                    redirect_target = arg[0] - '0';
                }

                break;
            }

            if (std.mem.eql(u8, arg, ">>") or std.mem.eql(u8, arg, "1>>") or std.mem.eql(u8, arg, "2>>")) {
                append = true;

                redirect_index = index;

                if (arg.len == 3) {
                    redirect_target = arg[0] - '0';
                }

                break;
            }
        }

        var argv = full_argv;

        var outfile: ?std.fs.File = null;

        var errfile: ?std.fs.File = null;

        var out = stdout;

        if (redirect_index) |index| {
            argv = full_argv[0..index];

            if (redirect_target == 1) {
                outfile = try std.fs.cwd().createFile(full_argv[index + 1], .{ .truncate = !append });

                if (outfile) |file| {
                    if (append) try file.seekFromEnd(0);

                    out = file.writer();
                }
            } else {
                errfile = try std.fs.cwd().createFile(full_argv[index + 1], .{ .truncate = !append });

                if (errfile) |file| {
                    if (append) try file.seekFromEnd(0);
                }
            }
        }

        defer if (outfile) |file| file.close();

        defer if (errfile) |file| file.close();

        const command = argv[0];

        if (std.meta.stringToEnum(commands, command)) |c| {
            switch (c) {
                .exit => return std.fmt.parseInt(u8, argOrDefault(argv, 1, "0"), 10) catch return 1,

                .echo => try echoCommand(out, argv),

                .type => try typeCommand(out, argOrDefault(argv, 1, ""), paths),

                .pwd => try pwdCommand(out),

                .cd => try cdCommand(out, argOrDefault(argv, 1, "")),
            }
        } else {
            if (searchPathsForExecutable(executable_path_buffer, command, paths)) |_| {
                var process = std.process.Child.init(argv, command_allocator);

                process.stdin_behavior = .Inherit;

                process.stdout_behavior = .Inherit;

                process.stderr_behavior = .Inherit;

                if (outfile) |file| {
                    process.stdout_behavior = .Pipe;

                    try process.spawn();

                    try file.writeFileAllUnseekable(process.stdout.?, .{});
                } else if (errfile) |file| {
                    process.stderr_behavior = .Pipe;

                    try process.spawn();

                    try file.writeFileAllUnseekable(process.stderr.?, .{});
                } else {
                    process.stdout_behavior = .Inherit;

                    try process.spawn();
                }

                _ = try process.wait();
            } else {
                try out.print("{s}: command not found\n", .{command});
            }
        }
    }
}

fn setRawModeLinux(original_termios: *std.os.linux.termios) !void {
    _ = std.os.linux.tcgetattr(std.io.getStdIn().handle, original_termios);

    var new_term: std.os.linux.termios = original_termios.*;

    new_term.lflag.ECHO = false;

    new_term.lflag.ICANON = false;

    new_term.cc[@intFromEnum(std.os.linux.V.TIME)] = 0;

    new_term.cc[@intFromEnum(std.os.linux.V.MIN)] = 1;

    _ = std.os.linux.tcsetattr(std.io.getStdIn().handle, .FLUSH, &new_term);
}

fn setRawModeWindows() !u32 {
    var stdin_mode: u32 = undefined;

    _ = std.os.windows.kernel32.GetConsoleMode(std.io.getStdIn().handle, &stdin_mode);

    const new_stdin_mode = stdin_mode & ~@as(u32, (0x0004 | 0x0002));

    _ = std.os.windows.kernel32.SetConsoleMode(std.io.getStdIn().handle, new_stdin_mode);

    return stdin_mode;
}

fn restoreModeWindows(stdin_mode: u32) void {
    _ = std.os.windows.kernel32.SetConsoleMode(std.io.getStdIn().handle, stdin_mode);
}

fn restoreModeLinux(termios: *std.os.linux.termios) void {
    _ = std.os.linux.tcsetattr(std.io.getStdIn().handle, .FLUSH, termios);
}

fn pollUntilNewline(buffer: []u8, paths: []const u8) ![]const u8 {
    var buffer_index: usize = 0;

    var last: u8 = 0;

    while (std.io.getStdIn().reader().readByte()) |read| {
        switch (read) {
            '\r' => {
                buffer[buffer_index] = read;

                buffer[buffer_index + 1] = '\n';

                // buffer_index += 2;

                try std.io.getStdOut().writer().print("\r\n", .{});

                break;
            },

            '\n' => {
                buffer[buffer_index] = read;

                try std.io.getStdOut().writer().print("\n", .{});

                break;
            },

            8, 127 => {
                if (buffer_index > 0) {
                    buffer_index -= 1;

                    try std.io.getStdOut().writer().print("{c} {c}", .{ @as(u8, 8), @as(u8, 8) });
                }
            },

            '\t' => {
                if (last != '\t') {
                    const new_index = try autocomplete(buffer, buffer_index, paths);

                    if (new_index > buffer_index) {
                        try std.io.getStdOut().writer().print("{s}", .{buffer[buffer_index..new_index]});

                        buffer_index = new_index;
                    } else {
                        try std.io.getStdOut().writer().writeByte(7);
                    }
                } else {
                    try printMatches(buffer, buffer_index, paths);
                }
            },

            else => {
                buffer[buffer_index] = read;

                buffer_index += 1;

                try std.io.getStdOut().writer().print("{c}", .{read});
            },
        }

        last = read;
    } else |err| return err;

    return buffer[0..buffer_index];
}

fn autocomplete(buffer: []u8, index: usize, paths: []const u8) !usize {
    inline for (@typeInfo(commands).Enum.fields) |field| {
        const command_name = field.name;

        if (command_name.len > index and std.mem.eql(u8, command_name[0..index], buffer[0..index])) {
            std.mem.copyForwards(u8, buffer, command_name);

            buffer[command_name.len] = ' ';

            return command_name.len + 1;
        }
    }

    var path_iter = std.mem.splitScalar(u8, paths, std.fs.path.delimiter);

    var new_index = index;

    var matches: usize = 0;

    while (path_iter.next()) |path| {
        if (!std.fs.path.isAbsolute(path)) continue;

        var dir = std.fs.openDirAbsolute(path, .{ .access_sub_paths = false, .iterate = true }) catch {
            continue;
        };

        defer dir.close();

        var dir_interator = dir.iterate();

        while (try dir_interator.next()) |file| {
            var extension_len: usize = 0;

            if (builtin.os.tag == .windows) {
                if (!std.mem.eql(u8, std.fs.path.extension(file.name), ".exe")) {
                    continue;
                }

                extension_len = std.fs.path.extension(file.name).len;
            }

            if (file.name.len > index and std.mem.eql(u8, file.name[0..index], buffer[0..index])) {
                const name_len = file.name.len - extension_len;

                if (matches < 1) {
                    std.mem.copyForwards(u8, buffer, file.name[0..name_len]);

                    buffer[name_len] = ' ';

                    new_index = name_len + 1;
                } else {
                    var i: usize = index;

                    while (i < new_index and i < name_len and buffer[i] == file.name[i]) {
                        i += 1;
                    }

                    new_index = i;
                }

                matches += 1;
            }
        }
    }

    if (matches < 1) {
        return index;
    }

    return new_index;
}

fn printMatches(buffer: []u8, index: usize, paths: []const u8) !void {
    var path_iter = std.mem.splitScalar(u8, paths, std.fs.path.delimiter);

    var new_index = index;

    var matches: usize = 0;

    while (path_iter.next()) |path| {
        if (!std.fs.path.isAbsolute(path)) continue;

        var dir = std.fs.openDirAbsolute(path, .{ .access_sub_paths = false, .iterate = true }) catch {
            continue;
        };

        defer dir.close();

        var dir_interator = dir.iterate();

        while (try dir_interator.next()) |file| {
            var extension_len: usize = 0;

            if (builtin.os.tag == .windows) {
                if (!std.mem.eql(u8, std.fs.path.extension(file.name), ".exe")) {
                    continue;
                }

                extension_len = std.fs.path.extension(file.name).len;
            }

            if (file.name.len > index and std.mem.eql(u8, file.name[0..index], buffer[0..index])) {
                const name_len = file.name.len - extension_len;

                switch (matches) {
                    0 => {
                        std.mem.copyForwards(u8, buffer, file.name[0..name_len]);

                        new_index = name_len;
                    },

                    1 => {
                        try std.io.getStdOut().writer().print("\n{s}  {s}", .{ buffer[0..new_index], file.name[0..name_len] });
                    },

                    else => {
                        try std.io.getStdOut().writer().print("  {s}", .{file.name[0..name_len]});
                    },
                }

                matches += 1;
            }
        }
    }

    if (matches > 1) {
        try std.io.getStdOut().writer().print("\n$ {s}", .{buffer[0..index]});
    }
}

fn splitArgs(allocator: std.mem.Allocator, arg_str: []const u8) ![][]const u8 {
    var args = std.ArrayList([]const u8).init(allocator);

    var arg_array = std.ArrayList(u8).init(allocator);

    const writer = arg_array.writer();

    var arg_stream = std.io.fixedBufferStream(arg_str);

    var reader = arg_stream.reader();

    var arg_str_index: usize = 0;

    while (std.mem.indexOfAnyPos(u8, arg_str, arg_str_index, " \'\"\\")) |end| {
        switch (arg_str[end]) {
            ' ' => {
                try reader.streamUntilDelimiter(writer, ' ', null);

                if (arg_array.items.len > 0) {
                    try args.append(try arg_array.toOwnedSlice());
                }

                arg_str_index = end + 1;
            },

            '\'' => {
                try reader.streamUntilDelimiter(writer, '\'', null);

                arg_str_index = end + 1;

                if (std.mem.indexOfScalarPos(u8, arg_str, arg_str_index, '\'')) |close| {
                    try reader.streamUntilDelimiter(writer, '\'', null);

                    arg_str_index = close + 1;
                } else {
                    break;
                }
            },

            '\"' => {
                try reader.streamUntilDelimiter(writer, '\"', null);

                arg_str_index = end + 1;

                while (std.mem.indexOfAnyPos(u8, arg_str, arg_str_index, "\\\"")) |escape_or_close| {
                    switch (arg_str[escape_or_close]) {
                        '\\' => {
                            try reader.streamUntilDelimiter(writer, '\\', null);

                            const escape = try reader.readByte();

                            switch (escape) {

                                // 'n' => try writer.writeByte('\n'),

                                '$', '\"', '\\' => try writer.writeByte(escape),

                                else => {
                                    try writer.writeByte('\\');

                                    try writer.writeByte(escape);
                                },
                            }

                            arg_str_index = escape_or_close + 2;
                        },

                        '\"' => {
                            try reader.streamUntilDelimiter(writer, '\"', null);

                            arg_str_index = escape_or_close + 1;

                            break;
                        },

                        else => unreachable,
                    }
                }
            },

            '\\' => {
                try reader.streamUntilDelimiter(writer, '\\', null);

                try writer.writeByte(try reader.readByte());

                arg_str_index = end + 2;
            },

            else => unreachable,
        }
    }

    try writer.writeAll(arg_str[arg_str_index..]);

    if (arg_array.items.len > 0) {
        try args.append(try arg_array.toOwnedSlice());
    }

    return try args.toOwnedSlice();
}

fn argOrDefault(argv: []const []const u8, argIndex: usize, default: []const u8) []const u8 {
    if (argv.len > argIndex)
        return argv[argIndex]
    else
        return default;
}

fn searchPathsForExecutable(buffer: []u8, executable: []const u8, paths: []const u8) ?[]const u8 {
    var path_iter = std.mem.splitScalar(u8, paths, std.fs.path.delimiter);

    while (path_iter.next()) |path| {
        if (!std.fs.path.isAbsolute(path)) {
            continue;
        }

        const sep = if (std.fs.path.isSep(path[path.len - 1])) "" else std.fs.path.sep_str;

        const extension = if (builtin.os.tag == .windows and std.fs.path.extension(executable).len == 0) ".exe" else "";

        const full_path = std.fmt.bufPrint(buffer, "{s}{s}{s}{s}", .{ path, sep, executable, extension }) catch {
            continue;
        };

        std.fs.accessAbsolute(full_path, .{}) catch {
            continue;
        };

        return full_path;
    }

    return null;
}

fn typeCommand(out: anytype, executable: []const u8, paths: []const u8) !void {
    if (executable.len == 0) {
        try out.print("type requires an argument\n", .{});

        return;
    }

    if (std.meta.stringToEnum(commands, executable) != null) {
        try out.print("{s} is a shell builtin\n", .{executable});

        return;
    }

    var buffer: [256]u8 = undefined;

    if (searchPathsForExecutable(&buffer, executable, paths)) |path| {
        try out.print("{s} is {s}\n", .{ executable, path });
    } else {
        try out.print("{s}: not found\n", .{executable});
    }
}

fn pwdCommand(out: anytype) !void {
    var buffer: [256]u8 = undefined;

    const cwd = try std.process.getCwd(&buffer);

    try out.print("{s}\n", .{cwd});
}

fn cdCommand(out: anytype, path: []const u8) !void {
    var buffer: [256]u8 = undefined;

    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var allocator = fba.allocator();

    var alloc_home_path: ?[]u8 = null;

    if (std.mem.eql(u8, path, "~")) {
        const home_env_var: []const u8 = switch (builtin.os.tag) {
            .windows => "USERPROFILE",

            .linux => "HOME",

            else => @compileError("Unsupported os"),
        };

        alloc_home_path = try std.process.getEnvVarOwned(allocator, home_env_var);
    }

    defer if (alloc_home_path) |mem| allocator.free(mem);

    const p: []const u8 = if (alloc_home_path) |home_path| home_path else path;

    var dir = std.fs.Dir.openDir(std.fs.cwd(), p, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => return try out.print("cd: {s}: No such file or directory\n", .{p}),

            else => return err,
        }
    };

    defer dir.close();

    try dir.setAsCwd();
}

fn echoCommand(out: anytype, argv: []const []const u8) !void {
    if (argv.len < 2) return;

    for (argv[1 .. argv.len - 1]) |arg| {
        try out.print("{s} ", .{arg});
    }

    try out.print("{s}\n", .{argv[argv.len - 1]});
}

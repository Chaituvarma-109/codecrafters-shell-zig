const std = @import("std");

const builtins = [_][]const u8{ "exit", "echo", "type", "pwd" };

pub fn main() !void {
    // Uncomment this block to pass the first stage
    const stdout = std.io.getStdOut().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    while (true) {
        try stdout.print("$ ", .{});

        const stdin = std.io.getStdIn().reader();
        var buffer: [1024]u8 = undefined;
        const user_input = try stdin.readUntilDelimiter(&buffer, '\n');

        const trim_inp = std.mem.trim(u8, user_input, "\r\n");
        var token_iter = std.mem.splitSequence(u8, trim_inp, " ");

        const cmd = token_iter.first();
        var args = token_iter.rest();

        if (std.mem.eql(u8, cmd, "exit")) {
            std.posix.exit(0);
        } else if (std.mem.eql(u8, cmd, "cd")) {
            const home: []const u8 = "HOME";
            if (std.mem.eql(u8, args, "~")) {
                args = std.posix.getenv(home) orelse "";
            }
            std.posix.chdir(args) catch {
                try stdout.print("{s}: No such file or directory\n", .{args});
            };
        } else if (std.mem.eql(u8, cmd, "pwd")) {
            var buff: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const pwd = try std.process.getCwd(&buff);

            try stdout.print("{s}\n", .{pwd});
        } else if (std.mem.eql(u8, cmd, "echo")) {
            try stdout.print("{s}\n", .{args});
        } else if (std.mem.eql(u8, cmd, "type")) {
            var found: bool = false;
            for (builtins) |builtin| {
                if (std.mem.eql(u8, builtin, args)) {
                    try stdout.print("{s} is a shell builtin\n", .{args});
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (try typeBuilt(alloc, args)) |p| {
                    defer alloc.free(p);
                    try stdout.print("{s} is {s}\n", .{ args, p });
                } else {
                    try stdout.print("{s}: not found\n", .{args});
                }
            }
        } else {
            if (try typeBuilt(alloc, cmd)) |p| {
                defer alloc.free(p);
                const res = try std.process.Child.run(.{ .allocator = alloc, .argv = &[_][]const u8{ cmd, args } });
                try stdout.print("{s}", .{res.stdout});
            } else {
                try stdout.print("{s}: command not found\n", .{cmd});
            }
        }
    }
}

fn typeBuilt(alloc: std.mem.Allocator, args: []const u8) !?[]const u8 {
    const env_path = std.posix.getenv("PATH");
    var folders = std.mem.tokenizeAny(u8, env_path.?, ":");

    while (folders.next()) |folder| {
        const full_path = try std.fs.path.join(alloc, &[_][]const u8{ folder, args });
        std.fs.accessAbsolute(full_path, .{ .mode = .read_only }) catch continue;
        return full_path;
    }

    return null;
}

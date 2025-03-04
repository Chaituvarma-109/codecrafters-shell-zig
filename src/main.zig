const std = @import("std");

const builtins = [_][]const u8{ "exit", "echo", "type" };

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
        const args = token_iter.rest();

        if (std.mem.eql(u8, cmd, "exit")) {
            std.posix.exit(0);
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
                // try stdout.print("{s}: not found\n", .{args});
                try typeBuilt(alloc, args);
            }
        } else {
            try stdout.print("{s}: command not found\n", .{cmd});
        }
    }
}

fn typeBuilt(alloc: std.mem.Allocator, args: []const u8) !void {
    const env_path = std.posix.getenv("PATH") orelse "";
    var folders = std.mem.splitScalar(u8, env_path, ':');

    while (folders.next()) |folder| {
        var dir = std.fs.cwd().openDir(folder, .{ .iterate = true }) catch {
            continue;
        };
        defer dir.close();

        var walker = try dir.walk(alloc);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (std.mem.eql(u8, entry.basename, args)) {
                return try std.io.getStdOut().writer().print("{0s} is {1s}/{0s}\n", .{ entry.basename, folder });
            }
        }
    }

    try std.io.getStdOut().writer().print("{s}: not found\n", .{args});
}

const std = @import("std");

const builtins = [_]*const [4:0]u8{ "exit", "echo", "type" };

pub fn main() !void {
    // Uncomment this block to pass the first stage
    const stdout = std.io.getStdOut().writer();

    while (true) {
        try stdout.print("$ ", .{});

        const stdin = std.io.getStdIn().reader();
        var buffer: [1024]u8 = undefined;
        const user_input = try stdin.readUntilDelimiter(&buffer, '\n');

        const trim_inp = std.mem.trim(u8, user_input, "\r\n");
        var token_iter = std.mem.tokenizeAny(u8, trim_inp, " ");

        const cmd = token_iter.next();
        const args = token_iter.rest();

        if (cmd) |c| {
            if (std.mem.eql(u8, c, "exit")) {
                std.posix.exit(0);
            } else if (std.mem.eql(u8, c, "echo")) {
                try stdout.print("{s}\n", .{args});
            } else if (std.mem.eql(u8, c, "type")) {
                var found: bool = false;
                for (builtins) |builtin| {
                    if (std.mem.eql(u8, builtin, args)) {
                        try stdout.print("{s} is a shell builtin\n", .{args});
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try stdout.print("{s}: not found\n", .{args});
                }
            } else {
                try stdout.print("{s}: command not found\n", .{c});
            }
        }
    }
}

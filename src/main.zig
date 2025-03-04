const std = @import("std");

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

        if (cmd) |c| {
            if (std.mem.eql(u8, c, "exit")) {
                std.posix.exit(0);
            } else if (std.mem.eql(u8, c, "echo")) {
                try stdout.print("{s}\n", .{token_iter.rest()});
            } else {
                try stdout.print("{s}: command not found\n", .{c});
            }
        }
    }
}

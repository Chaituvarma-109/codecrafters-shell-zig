// const std = @import("std");

// fn tokenizeInput(arena: std.mem.Allocator, input: []const u8) ![]Token {
//     var local_allocator = std.heap.DebugAllocator(.{}).init;

//     defer _ = local_allocator.deinit();

//     var tokens = std.ArrayList(Token).init(local_allocator.allocator());

//     defer tokens.deinit();

//     var pos: usize = 0;

//     while (pos < input.len) {
//         if (input[pos] == ' ') {
//             pos += 1;

//             continue;
//         }

//         if (input[pos] == '>') {
//             pos += 1;

//             if (input[pos] == '>') {
//                 pos += 1;

//                 try tokens.append(.{ .append = 1 });

//                 continue;
//             }

//             try tokens.append(.{ .redirect = 1 });

//             continue;
//         }

//         var token = std.ArrayList(u8).init(arena);

//         while (pos < input.len and input[pos] != ' ' and input[pos] != '>') {
//             switch (input[pos]) {
//                 '\'', '"' => {
//                     const quote = input[pos];

//                     pos += 1;

//                     while (input[pos] != quote) {
//                         if (quote == '"' and input[pos] == '\\' and switch (input[pos + 1]) {
//                             '"', '\\', '$', '\n' => true,

//                             else => false,
//                         }) {
//                             pos += 1;
//                         }

//                         try token.append(input[pos]);

//                         pos += 1;
//                     }

//                     pos += 1;
//                 },

//                 '\\' => {
//                     try token.append(input[pos + 1]);

//                     pos += 2;
//                 },

//                 else => {
//                     try token.append(input[pos]);

//                     pos += 1;
//                 },
//             }
//         }

//         if (pos < input.len and input[pos] == '>') {
//             if (std.fmt.parseUnsigned(u8, token.items, 10)) |fd| {
//                 pos += 1;

//                 if (input[pos] == '>') {
//                     pos += 1;

//                     try tokens.append(.{ .append = fd });

//                     continue;
//                 }

//                 try tokens.append(.{ .redirect = fd });

//                 continue;
//             } else |_| {}
//         }

//         try tokens.append(.{ .regular = try token.toOwnedSlice() });
//     }

//     const result = try arena.alloc(Token, tokens.items.len);

//     @memcpy(result, tokens.items);

//     return result;
// }

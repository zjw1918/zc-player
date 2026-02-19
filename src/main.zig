const std = @import("std");
const App = @import("app/App.zig").App;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const media_path: ?[]const u8 = if (args.len > 1) args[1] else null;

    var app = App.init(allocator);
    defer app.deinit();

    try app.run(media_path);
}

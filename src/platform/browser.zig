const std = @import("std");

pub fn open(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !void {
    if (url.len == 0 or !std.unicode.utf8ValidateSlice(url) or std.mem.indexOfAny(u8, url, "\r\n\x00") != null)
        return error.InvalidUrl;

    const argv: []const []const u8 = switch (@import("builtin").os.tag) {
        .macos => &.{ "open", url },
        .linux => &.{ "xdg-open", url },
        else => return error.UnsupportedBrowser,
    };
    _ = allocator;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.BrowserCommandNotFound,
        else => return error.BrowserOpenFailed,
    };
    errdefer child.kill(io);
    const term = child.wait(io) catch return error.BrowserOpenFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.BrowserOpenFailed,
        else => return error.BrowserOpenFailed,
    }
}

test "browser rejects invalid URLs before launching a command" {
    try std.testing.expectError(error.InvalidUrl, open(std.testing.allocator, std.testing.io, ""));
    try std.testing.expectError(error.InvalidUrl, open(std.testing.allocator, std.testing.io, "https://github.com/\nunsafe"));
}

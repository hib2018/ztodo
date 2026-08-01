const std = @import("std");

const max_clipboard_bytes = 1024 * 1024;

pub fn copy(allocator: std.mem.Allocator, io: std.Io, text: []const u8) !void {
    switch (@import("builtin").os.tag) {
        .macos => try run(allocator, io, &.{"pbcopy"}, text),
        .linux => run(allocator, io, &.{"wl-copy"}, text) catch |err| switch (err) {
            error.ClipboardCommandNotFound => try run(
                allocator,
                io,
                &.{ "xclip", "-selection", "clipboard" },
                text,
            ),
            else => return err,
        },
        else => return error.UnsupportedClipboard,
    }
}

pub fn read(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    return switch (@import("builtin").os.tag) {
        .macos => runRead(allocator, io, &.{"pbpaste"}),
        .linux => runRead(allocator, io, &.{ "wl-paste", "--no-newline" }) catch |err| switch (err) {
            error.ClipboardCommandNotFound => runRead(
                allocator,
                io,
                &.{ "xclip", "-selection", "clipboard", "-out" },
            ),
            else => return err,
        },
        else => error.UnsupportedClipboard,
    };
}

fn runRead(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) ![]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_clipboard_bytes),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.ClipboardCommandNotFound,
        error.StreamTooLong => return error.ClipboardTooLarge,
        else => return error.ClipboardFailed,
    };
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ClipboardFailed,
        else => return error.ClipboardFailed,
    }
    if (std.mem.trim(u8, result.stdout, " \t\r\n").len == 0)
        return error.EmptyClipboard;
    return result.stdout;
}

fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    text: []const u8,
) !void {
    _ = allocator;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.ClipboardCommandNotFound,
        else => return error.ClipboardFailed,
    };
    errdefer child.kill(io);
    child.stdin.?.writeStreamingAll(io, text) catch return error.ClipboardFailed;
    child.stdin.?.close(io);
    child.stdin = null;
    const term = child.wait(io) catch return error.ClipboardFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.ClipboardFailed,
        else => return error.ClipboardFailed,
    }
}

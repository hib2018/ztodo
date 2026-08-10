const std = @import("std");
const prompt_instructions = @import("prompt_instructions.zig");

pub fn edit(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    path: []const u8,
) !void {
    const editor = environ.get("VISUAL") orelse environ.get("EDITOR") orelse return error.EditorNotConfigured;
    if (std.mem.trim(u8, editor, " \t\r\n").len == 0) return error.EditorNotConfigured;
    const current = try prompt_instructions.load(allocator, io, path);
    defer allocator.free(current);
    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch return error.CreatePromptInstructionsDirectoryFailed;
    }

    var suffix: u64 = undefined;
    io.random(std.mem.asBytes(&suffix));
    const temporary_path = try std.fmt.allocPrint(allocator, "{s}.edit-{x}", .{ path, suffix });
    defer allocator.free(temporary_path);
    defer std.Io.Dir.cwd().deleteFile(io, temporary_path) catch {};
    {
        const file = std.Io.Dir.cwd().createFile(io, temporary_path, .{ .exclusive = true }) catch
            return error.PromptInstructionsWriteFailed;
        defer file.close(io);
        std.Io.File.writeStreamingAll(file, io, current) catch return error.PromptInstructionsWriteFailed;
        file.sync(io) catch return error.PromptInstructionsWriteFailed;
    }

    const term = blk: {
        var child = std.process.spawn(io, .{
            .argv = &.{ "/bin/sh", "-c", "file=$2; eval 'set -- ' \"$1\"; exec \"$@\" \"$file\"", "ztodo-editor", editor, temporary_path },
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.EditorNotFound,
            else => return error.EditorFailed,
        };
        errdefer child.kill(io);
        break :blk child.wait(io) catch return error.EditorFailed;
    };
    switch (term) {
        .exited => |code| if (code != 0) return error.EditorFailed,
        else => return error.EditorFailed,
    }
    const edited = std.Io.Dir.cwd().readFileAlloc(io, temporary_path, allocator, .limited(prompt_instructions.max_file_size)) catch |err| switch (err) {
        error.StreamTooLong => return error.PromptInstructionsTooLarge,
        else => return error.PromptInstructionsReadFailed,
    };
    defer allocator.free(edited);
    try prompt_instructions.save(io, path, edited);
}

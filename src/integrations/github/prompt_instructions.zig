const std = @import("std");

pub const max_file_size = 64 * 1024;

pub fn resolvePath(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    if (environ.get("ZTODO_PROMPT_INSTRUCTIONS_FILE")) |path| {
        if (path.len != 0) return allocator.dupe(u8, path);
    }
    if (environ.get("XDG_CONFIG_HOME")) |base| {
        if (base.len != 0)
            return std.fs.path.join(allocator, &.{ base, "ztodo", "prompt-instructions.txt" });
    }
    const home = environ.get("HOME") orelse return error.MissingHome;
    if (home.len == 0) return error.MissingHome;
    return std.fs.path.join(allocator, &.{ home, ".config", "ztodo", "prompt-instructions.txt" });
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_file_size),
    ) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, ""),
        error.StreamTooLong => return error.PromptInstructionsTooLarge,
        else => return error.PromptInstructionsReadFailed,
    };
    errdefer allocator.free(bytes);
    try validate(bytes);
    return bytes;
}

pub fn validate(bytes: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(bytes))
        return error.InvalidPromptInstructions;
    for (bytes) |byte| {
        if ((byte < 0x20 and byte != '\n' and byte != '\r' and byte != '\t') or byte == 0x7f)
            return error.InvalidPromptInstructions;
    }
}

pub fn save(io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (bytes.len > max_file_size) return error.PromptInstructionsTooLarge;
    try validate(bytes);
    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch
            return error.CreatePromptInstructionsDirectoryFailed;
    }
    var atomic = std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true }) catch
        return error.PromptInstructionsWriteFailed;
    defer atomic.deinit(io);
    std.Io.File.writeStreamingAll(atomic.file, io, bytes) catch
        return error.PromptInstructionsWriteFailed;
    atomic.file.sync(io) catch return error.PromptInstructionsWriteFailed;
    atomic.replace(io) catch return error.PromptInstructionsWriteFailed;
}

pub fn remove(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.PromptInstructionsDeleteFailed,
    };
    return true;
}

test "prompt instruction path follows override XDG and HOME priority" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/user");
    const path = try resolvePath(std.testing.allocator, &env);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/home/user/.config/ztodo/prompt-instructions.txt", path);

    try env.put("XDG_CONFIG_HOME", "/config");
    const xdg_path = try resolvePath(std.testing.allocator, &env);
    defer std.testing.allocator.free(xdg_path);
    try std.testing.expectEqualStrings("/config/ztodo/prompt-instructions.txt", xdg_path);

    try env.put("ZTODO_PROMPT_INSTRUCTIONS_FILE", "/tmp/custom.txt");
    const override_path = try resolvePath(std.testing.allocator, &env);
    defer std.testing.allocator.free(override_path);
    try std.testing.expectEqualStrings("/tmp/custom.txt", override_path);
}

test "prompt instructions validate and save atomically" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "config", "prompt-instructions.txt" });
    defer allocator.free(path);

    try save(io, path, "日本語で分解する\n");
    const loaded = try load(allocator, io, path);
    defer allocator.free(loaded);
    try std.testing.expectEqualStrings("日本語で分解する\n", loaded);
    try std.testing.expectError(error.InvalidPromptInstructions, validate("bad\x00text"));
    try std.testing.expect(try remove(io, path));
    try std.testing.expect(!try remove(io, path));
}

test "missing prompt instructions load as empty" {
    const loaded = try load(std.testing.allocator, std.testing.io, "missing-prompt-instructions.txt");
    defer std.testing.allocator.free(loaded);
    try std.testing.expectEqualStrings("", loaded);
}

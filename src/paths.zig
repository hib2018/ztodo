const std = @import("std");

pub fn resolve(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get("ZTODO_DATA_FILE")) |path| {
        if (path.len != 0) return allocator.dupe(u8, path);
    }
    if (environ.get("XDG_DATA_HOME")) |base| {
        if (base.len != 0) return std.fs.path.join(allocator, &.{ base, "ztodo", "tasks.json" });
    }
    const home = environ.get("HOME") orelse return error.MissingHome;
    if (home.len == 0) return error.MissingHome;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "ztodo", "tasks.json" });
}

pub fn resolveProposal(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    const tasks_path = try resolve(allocator, environ);
    defer allocator.free(tasks_path);
    const parent = std.fs.path.dirname(tasks_path) orelse return allocator.dupe(u8, "proposal.json");
    return std.fs.path.join(allocator, &.{ parent, "proposal.json" });
}

pub fn ensureParent(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    std.Io.Dir.cwd().createDirPath(io, parent) catch return error.CreateDirectoryFailed;
}

test "path priority" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/user");
    const path = try resolve(std.testing.allocator, &env);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/home/user/.local/share/ztodo/tasks.json", path);
}

test "proposal path shares the task data directory" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZTODO_DATA_FILE", "/tmp/ztodo-test/tasks-custom.json");
    const path = try resolveProposal(std.testing.allocator, &env);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/ztodo-test/proposal.json", path);
}

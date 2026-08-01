const std = @import("std");
const github_cli = @import("client.zig");

pub const schema_version: u32 = 1;
pub const max_repositories = 20;
const max_file_size = 64 * 1024;

pub const Config = struct {
    allocator: std.mem.Allocator,
    repositories: [][]const u8,

    pub fn deinit(self: *Config) void {
        for (self.repositories) |repository| self.allocator.free(repository);
        self.allocator.free(self.repositories);
        self.* = undefined;
    }
};

const DiskConfig = struct {
    schema_version: u32 = schema_version,
    repositories: []const []const u8,
};

pub fn resolvePath(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    if (environ.get("ZTODO_CONFIG_FILE")) |path| {
        if (path.len != 0) return allocator.dupe(u8, path);
    }
    if (environ.get("XDG_CONFIG_HOME")) |base| {
        if (base.len != 0)
            return std.fs.path.join(allocator, &.{ base, "ztodo", "config.json" });
    }
    const home = environ.get("HOME") orelse return error.MissingHome;
    if (home.len == 0) return error.MissingHome;
    return std.fs.path.join(allocator, &.{ home, ".config", "ztodo", "config.json" });
}

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !Config {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_file_size),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.GitHubConfigNotFound,
        error.StreamTooLong => return error.GitHubConfigTooLarge,
        else => return error.GitHubConfigReadFailed,
    };
    defer allocator.free(bytes);
    return decode(allocator, bytes);
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Config {
    const parsed = std.json.parseFromSlice(DiskConfig, allocator, bytes, .{}) catch
        return error.InvalidGitHubConfig;
    defer parsed.deinit();
    if (parsed.value.schema_version != schema_version)
        return error.UnsupportedGitHubConfigVersion;
    if (parsed.value.repositories.len > max_repositories)
        return error.TooManyConfiguredRepositories;

    const repositories = try allocator.alloc(
        []const u8,
        parsed.value.repositories.len,
    );
    errdefer allocator.free(repositories);
    var initialized: usize = 0;
    errdefer for (repositories[0..initialized]) |repository|
        allocator.free(repository);

    for (parsed.value.repositories, 0..) |repository, index| {
        try github_cli.validateRepository(repository);
        for (repositories[0..initialized]) |existing| {
            if (std.mem.eql(u8, existing, repository))
                return error.DuplicateConfiguredRepository;
        }
        repositories[index] = try allocator.dupe(u8, repository);
        initialized += 1;
    }
    return .{ .allocator = allocator, .repositories = repositories };
}

pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    config: *const Config,
) !void {
    const bytes = std.json.Stringify.valueAlloc(allocator, DiskConfig{
        .schema_version = schema_version,
        .repositories = config.repositories,
    }, .{ .whitespace = .indent_2 }) catch return error.GitHubConfigWriteFailed;
    defer allocator.free(bytes);

    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch
            return error.CreateConfigDirectoryFailed;
    }
    var atomic = std.Io.Dir.cwd().createFileAtomic(
        io,
        path,
        .{ .replace = true },
    ) catch return error.GitHubConfigWriteFailed;
    defer atomic.deinit(io);
    std.Io.File.writeStreamingAll(atomic.file, io, bytes) catch
        return error.GitHubConfigWriteFailed;
    atomic.file.sync(io) catch return error.GitHubConfigWriteFailed;
    atomic.replace(io) catch return error.GitHubConfigWriteFailed;
}

pub fn addRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    repository: []const u8,
) !usize {
    try github_cli.validateRepository(repository);
    var config = load(allocator, io, path) catch |err| switch (err) {
        error.GitHubConfigNotFound => Config{
            .allocator = allocator,
            .repositories = try allocator.alloc([]const u8, 0),
        },
        else => return err,
    };
    defer config.deinit();
    if (config.repositories.len >= max_repositories)
        return error.TooManyConfiguredRepositories;
    for (config.repositories) |existing| {
        if (std.mem.eql(u8, existing, repository))
            return error.DuplicateConfiguredRepository;
    }
    const copy = try allocator.dupe(u8, repository);
    errdefer allocator.free(copy);
    config.repositories = try allocator.realloc(
        config.repositories,
        config.repositories.len + 1,
    );
    config.repositories[config.repositories.len - 1] = copy;
    try save(allocator, io, path, &config);
    return config.repositories.len;
}

pub fn removeRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    repository: []const u8,
) !usize {
    try github_cli.validateRepository(repository);
    var config = try load(allocator, io, path);
    defer config.deinit();
    var found: ?usize = null;
    for (config.repositories, 0..) |existing, index| {
        if (std.mem.eql(u8, existing, repository)) {
            found = index;
            break;
        }
    }
    const index = found orelse return error.RepositoryNotConfigured;
    allocator.free(config.repositories[index]);
    const remaining = try allocator.alloc(
        []const u8,
        config.repositories.len - 1,
    );
    var target: usize = 0;
    for (config.repositories, 0..) |existing, current| {
        if (current == index) continue;
        remaining[target] = existing;
        target += 1;
    }
    allocator.free(config.repositories);
    config.repositories = remaining;
    try save(allocator, io, path, &config);
    return config.repositories.len;
}

test "config path follows override XDG and HOME priority" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/user");
    var path = try resolvePath(allocator, &env);
    try std.testing.expectEqualStrings("/home/user/.config/ztodo/config.json", path);
    allocator.free(path);

    try env.put("XDG_CONFIG_HOME", "/config");
    path = try resolvePath(allocator, &env);
    try std.testing.expectEqualStrings("/config/ztodo/config.json", path);
    allocator.free(path);

    try env.put("ZTODO_CONFIG_FILE", "/tmp/ztodo-config.json");
    path = try resolvePath(allocator, &env);
    try std.testing.expectEqualStrings("/tmp/ztodo-config.json", path);
    allocator.free(path);
}

test "config validates repositories and owns values" {
    const allocator = std.testing.allocator;
    var config = try decode(allocator,
        \\{"schema_version":1,"repositories":["owner/one","owner/two"]}
    );
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 2), config.repositories.len);
    try std.testing.expectEqualStrings("owner/two", config.repositories[1]);

    var empty = try decode(
        allocator,
        "{\"schema_version\":1,\"repositories\":[]}",
    );
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.repositories.len);
    try std.testing.expectError(
        error.DuplicateConfiguredRepository,
        decode(allocator,
            \\{"schema_version":1,"repositories":["owner/repo","owner/repo"]}
        ),
    );
}

test "repository operations save atomically and support an empty list" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(
        allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path, "config.json" },
    );
    defer allocator.free(path);

    try std.testing.expectEqual(
        @as(usize, 1),
        try addRepository(allocator, io, path, "owner/one"),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        try addRepository(allocator, io, path, "owner/two"),
    );
    try std.testing.expectError(
        error.DuplicateConfiguredRepository,
        addRepository(allocator, io, path, "owner/one"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try removeRepository(allocator, io, path, "owner/one"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try removeRepository(allocator, io, path, "owner/two"),
    );
    var loaded = try load(allocator, io, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.repositories.len);
}

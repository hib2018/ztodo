const std = @import("std");
const source_issue = @import("source_issue.zig");

const max_output_bytes = 2 * 1024 * 1024;
const max_issues = 100;

pub const IssueSummary = struct {
    number: u64,
    title: []const u8,
};

pub const IssueList = struct {
    allocator: std.mem.Allocator,
    items: []IssueSummary,

    pub fn deinit(self: *IssueList) void {
        for (self.items) |item| self.allocator.free(item.title);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn validateRepository(repository: []const u8) !void {
    const slash = std.mem.indexOfScalar(u8, repository, '/') orelse
        return error.InvalidRepository;
    if (slash == 0 or slash + 1 == repository.len) return error.InvalidRepository;
    if (std.mem.indexOfScalar(u8, repository[slash + 1 ..], '/') != null)
        return error.InvalidRepository;
    for (repository) |byte| {
        if (std.ascii.isWhitespace(byte) or std.ascii.isControl(byte))
            return error.InvalidRepository;
    }
}

pub fn currentRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
) ![]u8 {
    const result = try runGh(allocator, io, &.{
        "gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try requireSuccess(result.term);
    const repository = std.mem.trim(u8, result.stdout, " \t\r\n");
    try validateRepository(repository);
    return allocator.dupe(u8, repository);
}

pub fn listOpen(
    allocator: std.mem.Allocator,
    io: std.Io,
    repository: []const u8,
) !IssueList {
    try validateRepository(repository);
    const result = try runGh(allocator, io, &.{
        "gh",      "issue", "list",   "--repo",       repository, "--state", "open",
        "--limit", "100",   "--json", "number,title",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try requireSuccess(result.term);
    return parseList(allocator, result.stdout);
}

pub fn get(
    allocator: std.mem.Allocator,
    io: std.Io,
    repository: []const u8,
    number: u64,
) !source_issue.Issue {
    try validateRepository(repository);
    var number_buffer: [32]u8 = undefined;
    const number_text = std.fmt.bufPrint(&number_buffer, "{d}", .{number}) catch
        return error.InvalidIssueNumber;
    const result = try runGh(allocator, io, &.{
        "gh",     "issue",             "view", number_text, "--repo", repository,
        "--json", "number,title,body",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try requireSuccess(result.term);
    return parseIssue(allocator, repository, result.stdout);
}

fn runGh(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
    }) catch |err| switch (err) {
        error.FileNotFound => error.GitHubCliNotFound,
        error.StreamTooLong => error.GitHubCliOutputTooLarge,
        else => error.GitHubCliExecutionFailed,
    };
}

fn requireSuccess(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| if (code != 0) return error.GitHubCliFailed,
        else => return error.GitHubCliFailed,
    }
}

fn parseList(allocator: std.mem.Allocator, json: []const u8) !IssueList {
    const Item = struct { number: u64, title: []const u8 };
    const parsed = std.json.parseFromSlice([]Item, allocator, json, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidGitHubOutput;
    defer parsed.deinit();
    if (parsed.value.len > max_issues) return error.TooManyGitHubIssues;

    const items = try allocator.alloc(IssueSummary, parsed.value.len);
    errdefer allocator.free(items);
    var initialized: usize = 0;
    errdefer for (items[0..initialized]) |item| allocator.free(item.title);
    for (parsed.value, 0..) |item, index| {
        items[index] = .{
            .number = item.number,
            .title = try allocator.dupe(u8, item.title),
        };
        initialized += 1;
    }
    return .{ .allocator = allocator, .items = items };
}

fn parseIssue(
    allocator: std.mem.Allocator,
    repository: []const u8,
    json: []const u8,
) !source_issue.Issue {
    const Value = struct {
        number: u64,
        title: []const u8,
        body: []const u8 = "",
    };
    const parsed = std.json.parseFromSlice(Value, allocator, json, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidGitHubOutput;
    defer parsed.deinit();
    return source_issue.init(
        allocator,
        "github-cli",
        repository,
        parsed.value.number,
        parsed.value.title,
        parsed.value.body,
    );
}

test "repository validation" {
    try validateRepository("owner/repo");
    try std.testing.expectError(error.InvalidRepository, validateRepository("repo"));
    try std.testing.expectError(error.InvalidRepository, validateRepository("/repo"));
    try std.testing.expectError(error.InvalidRepository, validateRepository("owner/repo/extra"));
}

test "GitHub JSON parsing owns its values" {
    const allocator = std.testing.allocator;
    var list = try parseList(allocator,
        \\[{"number":12,"title":"テストを追加"},{"number":9,"title":"README"}]
    );
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(@as(u64, 12), list.items[0].number);
    try std.testing.expectEqualStrings("テストを追加", list.items[0].title);

    var issue = try parseIssue(allocator, "owner/repo",
        \\{"number":12,"title":"テストを追加","body":"完了条件を書く"}
    );
    defer issue.deinit();
    try std.testing.expectEqualStrings("github-cli", issue.provider);
    try std.testing.expectEqualStrings("完了条件を書く", issue.body);
}

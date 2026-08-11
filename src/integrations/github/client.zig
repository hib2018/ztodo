const std = @import("std");
const source_issue = @import("issue.zig");

const max_output_bytes = 16 * 1024 * 1024;
const max_issues = 10_000;
const max_aggregate_issues = 200_000;

pub const IssueSummary = struct {
    repository: []const u8,
    number: u64,
    title: []const u8,
    body: []const u8 = "",
};

pub const IssueList = struct {
    allocator: std.mem.Allocator,
    items: []IssueSummary,

    pub fn deinit(self: *IssueList) void {
        for (self.items) |item| {
            self.allocator.free(item.repository);
            self.allocator.free(item.title);
            self.allocator.free(item.body);
        }
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

pub fn listOpen(
    allocator: std.mem.Allocator,
    io: std.Io,
    repository: []const u8,
) !IssueList {
    try validateRepository(repository);
    const result = try runGh(allocator, io, &.{
        "gh",      "issue", "list",   "--repo",            repository, "--state", "open",
        "--limit", "10000", "--json", "number,title,body",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try requireSuccess(io, result.term, result.stderr);
    return parseList(allocator, repository, result.stdout);
}

pub fn listOpenMany(
    allocator: std.mem.Allocator,
    io: std.Io,
    repositories: []const []const u8,
) !IssueList {
    var combined: std.ArrayList(IssueSummary) = .empty;
    errdefer {
        for (combined.items) |item| {
            allocator.free(item.repository);
            allocator.free(item.title);
            allocator.free(item.body);
        }
        combined.deinit(allocator);
    }
    for (repositories) |repository| {
        var list = try listOpen(allocator, io, repository);
        errdefer list.deinit();
        if (combined.items.len + list.items.len > max_aggregate_issues)
            return error.TooManyGitHubIssues;
        try combined.ensureUnusedCapacity(allocator, list.items.len);
        for (list.items) |item| combined.appendAssumeCapacity(item);
        allocator.free(list.items);
        list = undefined;
    }
    return .{
        .allocator = allocator,
        .items = try combined.toOwnedSlice(allocator),
    };
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
    try requireSuccess(io, result.term, result.stderr);
    return parseIssue(allocator, repository, result.stdout);
}

pub fn fromSummary(allocator: std.mem.Allocator, summary: IssueSummary) !source_issue.Issue {
    return source_issue.init(allocator, "github-cli", summary.repository, summary.number, summary.title, summary.body);
}

pub fn openWeb(allocator: std.mem.Allocator, io: std.Io, repository: []const u8, number: u64) !void {
    try validateRepository(repository);
    var number_buffer: [32]u8 = undefined;
    const number_text = std.fmt.bufPrint(&number_buffer, "{d}", .{number}) catch return error.InvalidIssueNumber;
    const result = try runGh(allocator, io, &.{ "gh", "issue", "view", number_text, "--repo", repository, "--web" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try requireSuccess(io, result.term, result.stderr);
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

fn requireSuccess(io: std.Io, term: std.process.Child.Term, stderr: []const u8) !void {
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    const detail = std.mem.trim(u8, stderr, " \t\r\n");
    if (detail.len != 0) {
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stderr().writer(io, &buffer);
        const visible = detail[0..@min(detail.len, buffer.len - 32)];
        writer.interface.print("GitHub CLI: {s}\n", .{visible}) catch {};
        writer.interface.flush() catch {};
    }
    return error.GitHubCliFailed;
}

fn parseList(
    allocator: std.mem.Allocator,
    repository: []const u8,
    json: []const u8,
) !IssueList {
    const Item = struct { number: u64, title: []const u8, body: []const u8 = "" };
    const parsed = std.json.parseFromSlice([]Item, allocator, json, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidGitHubOutput;
    defer parsed.deinit();
    if (parsed.value.len > max_issues) return error.TooManyGitHubIssues;

    const items = try allocator.alloc(IssueSummary, parsed.value.len);
    errdefer allocator.free(items);
    var initialized: usize = 0;
    errdefer for (items[0..initialized]) |item| {
        allocator.free(item.repository);
        allocator.free(item.title);
        allocator.free(item.body);
    };
    for (parsed.value, 0..) |item, index| {
        const repository_copy = try allocator.dupe(u8, repository);
        errdefer allocator.free(repository_copy);
        const title_copy = try allocator.dupe(u8, item.title);
        errdefer allocator.free(title_copy);
        const body_copy = try allocator.dupe(u8, item.body);
        items[index] = .{
            .repository = repository_copy,
            .number = item.number,
            .title = title_copy,
            .body = body_copy,
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
    try std.testing.expectError(error.InvalidRepository, openWeb(std.testing.allocator, std.testing.io, "invalid", 1));
}

test "GitHub JSON parsing owns its values" {
    const allocator = std.testing.allocator;
    var list = try parseList(allocator, "owner/repo",
        \\[{"number":12,"title":"テストを追加","body":"本文"},{"number":9,"title":"README"}]
    );
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(@as(u64, 12), list.items[0].number);
    try std.testing.expectEqualStrings("owner/repo", list.items[0].repository);
    try std.testing.expectEqualStrings("テストを追加", list.items[0].title);
    try std.testing.expectEqualStrings("本文", list.items[0].body);

    var issue = try parseIssue(allocator, "owner/repo",
        \\{"number":12,"title":"テストを追加","body":"完了条件を書く"}
    );
    defer issue.deinit();
    try std.testing.expectEqualStrings("github-cli", issue.provider);
    try std.testing.expectEqualStrings("完了条件を書く", issue.body);
}

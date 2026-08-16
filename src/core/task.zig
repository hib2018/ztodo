const std = @import("std");

pub const Status = enum {
    todo,
    done,

    pub fn label(self: Status) []const u8 {
        return @tagName(self);
    }
};

pub const Task = struct {
    id: u64,
    title: []const u8,
    status: Status,
    issue: ?IssueRef = null,
};

pub const IssueRef = struct {
    repository: []const u8,
    number: u64,
    title: []const u8,
};

pub fn trimmedTitle(title: []const u8) error{EmptyTitle}![]const u8 {
    const trimmed = std.mem.trim(u8, title, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyTitle;
    return trimmed;
}

test "empty and whitespace-only titles are rejected" {
    try std.testing.expectError(error.EmptyTitle, trimmedTitle(""));
    try std.testing.expectError(error.EmptyTitle, trimmedTitle(" \t\n"));
    try std.testing.expectEqualStrings("task", try trimmedTitle("  task  "));
}

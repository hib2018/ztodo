const std = @import("std");
const github_cli = @import("github_cli.zig");

pub fn select(
    issues: []const github_cli.IssueSummary,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !?usize {
    if (issues.len == 0) {
        try writer.writeAll("No open issues.\n");
        return null;
    }
    try writer.writeAll("Open GitHub Issues\n\n");
    for (issues, 1..) |issue, index| {
        try writer.print("{d}. #{d} {s}\n", .{ index, issue.number, issue.title });
    }
    try writer.writeAll("\nSelect an issue number (q to cancel): ");
    try writer.flush();
    const input = try reader.takeDelimiter('\n') orelse return error.SelectionAborted;
    const trimmed = std.mem.trim(u8, input, " \t\r");
    if (std.mem.eql(u8, trimmed, "q")) return null;
    const selected = std.fmt.parseInt(usize, trimmed, 10) catch
        return error.InvalidIssueSelection;
    if (selected == 0 or selected > issues.len) return error.InvalidIssueSelection;
    return selected - 1;
}

test "selects by displayed one-based number" {
    const issues = [_]github_cli.IssueSummary{
        .{ .number = 12, .title = "first" },
        .{ .number = 18, .title = "second" },
    };
    var reader: std.Io.Reader = .fixed("2\n");
    var output: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try std.testing.expectEqual(@as(?usize, 1), try select(&issues, &reader, &writer));
}

test "selection can be cancelled and rejects an out of range number" {
    const issues = [_]github_cli.IssueSummary{.{ .number = 12, .title = "first" }};
    var cancel_reader: std.Io.Reader = .fixed("q\n");
    var cancel_output: [1024]u8 = undefined;
    var cancel_writer = std.Io.Writer.fixed(&cancel_output);
    try std.testing.expectEqual(@as(?usize, null), try select(
        &issues,
        &cancel_reader,
        &cancel_writer,
    ));

    var bad_reader: std.Io.Reader = .fixed("2\n");
    var bad_output: [1024]u8 = undefined;
    var bad_writer = std.Io.Writer.fixed(&bad_output);
    try std.testing.expectError(
        error.InvalidIssueSelection,
        select(&issues, &bad_reader, &bad_writer),
    );
}

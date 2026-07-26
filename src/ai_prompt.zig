const std = @import("std");
const source_issue = @import("source_issue.zig");

pub fn build(allocator: std.mem.Allocator, issue: *const source_issue.Issue) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\次のGitHub Issueを、ztodoで実行可能な具体的Taskへ分解してください。
        \\
        \\リポジトリ: {s}
        \\Issue番号: #{d}
        \\タイトル: {s}
        \\
        \\本文:
        \\{s}
        \\
        \\出力条件:
        \\- JSONだけを出力し、Markdownのコードフェンスや説明文を含めない
        \\- sourceは上記Issueの情報を正確に転記する
        \\- providerは "github-cli" とする
        \\- schema_versionは1とする
        \\- tasksは、数十分から数時間で完了できる具体的な作業へ分解する
        \\- tasksの各要素は {{"title":"..."}} の形式にする
        \\- completion_criteria、excluded、notesは文字列配列にする
        \\
        \\JSON形式:
        \\{{"schema_version":1,"source":{{"provider":"github-cli","repository":"owner/repo","issue_number":1,"issue_title":"Issue title"}},"summary":"概要","completion_criteria":["完了条件"],"tasks":[{{"title":"具体的なTask"}}],"excluded":[],"notes":[]}}
        \\
    , .{ issue.repository, issue.number, issue.title, issue.body });
}

test "prompt includes the selected issue and Proposal requirements" {
    const allocator = std.testing.allocator;
    var issue = try source_issue.init(
        allocator,
        "github-cli",
        "owner/repo",
        12,
        "テストを追加",
        "完了条件を確認する",
    );
    defer issue.deinit();
    const prompt = try build(allocator, &issue);
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "owner/repo") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "#12") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "完了条件を確認する") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"schema_version\":1") != null);
}

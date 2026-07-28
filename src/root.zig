pub const task = @import("task.zig");
pub const store = @import("store.zig");
pub const paths = @import("paths.zig");
pub const proposal = @import("proposal.zig");
pub const proposal_store = @import("proposal_store.zig");
pub const proposal_editor = @import("proposal_editor.zig");
pub const workflow_apply = @import("workflow_apply.zig");
pub const source_issue = @import("source_issue.zig");
pub const github_cli = @import("github_cli.zig");
pub const github_config = @import("github_config.zig");
pub const issue_selector = @import("issue_selector.zig");
pub const ai_prompt = @import("ai_prompt.zig");
pub const clipboard = @import("clipboard.zig");
pub const workflow_clipboard_import = @import("workflow_clipboard_import.zig");
pub const tui = @import("tui.zig");
pub const cli = @import("cli.zig");

test {
    _ = task;
    _ = store;
    _ = paths;
    _ = proposal;
    _ = proposal_store;
    _ = proposal_editor;
    _ = workflow_apply;
    _ = source_issue;
    _ = github_cli;
    _ = github_config;
    _ = issue_selector;
    _ = ai_prompt;
    _ = clipboard;
    _ = workflow_clipboard_import;
    _ = tui;
    _ = cli;
}

pub const task = @import("core/task.zig");
pub const store = @import("core/store.zig");
pub const paths = @import("core/paths.zig");
pub const proposal = @import("proposal/model.zig");
pub const proposal_store = @import("proposal/store.zig");
pub const proposal_editor = @import("proposal/editor.zig");
pub const workflow_apply = @import("proposal/apply.zig");
pub const source_issue = @import("integrations/github/issue.zig");
pub const github_cli = @import("integrations/github/client.zig");
pub const github_config = @import("integrations/github/config.zig");
pub const issue_selector = @import("integrations/github/selector.zig");
pub const ai_prompt = @import("integrations/github/prompt.zig");
pub const prompt_instructions = @import("integrations/github/prompt_instructions.zig");
pub const clipboard = @import("platform/clipboard.zig");
pub const workflow_clipboard_import = @import("proposal/clipboard_import.zig");
pub const tui = @import("tui/app.zig");
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
    _ = prompt_instructions;
    _ = clipboard;
    _ = workflow_clipboard_import;
    _ = tui;
    _ = cli;
}

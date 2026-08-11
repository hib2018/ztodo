const std = @import("std");
const paths = @import("../core/paths.zig");
const store = @import("../core/store.zig");
const proposal_mod = @import("../proposal/model.zig");
const proposal_store = @import("../proposal/store.zig");
const proposal_apply = @import("../proposal/apply.zig");
const proposal_import = @import("../proposal/clipboard_import.zig");
const clipboard = @import("../platform/clipboard.zig");
const github_config = @import("../integrations/github/config.zig");
const github_client = @import("../integrations/github/client.zig");
const github_prompt = @import("../integrations/github/prompt.zig");
const prompt_instructions = @import("../integrations/github/prompt_instructions.zig");
const prompt_editor = @import("../integrations/github/prompt_editor.zig");
const build_options = @import("build_options");

pub const min_columns: u16 = 48;
pub const min_rows: u16 = 12;

const panel_style = "\x1b[39m\x1b[49m";
const panel_heading_style = "\x1b[1;39m\x1b[49m";
const active_frame_style = "\x1b[38;2;87;149;209m\x1b[49m";
const active_heading_style = "\x1b[1;38;2;87;149;209m\x1b[49m";

const Size = struct {
    columns: u16,
    rows: u16,
};

const max_input_bytes = 1024;

const InputAction = enum { task_add, task_edit, proposal_add, proposal_edit, repository_add };

const InputState = struct {
    action: InputAction,
    target_id: ?u64 = null,
    buffer: [max_input_bytes]u8 = undefined,
    length: usize = 0,
    cursor: usize = 0,
    error_message: ?[]const u8 = null,

    fn init(action: InputAction, target_id: ?u64, initial: []const u8) InputState {
        var input: InputState = .{ .action = action, .target_id = target_id };
        input.length = @min(initial.len, input.buffer.len);
        @memcpy(input.buffer[0..input.length], initial[0..input.length]);
        input.cursor = input.length;
        return input;
    }

    fn value(self: *const InputState) []const u8 {
        return self.buffer[0..self.length];
    }

    fn displayValue(self: *const InputState) []const u8 {
        return completeUtf8Prefix(self.value());
    }

    fn append(self: *InputState, byte: u8) void {
        if (self.length == self.buffer.len) return;
        std.mem.copyBackwards(u8, self.buffer[self.cursor + 1 .. self.length + 1], self.buffer[self.cursor..self.length]);
        self.buffer[self.cursor] = byte;
        self.length += 1;
        self.cursor += 1;
        self.error_message = null;
    }

    fn backspace(self: *InputState) void {
        if (self.cursor == 0) return;
        const previous = previousCodepointStart(self.buffer[0..self.length], self.cursor);
        std.mem.copyForwards(u8, self.buffer[previous .. self.length - (self.cursor - previous)], self.buffer[self.cursor..self.length]);
        self.length -= self.cursor - previous;
        self.cursor = previous;
        self.error_message = null;
    }

    fn moveLeft(self: *InputState) void {
        if (self.cursor > 0) self.cursor = previousCodepointStart(self.buffer[0..self.length], self.cursor);
    }

    fn moveRight(self: *InputState) void {
        if (self.cursor >= self.length) return;
        const sequence_length = std.unicode.utf8ByteSequenceLength(self.buffer[self.cursor]) catch 1;
        self.cursor = @min(self.cursor + sequence_length, self.length);
    }
};

fn previousCodepointStart(text: []const u8, cursor: usize) usize {
    var previous = cursor - 1;
    while (previous > 0 and text[previous] & 0xc0 == 0x80) previous -= 1;
    return previous;
}

const Confirmation = union(enum) {
    delete_task: struct { id: u64, index: usize },
    clear_tasks,
    delete_proposal_task: usize,
    approve_proposal,
    delete_repository: usize,
};

const Screen = enum { tasks, proposal, repositories, issues, prompt, help };
const Focus = enum { tasks, right };
const pane_gap: u16 = 1;
const help_height: u16 = 4;

const RepositoryNode = struct {
    repository: []u8,
    expanded: bool = false,
    issues: ?github_client.IssueList = null,
    load_attempted: bool = false,
    load_error: ?[]const u8 = null,

    fn deinit(self: *RepositoryNode, allocator: std.mem.Allocator) void {
        allocator.free(self.repository);
        if (self.issues) |*issues| issues.deinit();
        self.* = undefined;
    }
};

const RepositoryTree = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(RepositoryNode) = .empty,

    fn init(allocator: std.mem.Allocator) RepositoryTree {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *RepositoryTree) void {
        for (self.nodes.items) |*node| node.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    fn find(self: *RepositoryTree, repository: []const u8) ?*RepositoryNode {
        for (self.nodes.items) |*node| {
            if (std.mem.eql(u8, node.repository, repository)) return node;
        }
        return null;
    }

    fn getOrCreate(self: *RepositoryTree, repository: []const u8) !*RepositoryNode {
        if (self.find(repository)) |node| return node;
        const copy = try self.allocator.dupe(u8, repository);
        errdefer self.allocator.free(copy);
        try self.nodes.append(self.allocator, .{ .repository = copy });
        return &self.nodes.items[self.nodes.items.len - 1];
    }

    fn issueCount(self: *const RepositoryTree, repository: []const u8) usize {
        for (self.nodes.items) |node| {
            if (std.mem.eql(u8, node.repository, repository))
                return if (node.expanded and node.issues != null) node.issues.?.items.len else 0;
        }
        return 0;
    }

    fn isExpanded(self: *const RepositoryTree, repository: []const u8) bool {
        for (self.nodes.items) |node| {
            if (std.mem.eql(u8, node.repository, repository)) return node.expanded;
        }
        return false;
    }
};

fn preloadRepositoryIssues(allocator: std.mem.Allocator, io: std.Io, config: ?*const github_config.Config, tree: *RepositoryTree) !void {
    const current = config orelse return;
    for (current.repositories) |repository| {
        const node = try tree.getOrCreate(repository);
        node.load_attempted = true;
        node.issues = github_client.listOpen(allocator, io, repository) catch |err| {
            node.load_error = githubIssueErrorMessage(err);
            continue;
        };
        node.load_error = null;
    }
}

pub const Key = enum {
    up,
    down,
    left,
    right,
    scroll_next,
    scroll_previous,
    move_up,
    move_down,
    add,
    edit,
    toggle,
    delete,
    clear,
    switch_screen,
    approve,
    import_proposal,
    open_repositories,
    open_issues,
    open_proposal,
    open_prompt,
    focus_tasks,
    help,
    accept,
    backspace,
    quit,
    other,
};

const Event = union(enum) {
    key: Key,
    byte: u8,
};

pub const Popup = union(enum) {
    help,
    input: InputState,
    confirmation: Confirmation,
    error_message: []const u8,
};

pub const Model = struct {
    screen: Screen = .repositories,
    focus: Focus = .tasks,
    selected: usize = 0,
    proposal_selected: usize = 0,
    repository_selected: usize = 0,
    repository_issue_selected: ?usize = null,
    issue_selected: usize = 0,
    quit: bool = false,
    popup: ?Popup = null,

    pub fn update(self: *Model, key: Key, task_count: usize) void {
        switch (key) {
            .up, .scroll_previous => if (self.selected > 0) {
                self.selected -= 1;
            },
            .down, .scroll_next => if (self.selected + 1 < task_count) {
                self.selected += 1;
            },
            .left, .right, .move_up, .move_down, .add, .edit, .toggle, .delete, .clear, .switch_screen, .approve, .import_proposal, .open_repositories, .open_issues, .open_proposal, .open_prompt, .focus_tasks, .help, .accept, .backspace => {},
            .quit => self.quit = true,
            .other => {},
        }
        if (task_count == 0) self.selected = 0;
    }
};

pub fn decodeKey(first: u8, second: ?u8, third: ?u8) Key {
    if (first == '\r' or first == '\n') return .accept;
    if (first == '?') return .help;
    if (first == 'q' or first == 3) return .quit;
    if (first == 'k') return .up;
    if (first == 'j') return .down;
    if (first == 'K') return .move_up;
    if (first == 'J') return .move_down;
    if (first == 0x1b and second == '[' and third == 'A') return .up;
    if (first == 0x1b and second == '[' and third == 'B') return .down;
    if (first == 0x1b and second == '[' and third == 'D') return .left;
    if (first == 0x1b and second == '[' and third == 'C') return .right;
    return .other;
}

pub fn decodeMouse(sequence: []const u8) Key {
    const separator = std.mem.indexOfScalar(u8, sequence, ';') orelse return .other;
    const button = std.fmt.parseInt(u8, sequence[0..separator], 10) catch return .other;
    return switch (button) {
        64 => .scroll_next,
        65 => .scroll_previous,
        else => .other,
    };
}

pub fn render(writer: *std.Io.Writer, data: *const store.Data, model: Model, columns: u16, rows: u16) !void {
    return renderApp(writer, data, null, model, columns, rows);
}

fn renderApp(writer: *std.Io.Writer, data: *const store.Data, proposal: ?*const proposal_mod.Proposal, model: Model, columns: u16, rows: u16) !void {
    return renderApplication(writer, data, proposal, null, null, null, "", model, columns, rows);
}

fn renderApplication(writer: *std.Io.Writer, data: *const store.Data, proposal: ?*const proposal_mod.Proposal, config: ?*const github_config.Config, issues: ?*const github_client.IssueList, repository_tree: ?*const RepositoryTree, instructions: []const u8, model: Model, columns: u16, rows: u16) !void {
    try writer.writeAll("\x1b[2J\x1b[H");
    if (columns < min_columns or rows < min_rows) {
        try writer.print("ztodo: terminal too small ({d}x{d}); need at least {d}x{d}.\r\n", .{
            columns, rows, min_columns, min_rows,
        });
        return;
    }

    const main_height = rows - help_height - pane_gap - 1;
    const available_columns = columns - pane_gap;
    const tasks_width = (available_columns * 3) / 5;
    const right_width = available_columns - tasks_width;
    const tasks_panel: Panel = .{ .top = 1, .left = 1, .width = tasks_width, .height = main_height };
    const right_panel: Panel = .{ .top = 1, .left = tasks_width + pane_gap + 1, .width = right_width, .height = main_height };
    const help_panel: Panel = .{ .top = main_height + pane_gap + 1, .left = 1, .width = columns, .height = help_height };
    const dimmed = false;
    try renderBase(writer, data, model, tasks_panel, dimmed);
    switch (model.screen) {
        .tasks, .repositories => try renderRepositoriesBase(writer, config, repository_tree, model, right_panel, dimmed),
        .proposal => try renderProposalBase(writer, proposal, model, right_panel, dimmed),
        .issues => try renderIssuesBase(writer, issues, model, right_panel, dimmed),
        .prompt => try renderPromptBase(writer, instructions, model, right_panel, dimmed),
        .help => try renderHelpBase(writer, model, right_panel, dimmed),
    }
    try renderContextHelp(writer, help_panel, model, dimmed);
    var version_buffer: [64]u8 = undefined;
    const version = try std.fmt.bufPrint(&version_buffer, "ztodo v{s}", .{build_options.version});
    try writer.print("\x1b[{d};{d}H{s}{s}\x1b[0m", .{ rows, columns -| @as(u16, @intCast(displayWidth(version))) + 1, panel_style, version });
    if (model.popup) |popup|
        try renderPopup(writer, popup, if (model.focus == .tasks) .tasks else model.screen, columns, rows)
    else
        try writer.writeAll("\x1b[?25l");
}

fn renderBase(writer: *std.Io.Writer, data: *const store.Data, model: Model, panel: Panel, dimmed: bool) !void {
    const style = if (dimmed) "\x1b[2m" else "";
    try renderPanel(writer, panel, dimmed, model.focus == .tasks, null);
    try renderPaneHeading(writer, panel, " Tasks", dimmed, model.focus == .tasks);
    try popupLine(writer, panel.top + 2, panel.left, panel.width, "├", "─", "┤", paneFrameStyle(dimmed, model.focus == .tasks));

    const task_row = panel.top + 3;
    const available_rows: usize = panel.height -| 4;
    if (data.tasks.items.len == 0) {
        try popupText(writer, task_row, panel.left, "  No tasks.", false, dimmed);
    } else {
        const content_columns: usize = panel.width -| 2;
        const prefix_columns: usize = 12;
        const first_columns = content_columns -| prefix_columns;
        const continuation_columns = first_columns -| 1;
        const start = visibleStart(data, model.selected, available_rows, first_columns, continuation_columns);
        var row = task_row;
        for (data.tasks.items[start..], start..) |task, index| {
            if (row >= panel.bottom() - 1) break;
            row += @intCast(try renderTask(
                writer,
                task,
                index == model.selected and model.focus == .tasks,
                style,
                row,
                panel.left + 1,
                panel.bottom(),
                first_columns,
                continuation_columns,
            ));
        }
    }
}

fn renderProposalBase(writer: *std.Io.Writer, proposal: ?*const proposal_mod.Proposal, model: Model, panel: Panel, dimmed: bool) !void {
    try renderPanel(writer, panel, dimmed, model.focus == .right, null);
    try renderPaneHeading(writer, panel, " Proposal", dimmed, model.focus == .right);
    try popupLine(writer, panel.top + 2, panel.left, panel.width, "├", "─", "┤", paneFrameStyle(dimmed, model.focus == .right));
    const current = proposal orelse {
        try popupTextClipped(writer, panel, panel.top + 4, " Proposalはありません。iでClipboardから取り込めます。", false, dimmed);
        return;
    };
    var source_buffer: [512]u8 = undefined;
    const source = try std.fmt.bufPrint(&source_buffer, " {s}#{d}  {s}", .{ current.source.repository, current.source.issue_number, current.source.issue_title });
    var row = panel.top + 3;
    row += try renderWrappedRightLine(writer, row, panel.bottom(), panel, source, 1, false, dimmed);
    row += 1;
    for (current.tasks.items, 0..) |candidate, index| {
        if (row >= panel.bottom()) break;
        var prefix_buffer: [32]u8 = undefined;
        const selected = index == model.proposal_selected and model.focus == .right;
        const prefix = try std.fmt.bufPrint(&prefix_buffer, "{s} {d: >2}. ", .{ if (selected) ">" else " ", index + 1 });
        var line_buffer: [1024]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buffer, "{s}{s}", .{ prefix, candidate.title });
        row += try renderWrappedRightLine(writer, row, panel.bottom(), panel, line, displayWidth(prefix), selected, dimmed);
    }
    if (current.tasks.items.len == 0) try popupText(writer, row, panel.left, " Task候補はありません。", false, dimmed);
}

fn renderRepositoriesBase(writer: *std.Io.Writer, config: ?*const github_config.Config, repository_tree: ?*const RepositoryTree, model: Model, panel: Panel, dimmed: bool) !void {
    try renderPanel(writer, panel, dimmed, model.focus == .right, null);
    try renderPaneHeading(writer, panel, " Repositories / Issues", dimmed, model.focus == .right);
    try popupLine(writer, panel.top + 2, panel.left, panel.width, "├", "─", "┤", paneFrameStyle(dimmed, model.focus == .right));
    const repositories = if (config) |value| value.repositories else &.{};
    var row = panel.top + 4;
    if (repositories.len == 0) {
        try popupTextClipped(writer, panel, row, " Repositoryは登録されていません。", false, dimmed);
    } else {
        const available_rows: usize = panel.height -| 4;
        const selected_ordinal = if (repository_tree) |tree| repositoryTreeSelectionOrdinal(repositories, tree, model) else model.repository_selected;
        const start = if (selected_ordinal >= available_rows) selected_ordinal - available_rows + 1 else 0;
        var ordinal: usize = 0;
        outer: for (repositories, 0..) |repository, index| {
            const expanded = if (repository_tree) |tree| tree.isExpanded(repository) else false;
            if (ordinal >= start) {
                if (row >= panel.bottom()) break;
                var prefix_buffer: [16]u8 = undefined;
                const selected = index == model.repository_selected and model.repository_issue_selected == null and model.focus == .right;
                const prefix = try std.fmt.bufPrint(&prefix_buffer, "{s} {s} ", .{ if (selected) ">" else " ", if (expanded) "▾" else "▸" });
                row += try renderRepositoryTreeLine(writer, row, panel, prefix, repository, selected, dimmed);
            }
            ordinal += 1;

            const node = if (repository_tree) |tree| treeNode(tree, repository) else null;
            if (node) |current| if (current.expanded and current.issues != null) {
                for (current.issues.?.items, 0..) |issue, issue_index| {
                    if (ordinal >= start) {
                        if (row >= panel.bottom()) break :outer;
                        const selected = index == model.repository_selected and model.repository_issue_selected == issue_index and model.focus == .right;
                        var prefix_buffer: [64]u8 = undefined;
                        const prefix = try std.fmt.bufPrint(&prefix_buffer, "  {s} #{d} ", .{ if (selected) ">" else " ", issue.number });
                        row += try renderRepositoryTreeLine(writer, row, panel, prefix, issue.title, selected, dimmed);
                    }
                    ordinal += 1;
                }
            };
        }
    }
}

fn treeNode(tree: *const RepositoryTree, repository: []const u8) ?*const RepositoryNode {
    for (tree.nodes.items) |*node| {
        if (std.mem.eql(u8, node.repository, repository)) return node;
    }
    return null;
}

fn repositoryTreeSelectionOrdinal(repositories: []const []const u8, tree: *const RepositoryTree, model: Model) usize {
    var ordinal: usize = 0;
    for (repositories, 0..) |repository, index| {
        if (index == model.repository_selected)
            return ordinal + if (model.repository_issue_selected) |issue_index| issue_index + 1 else 0;
        ordinal += 1 + tree.issueCount(repository);
    }
    return ordinal;
}

fn renderRepositoryTreeLine(writer: *std.Io.Writer, row: u16, panel: Panel, prefix: []const u8, text: []const u8, selected: bool, dimmed: bool) !u16 {
    var line_buffer: [1024]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buffer, "{s}{s}", .{ prefix, text });
    return renderWrappedRightLine(writer, row, panel.bottom(), panel, line, displayWidth(prefix), selected, dimmed);
}

fn renderWrappedRightLine(
    writer: *std.Io.Writer,
    first_row: u16,
    row_limit: u16,
    panel: Panel,
    text: []const u8,
    requested_indent: usize,
    selected: bool,
    dimmed: bool,
) !u16 {
    const content_columns: usize = panel.width -| 2;
    const continuation_indent = @min(requested_indent, content_columns / 2);
    var offset: usize = 0;
    var lines: u16 = 0;
    while (offset < text.len and first_row + lines < row_limit) : (lines += 1) {
        const indent = if (lines == 0) 0 else continuation_indent;
        const columns = content_columns -| indent;
        const length = wrapChunkLength(text[offset..], columns);
        const chunk = text[offset .. offset + length];
        try writer.print("\x1b[{d};{d}H{s}{s}", .{
            first_row + lines,
            panel.left + 1,
            panelStyle(dimmed),
            if (selected) "\x1b[7m" else "",
        });
        var spaces = indent;
        while (spaces > 0) : (spaces -= 1) try writer.writeByte(' ');
        try writer.writeAll(chunk);
        if (selected) {
            var padding = columns - displayWidth(chunk);
            while (padding > 0) : (padding -= 1) try writer.writeByte(' ');
        }
        try writer.writeAll("\x1b[0m");
        offset += length;
    }
    return lines;
}

fn renderIssuesBase(writer: *std.Io.Writer, issues: ?*const github_client.IssueList, model: Model, panel: Panel, dimmed: bool) !void {
    try renderPanel(writer, panel, dimmed, model.focus == .right, null);
    try renderPaneHeading(writer, panel, " GitHub Issues", dimmed, model.focus == .right);
    try popupLine(writer, panel.top + 2, panel.left, panel.width, "├", "─", "┤", paneFrameStyle(dimmed, model.focus == .right));
    const items = if (issues) |value| value.items else &.{};
    var row = panel.top + 4;
    if (items.len == 0) {
        try popupTextClipped(writer, panel, row, " Open Issueはありません。", false, dimmed);
    } else for (items, 0..) |issue, index| {
        if (row >= panel.bottom()) break;
        var prefix_buffer: [512]u8 = undefined;
        const selected = index == model.issue_selected and model.focus == .right;
        const prefix = try std.fmt.bufPrint(&prefix_buffer, "{s} {s}#{d} ", .{ if (selected) ">" else " ", issue.repository, issue.number });
        var line_buffer: [1024]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buffer, "{s}{s}", .{ prefix, issue.title });
        row += try renderWrappedRightLine(writer, row, panel.bottom(), panel, line, displayWidth(prefix), selected, dimmed);
    }
}

fn renderPromptBase(writer: *std.Io.Writer, instructions: []const u8, model: Model, panel: Panel, dimmed: bool) !void {
    try renderPanel(writer, panel, dimmed, model.focus == .right, null);
    try renderPaneHeading(writer, panel, " プロンプト編集", dimmed, model.focus == .right);
    try popupLine(writer, panel.top + 2, panel.left, panel.width, "├", "─", "┤", paneFrameStyle(dimmed, model.focus == .right));
    try popupTextClipped(writer, panel, panel.top + 3, " AIへ追加する指示", true, dimmed);
    if (instructions.len == 0)
        try popupTextClipped(writer, panel, panel.top + 5, " 追加指示は設定されていません。", false, dimmed)
    else
        try renderPopupWrapped(writer, panel, panel.top + 5, instructions);
}

fn renderHelpBase(writer: *std.Io.Writer, model: Model, panel: Panel, dimmed: bool) !void {
    try renderPanel(writer, panel, dimmed, model.focus == .right, null);
    try renderPaneHeading(writer, panel, " ヘルプ", dimmed, model.focus == .right);
    try popupLine(writer, panel.top + 2, panel.left, panel.width, "├", "─", "┤", paneFrameStyle(dimmed, model.focus == .right));
    const lines = [_][]const u8{
        " Tab       Tasksと右ペインのフォーカスを切り替える",
        " j / ↓     次の項目を選択する",
        " k / ↑     前の項目を選択する",
        " Enter      選択IssueのAI向けプロンプトをコピーする",
        " q          戻る、または終了する",
        " Ctrl-C     入力をキャンセル、通常時は終了する",
        "",
        " タスク: a 追加  e 編集  Space 完了  d 削除  K/J 並べ替え",
        " Repository: a 追加  d 削除",
        " Proposal: p 開く  i 取込  A 承認",
        " Issue: g 開く  Enter プロンプトをコピー",
    };
    for (lines, 0..) |line, index| {
        const row = panel.top + 4 + @as(u16, @intCast(index));
        if (row >= panel.bottom()) break;
        try popupTextClipped(writer, panel, row, line, false, dimmed);
    }
}

fn renderContextHelp(writer: *std.Io.Writer, panel: Panel, model: Model, dimmed: bool) !void {
    try renderPanel(writer, panel, dimmed, false, " Help ");
    const common = if (model.focus == .tasks)
        " Tab: 右ペインへ  ?: 詳細ヘルプ  q: 終了  p: Proposal  g: 全Issue  P: プロンプト"
    else
        " Tab: Tasksへ  ?: 詳細ヘルプ  q: 戻る";
    const context = if (model.focus == .tasks)
        " Tasks  j/k: 選択  Space: 完了切替  a: 追加  e: 編集  d: 削除  K/J: 並べ替え"
    else switch (model.screen) {
        .tasks, .repositories => " Repositories  j/k: 選択  Space: 開閉  Enter: 選択Issueのプロンプトをコピー  r: 再取得",
        .proposal => " Proposal  j/k: 選択  a: 追加  e: 編集  d: 削除  K/J: 並べ替え  i: 取込  A: 承認",
        .issues => " Issues  j/k: 選択  Enter: 選択Issueのプロンプトをコピー",
        .prompt => " Prompt  e: 外部エディタで追加指示を編集",
        .help => " Help  ?: 画面別の詳しいキー操作を表示",
    };
    try popupTextClipped(writer, panel, panel.top + 1, common, true, dimmed);
    try popupTextClipped(writer, panel, panel.top + 2, context, false, dimmed);
}

fn visibleStart(data: *const store.Data, selected: usize, available_rows: usize, first_columns: usize, continuation_columns: usize) usize {
    var start: usize = 0;
    var used: usize = 0;
    for (data.tasks.items[0 .. selected + 1]) |task| {
        used += wrappedLineCount(task.title, first_columns, continuation_columns);
    }
    while (used > available_rows and start < selected) : (start += 1) {
        used -= wrappedLineCount(data.tasks.items[start].title, first_columns, continuation_columns);
    }
    return start;
}

fn renderTask(
    writer: *std.Io.Writer,
    task: store.Task,
    selected: bool,
    style: []const u8,
    first_row: u16,
    first_column: u16,
    row_limit: u16,
    first_columns: usize,
    continuation_columns: usize,
) !usize {
    const marker = if (selected) ">" else " ";
    const task_style = if (task.status == .done) "\x1b[2;9m" else style;
    var prefix_buffer: [64]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buffer, "{s} [{s}] {d: >4}  ", .{
        marker,
        if (task.status == .done) "x" else " ",
        task.id,
    });

    var offset: usize = 0;
    var row = first_row;
    var line: usize = 0;
    while (offset < task.title.len and row < row_limit) : ({
        row += 1;
        line += 1;
    }) {
        const limit = if (line == 0) first_columns else continuation_columns;
        const length = wrapChunkLength(task.title[offset..], limit);
        const chunk = task.title[offset .. offset + length];
        const padding = limit - displayWidth(chunk);
        const column = if (line == 0) first_column else first_column + 13;
        try writer.print("\x1b[{d};{d}H{s}{s}{s}{s}", .{
            row,
            column,
            task_style,
            if (selected) "\x1b[7m" else "",
            if (line == 0) prefix else "",
            chunk,
        });
        if (selected or task.status == .done) {
            var remaining = padding;
            while (remaining > 0) : (remaining -= 1) try writer.writeByte(' ');
        }
        try writer.writeAll("\x1b[0m");
        offset += length;
    }
    return @max(line, 1);
}

fn wrappedLineCount(text: []const u8, first_columns: usize, continuation_columns: usize) usize {
    if (text.len == 0) return 1;
    var offset: usize = 0;
    var lines: usize = 0;
    while (offset < text.len) : (lines += 1) {
        offset += wrapChunkLength(text[offset..], if (lines == 0) first_columns else continuation_columns);
    }
    return lines;
}

fn wrapChunkLength(text: []const u8, max_columns: usize) usize {
    if (text.len == 0) return 0;
    var offset: usize = 0;
    var columns: usize = 0;
    while (offset < text.len) {
        const unit = displayUnit(text[offset..]);
        const width = codepointWidth(unit.codepoint);
        if (offset > 0 and columns + width > max_columns) break;
        columns += width;
        offset += unit.length;
    }
    return @max(offset, 1);
}

fn displayWidth(text: []const u8) usize {
    var offset: usize = 0;
    var columns: usize = 0;
    while (offset < text.len) {
        const unit = displayUnit(text[offset..]);
        columns += codepointWidth(unit.codepoint);
        offset += unit.length;
    }
    return columns;
}

const DisplayUnit = struct { length: usize, codepoint: u21 };

fn displayUnit(text: []const u8) DisplayUnit {
    const sequence_length = std.unicode.utf8ByteSequenceLength(text[0]) catch
        return .{ .length = 1, .codepoint = text[0] };
    if (sequence_length > text.len)
        return .{ .length = 1, .codepoint = text[0] };
    const codepoint = std.unicode.utf8Decode(text[0..sequence_length]) catch
        return .{ .length = 1, .codepoint = text[0] };
    return .{ .length = sequence_length, .codepoint = codepoint };
}

fn completeUtf8Prefix(text: []const u8) []const u8 {
    var offset: usize = 0;
    while (offset < text.len) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(text[offset]) catch return text[0..offset];
        if (sequence_length > text.len - offset) return text[0..offset];
        _ = std.unicode.utf8Decode(text[offset .. offset + sequence_length]) catch return text[0..offset];
        offset += sequence_length;
    }
    return text;
}

fn codepointWidth(codepoint: u21) usize {
    if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0)) return 0;
    if ((codepoint >= 0x0300 and codepoint <= 0x036f) or
        (codepoint >= 0x1ab0 and codepoint <= 0x1aff) or
        (codepoint >= 0x1dc0 and codepoint <= 0x1dff) or
        (codepoint >= 0x20d0 and codepoint <= 0x20ff) or
        (codepoint >= 0xfe20 and codepoint <= 0xfe2f)) return 0;
    if ((codepoint >= 0x1100 and codepoint <= 0x115f) or
        (codepoint >= 0x2e80 and codepoint <= 0xa4cf) or
        (codepoint >= 0xac00 and codepoint <= 0xd7a3) or
        (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0xfe10 and codepoint <= 0xfe19) or
        (codepoint >= 0xfe30 and codepoint <= 0xfe6f) or
        (codepoint >= 0xff00 and codepoint <= 0xff60) or
        (codepoint >= 0xffe0 and codepoint <= 0xffe6) or
        (codepoint >= 0x1f300 and codepoint <= 0x1faff) or
        (codepoint >= 0x20000 and codepoint <= 0x3fffd)) return 2;
    return 1;
}

const Panel = struct {
    top: u16,
    left: u16,
    width: u16,
    height: u16,

    fn init(columns: u16, rows: u16, margin: u16) Panel {
        const horizontal_margin = @min(margin, (columns -| min_columns) / 2);
        const vertical_margin = @min(margin, (rows -| min_rows) / 2);
        return .{
            .top = vertical_margin + 1,
            .left = horizontal_margin + 1,
            .width = columns -| (horizontal_margin * 2),
            .height = rows -| (vertical_margin * 2),
        };
    }

    fn bottom(self: Panel) u16 {
        return self.top + self.height - 1;
    }
};

fn panelStyle(dimmed: bool) []const u8 {
    return if (dimmed) "\x1b[2;39m\x1b[49m" else panel_style;
}

fn paneFrameStyle(dimmed: bool, active: bool) []const u8 {
    return if (active and !dimmed) active_frame_style else panelStyle(dimmed);
}

fn renderPaneHeading(writer: *std.Io.Writer, panel: Panel, heading: []const u8, dimmed: bool, active: bool) !void {
    const length = wrapChunkLength(heading, panel.width -| 2);
    const style = if (active and !dimmed) active_heading_style else if (dimmed) panelStyle(true) else panel_heading_style;
    try writer.print("\x1b[{d};{d}H{s}{s}\x1b[0m", .{ panel.top + 1, panel.left + 1, style, heading[0..length] });
}

fn renderPanel(writer: *std.Io.Writer, panel: Panel, dimmed: bool, active: bool, top_label: ?[]const u8) !void {
    const content_style = panelStyle(dimmed);
    const frame_style = paneFrameStyle(dimmed, active);
    try popupLine(writer, panel.top, panel.left, panel.width, "╭", "─", "╮", frame_style);
    if (top_label) |label| {
        const label_width: u16 = @intCast(@min(displayWidth(label), panel.width -| 2));
        const label_start = panel.left + 2;
        const length = wrapChunkLength(label, label_width);
        try writer.print("\x1b[{d};{d}H{s}{s}\x1b[0m", .{ panel.top, label_start, frame_style, label[0..length] });
    }
    var row = panel.top + 1;
    while (row < panel.bottom()) : (row += 1) try popupContent(writer, row, panel.left, panel.width, frame_style, content_style);
    try popupLine(writer, panel.bottom(), panel.left, panel.width, "╰", "─", "╯", frame_style);
}

fn renderPopup(writer: *std.Io.Writer, popup: Popup, screen: Screen, columns: u16, rows: u16) !void {
    const margin: u16 = switch (popup) {
        .help => 1,
        else => 12,
    };
    const panel = Panel.init(columns, rows, margin);
    try renderPanel(writer, panel, false, true, null);

    var heading_buffer: [128]u8 = undefined;
    const heading = switch (popup) {
        .help => try std.fmt.bufPrint(&heading_buffer, " ヘルプ  ztodo v{s}", .{build_options.version}),
        .input => |input| switch (input.action) {
            .task_add => " Taskを追加",
            .task_edit => " Taskを編集",
            .proposal_add => " ProposalへTask候補を追加",
            .proposal_edit => " ProposalのTask候補を編集",
            .repository_add => " Repositoryを追加",
        },
        .confirmation => |confirmation| switch (confirmation) {
            .delete_task => " Taskを削除しますか？",
            .clear_tasks => " 全Taskを削除しますか？",
            .delete_proposal_task => " Task候補を削除しますか？",
            .approve_proposal => " Proposalを承認しますか？",
            .delete_repository => " Repositoryを削除しますか？",
        },
        .error_message => " エラー",
    };
    try popupText(writer, panel.top + 1, panel.left, heading, true, false);
    switch (popup) {
        .help => {
            const lines: []const []const u8 = switch (screen) {
                .tasks => &.{
                    " j / ↓ : 次のTask",
                    " k / ↑ : 前のTask",
                    " a     : Taskを追加",
                    " e     : Taskを編集",
                    " Space : 完了状態を切り替え",
                    " d     : Taskを削除",
                    " C     : 全Taskを削除",
                    " K / J : Taskを並べ替え",
                    " p     : Proposalを開く",
                    " P     : プロンプト編集を開く",
                    " r     : Repositoriesを開く",
                    " g     : GitHub Issuesを開く",
                    " q     : 終了",
                },
                .proposal => &.{
                    " j / ↓ : 次のTask候補",
                    " k / ↑ : 前のTask候補",
                    " a     : Task候補を追加",
                    " e     : Task候補を編集",
                    " d     : Task候補を削除",
                    " K / J : Task候補を並べ替え",
                    " A     : Proposalを承認",
                    " i     : Clipboardから取り込む",
                    " q     : Tasksへ戻る",
                },
                .repositories => &.{
                    " j / ↓ : 次のRepositoryまたはIssueを選択",
                    " k / ↑ : 前のRepositoryまたはIssueを選択",
                    " Space : 選択RepositoryのIssueを展開・折りたたみ",
                    " Enter : 選択IssueのAI向けプロンプトをClipboardへコピー",
                    " r     : 選択RepositoryのOpen Issueを再取得",
                    " a     : Repositoryを一覧へ追加",
                    " d     : 選択Repositoryを確認後に削除",
                    " q     : Tasksへフォーカスを戻す",
                },
                .issues => &.{
                    " j / ↓ : 次のIssue",
                    " k / ↑ : 前のIssue",
                    " Enter : プロンプトをコピー",
                    " q     : Tasksへ戻る",
                },
                .prompt => &.{
                    " e     : 外部エディタで編集",
                    " Tab   : Tasksへフォーカスを移す",
                    " q     : Repositories / Issuesへ戻る",
                },
                .help => &.{
                    " Tab   : Tasksへフォーカスを移す",
                    " q     : Repositories / Issuesへ戻る",
                },
            };
            for (lines, 0..) |line, index| try popupText(writer, panel.top + 3 + @as(u16, @intCast(index)), panel.left, line, false, false);
        },
        .input => |input| {
            try popupText(writer, panel.top + 3, panel.left, if (input.action == .repository_add) " Repository:" else " タイトル:", false, false);
            try renderPopupWrapped(writer, panel, panel.top + 4, input.displayValue());
            if (input.error_message) |message|
                try popupText(writer, panel.bottom() - 3, panel.left, message, false, false);
        },
        .confirmation => |confirmation| switch (confirmation) {
            .delete_task => |target| {
                var message_buffer: [128]u8 = undefined;
                const message = try std.fmt.bufPrint(&message_buffer, " Task {d}を削除します。この操作は元に戻せません。", .{target.id});
                try renderPopupWrapped(writer, panel, panel.top + 3, message);
            },
            .clear_tasks => try renderPopupWrapped(writer, panel, panel.top + 3, " すべてのTaskを削除し、次のIDを1へ戻します。この操作は元に戻せません。"),
            .delete_proposal_task => |index| {
                var message_buffer: [128]u8 = undefined;
                const message = try std.fmt.bufPrint(&message_buffer, " ProposalのTask候補 {d}を削除します。", .{index + 1});
                try renderPopupWrapped(writer, panel, panel.top + 3, message);
            },
            .approve_proposal => try renderPopupWrapped(writer, panel, panel.top + 3, " Proposalの全Task候補をTask一覧へ登録します。"),
            .delete_repository => |index| {
                var message_buffer: [128]u8 = undefined;
                const message = try std.fmt.bufPrint(&message_buffer, " Repository {d}を設定から削除します。", .{index + 1});
                try renderPopupWrapped(writer, panel, panel.top + 3, message);
            },
        },
        .error_message => |message| {
            try popupText(writer, panel.top + 3, panel.left, message, false, false);
        },
    }
    try popupText(writer, panel.bottom() - 1, panel.left, switch (popup) {
        .input => " ←/→: カーソル移動   Enter: 保存   Ctrl-C: キャンセル",
        .confirmation => " y: 実行   n/q: キャンセル",
        else => " Enter / q: 閉じる",
    }, false, false);
    switch (popup) {
        .input => |input| try renderInputCursor(writer, panel, input),
        else => try writer.writeAll("\x1b[?25l"),
    }
}

const CursorPosition = struct { row: u16, column: u16 };

fn inputCursorPosition(panel: Panel, text: []const u8) CursorPosition {
    const first_row = panel.top + 4;
    const first_column = panel.left + 2;
    const columns: usize = panel.width -| 4;
    const last_row = panel.bottom() -| 3;
    if (text.len == 0 or columns == 0) return .{ .row = first_row, .column = first_column };

    var offset: usize = 0;
    var row = first_row;
    while (offset < text.len) {
        const length = wrapChunkLength(text[offset..], columns);
        const width = displayWidth(text[offset .. offset + length]);
        offset += length;
        if (offset == text.len and width < columns)
            return .{ .row = @min(row, last_row), .column = first_column + @as(u16, @intCast(width)) };
        if (row >= last_row) return .{ .row = last_row, .column = first_column };
        row += 1;
    }
    return .{ .row = @min(row, last_row), .column = first_column };
}

fn renderInputCursor(writer: *std.Io.Writer, panel: Panel, input: InputState) !void {
    const visible = input.displayValue();
    const cursor = @min(input.cursor, visible.len);
    const position = inputCursorPosition(panel, visible[0..cursor]);
    try writer.print("\x1b[?25h\x1b[{d};{d}H", .{ position.row, position.column });
}

fn renderPopupWrapped(writer: *std.Io.Writer, panel: Panel, first_row: u16, text: []const u8) !void {
    var offset: usize = 0;
    var row = first_row;
    const columns: usize = panel.width -| 4;
    while (offset < text.len and row < panel.bottom() - 2) : (row += 1) {
        const remaining = text[offset..];
        const newline = std.mem.indexOfScalar(u8, remaining, '\n');
        const line = if (newline) |index| remaining[0..index] else remaining;
        if (line.len == 0) {
            offset += if (newline != null) 1 else 0;
            continue;
        }
        const length = wrapChunkLength(line, columns);
        try popupText(writer, row, panel.left + 1, line[0..length], false, false);
        offset += length;
        if (length == line.len and newline != null) offset += 1;
    }
}

fn popupLine(writer: *std.Io.Writer, row: u16, column: u16, width: u16, left_edge: []const u8, fill: []const u8, right_edge: []const u8, style: []const u8) !void {
    try writer.print("\x1b[{d};{d}H{s}{s}", .{ row, column, style, left_edge });
    var index: u16 = 0;
    while (index < width -| 2) : (index += 1) try writer.writeAll(fill);
    try writer.print("{s}\x1b[0m", .{right_edge});
}

fn popupContent(writer: *std.Io.Writer, row: u16, column: u16, width: u16, frame_style: []const u8, content_style: []const u8) !void {
    try writer.print("\x1b[{d};{d}H{s}│{s}", .{ row, column, frame_style, content_style });
    var index: u16 = 0;
    while (index < width -| 2) : (index += 1) try writer.writeByte(' ');
    try writer.print("{s}│\x1b[0m", .{frame_style});
}

fn popupText(writer: *std.Io.Writer, row: u16, column: u16, content: []const u8, emphasized: bool, dimmed: bool) !void {
    try writer.print("\x1b[{d};{d}H{s}{s}\x1b[0m", .{
        row,
        column + 1,
        if (emphasized and !dimmed) panel_heading_style else panelStyle(dimmed),
        content,
    });
}

fn popupTextClipped(writer: *std.Io.Writer, panel: Panel, row: u16, content: []const u8, emphasized: bool, dimmed: bool) !void {
    const length = wrapChunkLength(content, panel.width -| 2);
    try popupText(writer, row, panel.left, content[0..length], emphasized, dimmed);
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, path: []const u8, proposal_path: []const u8, config_path: []const u8, instructions_path: []const u8, data: *store.Data) !void {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    if (!try stdin.isTty(io) or !try stdout.isTty(io)) return error.NotATerminal;
    try stdout.enableAnsiEscapeCodes(io);

    const original = try std.posix.tcgetattr(stdin.handle);
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin.handle, .FLUSH, raw);
    defer std.posix.tcsetattr(stdin.handle, .FLUSH, original) catch {};

    var out_buffer: [8192]u8 = undefined;
    var out = stdout.writer(io, &out_buffer);
    defer {
        out.interface.writeAll("\x1b[?1006l\x1b[?1000l\x1b[?25h\x1b[?1049l") catch {};
        out.interface.flush() catch {};
    }
    try out.interface.writeAll("\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1006h");

    var in_buffer: [64]u8 = undefined;
    var input = stdin.readerStreaming(io, &in_buffer);
    var model: Model = .{};
    var proposal: ?proposal_mod.Proposal = proposal_store.load(allocator, io, proposal_path) catch |err| switch (err) {
        error.ProposalNotFound => null,
        else => return err,
    };
    defer if (proposal) |*value| value.deinit();
    var config: ?github_config.Config = github_config.load(allocator, io, config_path) catch |err| switch (err) {
        error.GitHubConfigNotFound => null,
        else => return err,
    };
    defer if (config) |*value| value.deinit();
    var instructions = try prompt_instructions.load(allocator, io, instructions_path);
    defer allocator.free(instructions);
    var issues: ?github_client.IssueList = null;
    defer if (issues) |*value| value.deinit();
    var repository_tree = RepositoryTree.init(allocator);
    defer repository_tree.deinit();
    try preloadRepositoryIssues(allocator, io, if (config) |*value| value else null, &repository_tree);
    while (!model.quit) {
        const size = terminalSize(io, stdout);
        try renderApplication(&out.interface, data, if (proposal) |*value| value else null, if (config) |*value| value else null, if (issues) |*value| value else null, &repository_tree, instructions, model, size.columns, size.rows);
        try out.interface.flush();
        const event = readInputEvent(&input.interface) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        if (model.popup != null) {
            try handlePopupEvent(allocator, io, path, proposal_path, config_path, data, &proposal, &config, &model, event);
            continue;
        }
        const key = switch (event) {
            .key => |key| key,
            .byte => |byte| commandKey(byte),
        };
        if (key == .switch_screen) {
            model.focus = if (model.focus == .tasks) .right else .tasks;
            continue;
        }
        if (key == .focus_tasks) {
            model.focus = .tasks;
            continue;
        }
        if (key == .open_proposal and model.focus == .tasks) {
            model.screen = .proposal;
            model.focus = .right;
            continue;
        }
        if (key == .open_repositories and model.focus == .tasks) {
            model.screen = .repositories;
            model.focus = .right;
            continue;
        }
        if (key == .open_issues and model.focus == .tasks) {
            try openIssues(allocator, io, &config, &issues, &model);
            if (model.popup == null) model.focus = .right;
            continue;
        }
        if (key == .open_prompt and model.focus == .tasks) {
            model.screen = .prompt;
            model.focus = .right;
            continue;
        }
        if (model.focus == .right) {
            switch (model.screen) {
                .tasks, .repositories => try handleRepositoryKey(allocator, io, &config, &repository_tree, instructions, &model, key),
                .proposal => try handleProposalKey(allocator, io, proposal_path, &proposal, &model, key),
                .issues => try handleIssueKey(allocator, io, instructions, &issues, &model, key),
                .prompt => {
                    if (key == .edit) {
                        try out.interface.writeAll("\x1b[?1006l\x1b[?1000l\x1b[?25h\x1b[?1049l");
                        try out.interface.flush();
                        try std.posix.tcsetattr(stdin.handle, .FLUSH, original);
                        const edit_result = prompt_editor.edit(allocator, io, environ, instructions_path);
                        try std.posix.tcsetattr(stdin.handle, .FLUSH, raw);
                        try out.interface.writeAll("\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1006h");
                        if (edit_result) |_| {
                            const refreshed = prompt_instructions.load(allocator, io, instructions_path) catch |err| {
                                model.popup = .{ .error_message = promptEditorErrorMessage(err) };
                                continue;
                            };
                            allocator.free(instructions);
                            instructions = refreshed;
                        } else |err| {
                            model.popup = .{ .error_message = promptEditorErrorMessage(err) };
                        }
                    } else if (key == .quit) model.screen = .repositories else if (key == .help) model.popup = .help;
                },
                .help => if (key == .quit) {
                    model.screen = .repositories;
                } else if (key == .help) {
                    model.popup = .help;
                },
            }
            continue;
        }
        switch (key) {
            .move_up => if (model.selected > 0) {
                const id = data.tasks.items[model.selected].id;
                const original_position = model.selected + 1;
                _ = try data.move(id, model.selected);
                if (!persist(allocator, io, path, data)) {
                    _ = data.move(id, original_position) catch {};
                    model.popup = .{ .error_message = "Taskの順序を保存できませんでした。" };
                } else {
                    model.selected -= 1;
                }
            },
            .move_down => if (model.selected + 1 < data.tasks.items.len) {
                const id = data.tasks.items[model.selected].id;
                const original_position = model.selected + 1;
                _ = try data.move(id, model.selected + 2);
                if (!persist(allocator, io, path, data)) {
                    _ = data.move(id, original_position) catch {};
                    model.popup = .{ .error_message = "Taskの順序を保存できませんでした。" };
                } else {
                    model.selected += 1;
                }
            },
            .add => model.popup = .{ .input = InputState.init(.task_add, null, "") },
            .edit => if (data.tasks.items.len > 0) {
                const task = data.tasks.items[model.selected];
                model.popup = .{ .input = InputState.init(.task_edit, task.id, task.title) };
            },
            .toggle => if (data.tasks.items.len > 0) try toggleSelected(allocator, io, path, data, &model),
            .delete => if (data.tasks.items.len > 0) {
                model.popup = .{ .confirmation = .{ .delete_task = .{
                    .id = data.tasks.items[model.selected].id,
                    .index = model.selected,
                } } };
            },
            .clear => if (data.tasks.items.len > 0) {
                model.popup = .{ .confirmation = .clear_tasks };
            },
            .help => model.popup = .help,
            else => model.update(key, data.tasks.items.len),
        }
    }
}

fn commandKey(byte: u8) Key {
    return switch (byte) {
        'q' => .quit,
        '?' => .help,
        'k' => .up,
        'j' => .down,
        'K' => .move_up,
        'J' => .move_down,
        'a' => .add,
        'e' => .edit,
        ' ' => .toggle,
        'd' => .delete,
        'C' => .clear,
        '\t' => .switch_screen,
        'p' => .open_proposal,
        'P' => .open_prompt,
        'h' => .focus_tasks,
        'A' => .approve,
        'i' => .import_proposal,
        'r' => .open_repositories,
        'g' => .open_issues,
        else => .other,
    };
}

fn handleProposalKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    proposal_path: []const u8,
    proposal: *?proposal_mod.Proposal,
    model: *Model,
    key: Key,
) !void {
    const count = if (proposal.*) |*value| value.tasks.items.len else 0;
    switch (key) {
        .up, .scroll_previous => if (model.proposal_selected > 0) {
            model.proposal_selected -= 1;
        },
        .down, .scroll_next => if (model.proposal_selected + 1 < count) {
            model.proposal_selected += 1;
        },
        .add => if (proposal.* != null) {
            model.popup = .{ .input = InputState.init(.proposal_add, null, "") };
        },
        .edit => if (proposal.*) |*value| if (count > 0) {
            model.popup = .{ .input = InputState.init(.proposal_edit, model.proposal_selected, value.tasks.items[model.proposal_selected].title) };
        },
        .delete => if (count > 0) {
            model.popup = .{ .confirmation = .{ .delete_proposal_task = model.proposal_selected } };
        },
        .move_up => if (proposal.*) |*value| if (model.proposal_selected > 0) {
            const from = model.proposal_selected;
            try value.moveTask(from, from - 1);
            proposal_store.save(allocator, io, proposal_path, value) catch {
                value.moveTask(from - 1, from) catch {};
                model.popup = .{ .error_message = " Proposalの順序を保存できませんでした。" };
                return;
            };
            model.proposal_selected -= 1;
        },
        .move_down => if (proposal.*) |*value| if (model.proposal_selected + 1 < count) {
            const from = model.proposal_selected;
            try value.moveTask(from, from + 1);
            proposal_store.save(allocator, io, proposal_path, value) catch {
                value.moveTask(from + 1, from) catch {};
                model.popup = .{ .error_message = " Proposalの順序を保存できませんでした。" };
                return;
            };
            model.proposal_selected += 1;
        },
        .approve => if (count > 0) {
            model.popup = .{ .confirmation = .approve_proposal };
        },
        .import_proposal => try importProposalFromClipboard(allocator, io, proposal_path, proposal, model),
        .help => model.popup = .help,
        .quit => model.screen = .repositories,
        else => {},
    }
}

fn handleRepositoryKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *?github_config.Config,
    tree: *RepositoryTree,
    instructions: []const u8,
    model: *Model,
    key: Key,
) !void {
    const count = if (config.*) |*value| value.repositories.len else 0;
    switch (key) {
        .up, .scroll_previous => moveRepositoryTreeSelection(config, tree, model, false),
        .down, .scroll_next => moveRepositoryTreeSelection(config, tree, model, true),
        .toggle => if (count > 0) {
            const repository = config.*.?.repositories[model.repository_selected];
            const node = try tree.getOrCreate(repository);
            if (model.repository_issue_selected != null) return;
            if (node.expanded) {
                node.expanded = false;
            } else {
                if (node.issues == null) {
                    if (node.load_attempted) {
                        model.popup = .{ .error_message = node.load_error orelse " GitHub Issueを取得できませんでした。" };
                        return;
                    }
                    node.issues = github_client.listOpen(allocator, io, repository) catch |err| {
                        node.load_attempted = true;
                        node.load_error = githubIssueErrorMessage(err);
                        model.popup = .{ .error_message = githubIssueErrorMessage(err) };
                        return;
                    };
                    node.load_attempted = true;
                    node.load_error = null;
                }
                node.expanded = true;
            }
        },
        .open_repositories => if (count > 0) {
            const repository = config.*.?.repositories[model.repository_selected];
            const node = try tree.getOrCreate(repository);
            const loaded = github_client.listOpen(allocator, io, repository) catch |err| {
                node.load_attempted = true;
                node.load_error = githubIssueErrorMessage(err);
                model.popup = .{ .error_message = githubIssueErrorMessage(err) };
                return;
            };
            if (node.issues) |*previous| previous.deinit();
            node.issues = loaded;
            node.load_attempted = true;
            node.load_error = null;
            node.expanded = true;
            if (model.repository_issue_selected) |selected| {
                if (selected >= loaded.items.len) model.repository_issue_selected = if (loaded.items.len == 0) null else loaded.items.len - 1;
            }
        },
        .accept => if (count > 0 and model.repository_issue_selected != null) {
            const repository = config.*.?.repositories[model.repository_selected];
            const node = tree.find(repository) orelse return;
            const selected = node.issues.?.items[model.repository_issue_selected.?];
            var issue = github_client.get(allocator, io, selected.repository, selected.number) catch |err| {
                model.popup = .{ .error_message = githubIssueErrorMessage(err) };
                return;
            };
            defer issue.deinit();
            const prompt = github_prompt.buildWithInstructions(allocator, &issue, instructions) catch {
                model.popup = .{ .error_message = " AI向けプロンプトを生成できませんでした。" };
                return;
            };
            defer allocator.free(prompt);
            clipboard.copy(allocator, io, prompt) catch |err| {
                model.popup = .{ .error_message = proposalImportErrorMessage(err) };
                return;
            };
        },
        .add => model.popup = .{ .input = InputState.init(.repository_add, null, "") },
        .delete => if (count > 0 and model.repository_issue_selected == null) {
            model.popup = .{ .confirmation = .{ .delete_repository = model.repository_selected } };
        },
        .help => model.popup = .help,
        .quit => model.focus = .tasks,
        else => {},
    }
}

fn moveRepositoryTreeSelection(
    config: *const ?github_config.Config,
    tree: *const RepositoryTree,
    model: *Model,
    down: bool,
) void {
    const current = if (config.*) |*value| value else return;
    if (current.repositories.len == 0) return;
    const issue_count = tree.issueCount(current.repositories[model.repository_selected]);
    if (down) {
        if (model.repository_issue_selected) |issue_index| {
            if (issue_index + 1 < issue_count) {
                model.repository_issue_selected = issue_index + 1;
            } else if (model.repository_selected + 1 < current.repositories.len) {
                model.repository_selected += 1;
                model.repository_issue_selected = null;
            }
        } else if (issue_count > 0) {
            model.repository_issue_selected = 0;
        } else if (model.repository_selected + 1 < current.repositories.len) {
            model.repository_selected += 1;
        }
        return;
    }

    if (model.repository_issue_selected) |issue_index| {
        model.repository_issue_selected = if (issue_index == 0) null else issue_index - 1;
    } else if (model.repository_selected > 0) {
        model.repository_selected -= 1;
        const previous_count = tree.issueCount(current.repositories[model.repository_selected]);
        model.repository_issue_selected = if (previous_count == 0) null else previous_count - 1;
    }
}

fn openIssues(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *?github_config.Config,
    issues: *?github_client.IssueList,
    model: *Model,
) !void {
    const current = if (config.*) |*value| value else {
        model.popup = .{ .error_message = " Repositoryを先に登録してください。" };
        return;
    };
    if (current.repositories.len == 0) {
        model.popup = .{ .error_message = " Repositoryを先に登録してください。" };
        return;
    }
    const loaded = github_client.listOpenMany(allocator, io, current.repositories) catch |err| {
        model.popup = .{ .error_message = githubIssueErrorMessage(err) };
        return;
    };
    if (issues.*) |*previous| previous.deinit();
    issues.* = loaded;
    model.issue_selected = 0;
    model.screen = .issues;
}

fn handleIssueKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    instructions: []const u8,
    issues: *?github_client.IssueList,
    model: *Model,
    key: Key,
) !void {
    const current = if (issues.*) |*value| value else return;
    switch (key) {
        .up, .scroll_previous => if (model.issue_selected > 0) {
            model.issue_selected -= 1;
        },
        .down, .scroll_next => if (model.issue_selected + 1 < current.items.len) {
            model.issue_selected += 1;
        },
        .accept => if (current.items.len > 0) {
            const selected = current.items[model.issue_selected];
            var issue = github_client.get(allocator, io, selected.repository, selected.number) catch |err| {
                model.popup = .{ .error_message = githubIssueErrorMessage(err) };
                return;
            };
            defer issue.deinit();
            const prompt = github_prompt.buildWithInstructions(allocator, &issue, instructions) catch {
                model.popup = .{ .error_message = " AI向けプロンプトを生成できませんでした。" };
                return;
            };
            defer allocator.free(prompt);
            clipboard.copy(allocator, io, prompt) catch |err| {
                model.popup = .{ .error_message = proposalImportErrorMessage(err) };
                return;
            };
            model.screen = .repositories;
            model.focus = .tasks;
        },
        .help => model.popup = .help,
        .quit => model.screen = .repositories,
        else => {},
    }
}

fn githubIssueErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.GitHubCliNotFound => " GitHub CLI（gh）が見つかりません。",
        error.GitHubCliFailed => " GitHub CLIが失敗しました。認証とアクセス権を確認してください。",
        error.GitHubCliOutputTooLarge => " GitHub CLIの出力が大きすぎます。",
        error.GitHubCliExecutionFailed => " GitHub CLIを実行できませんでした。",
        error.InvalidGitHubOutput => " GitHub CLIから不正なIssueデータが返されました。",
        error.TooManyGitHubIssues => " Open Issueが多すぎます。",
        else => " GitHub Issueを取得できませんでした。",
    };
}

fn promptEditorErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.EditorNotConfigured => " VISUALまたはEDITORを設定してください。",
        error.EditorNotFound => " 設定されたエディタが見つかりません。",
        error.EditorFailed => " エディタが失敗しました。既存の追加指示は保持されています。",
        error.PromptInstructionsTooLarge => " 追加指示は64 KiB以内にしてください。",
        error.InvalidPromptInstructions => " 追加指示は有効なUTF-8で入力してください。",
        error.PromptInstructionsReadFailed => " 追加指示を読み込めませんでした。",
        error.CreatePromptInstructionsDirectoryFailed,
        error.PromptInstructionsWriteFailed,
        => " 追加指示を保存できませんでした。既存の内容は保持されています。",
        else => " 追加指示を編集できませんでした。",
    };
}

fn importProposalFromClipboard(
    allocator: std.mem.Allocator,
    io: std.Io,
    proposal_path: []const u8,
    proposal: *?proposal_mod.Proposal,
    model: *Model,
) !void {
    if (proposal.* != null) {
        model.popup = .{ .error_message = " 既存のProposalを承認してから取り込んでください。" };
        return;
    }
    const bytes = clipboard.read(allocator, io) catch |err| {
        model.popup = .{ .error_message = proposalImportErrorMessage(err) };
        return;
    };
    defer allocator.free(bytes);
    importProposalBytes(allocator, io, proposal_path, proposal, bytes) catch |err| {
        model.popup = .{ .error_message = proposalImportErrorMessage(err) };
        return;
    };
    model.proposal_selected = 0;
    model.popup = null;
}

fn importProposalBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    proposal_path: []const u8,
    proposal: *?proposal_mod.Proposal,
    bytes: []const u8,
) !void {
    if (proposal.* != null) return error.ProposalAlreadyExists;
    _ = try proposal_import.import(allocator, io, proposal_path, bytes);
    errdefer proposal_store.delete(io, proposal_path) catch {};
    proposal.* = try proposal_store.load(allocator, io, proposal_path);
}

fn proposalImportErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ProposalAlreadyExists => " 既存のProposalを承認してから取り込んでください。",
        error.EmptyClipboard => " Clipboardが空です。",
        error.ClipboardCommandNotFound => " Clipboard操作コマンドが見つかりません。",
        error.ClipboardTooLarge => " Clipboardの内容が大きすぎます。",
        error.ClipboardFailed => " Clipboardを読み込めませんでした。",
        error.UnsupportedClipboard => " このOSのClipboardには対応していません。",
        error.InvalidJson => " Clipboardの内容はProposal JSONとして読み込めません。",
        error.EmptyProposal => " ProposalにTask候補がありません。",
        error.UnsupportedProposalSchemaVersion => " 対応していないProposal形式です。",
        error.WriteFailed, error.CreateDirectoryFailed => " Proposalを保存できませんでした。",
        else => " Proposalを取り込めませんでした。",
    };
}

fn handlePopupEvent(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    proposal_path: []const u8,
    config_path: []const u8,
    data: *store.Data,
    proposal: *?proposal_mod.Proposal,
    config: *?github_config.Config,
    model: *Model,
    event: Event,
) !void {
    if (model.popup) |*popup| switch (popup.*) {
        .help, .error_message => switch (event) {
            .key => |key| if (key == .accept or key == .quit) {
                model.popup = null;
            },
            .byte => |byte| if (byte == 'q') {
                model.popup = null;
            },
        },
        .input => |*input| switch (event) {
            .key => |key| switch (key) {
                .accept => try applyInput(allocator, io, path, proposal_path, config_path, data, proposal, config, model, input),
                .backspace => input.backspace(),
                .left => input.moveLeft(),
                .right => input.moveRight(),
                .quit => model.popup = null,
                else => {},
            },
            .byte => |byte| input.append(byte),
        },
        .confirmation => |confirmation| switch (event) {
            .key => |key| if (key == .quit) {
                model.popup = null;
            },
            .byte => |byte| if (byte == 'y') {
                try applyConfirmation(allocator, io, path, proposal_path, config_path, data, proposal, config, model, confirmation);
            } else if (byte == 'n' or byte == 'q') {
                model.popup = null;
            },
        },
    };
}

fn applyInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    proposal_path: []const u8,
    config_path: []const u8,
    data: *store.Data,
    proposal: *?proposal_mod.Proposal,
    config: *?github_config.Config,
    model: *Model,
    input: *InputState,
) !void {
    if (!std.unicode.utf8ValidateSlice(input.value())) {
        input.error_message = " 入力中の文字を確定してから保存してください。";
        return;
    }
    switch (input.action) {
        .task_add => {
            const task = data.add(input.value()) catch |err| {
                input.error_message = inputErrorMessage(err);
                return;
            };
            const id = task.id;
            if (!persist(allocator, io, path, data)) {
                const removed = data.delete(id) catch unreachable;
                allocator.free(removed.title);
                model.popup = .{ .error_message = " Taskを保存できませんでした。" };
                return;
            }
            model.selected = data.tasks.items.len - 1;
            model.popup = null;
        },
        .task_edit => {
            const id = input.target_id orelse return;
            const task = data.find(id) orelse {
                model.popup = .{ .error_message = " 編集対象のTaskが見つかりません。" };
                return;
            };
            const previous = try allocator.dupe(u8, task.title);
            defer allocator.free(previous);
            const changed = data.edit(id, input.value()) catch |err| {
                input.error_message = inputErrorMessage(err);
                return;
            };
            if (!changed) {
                model.popup = null;
                return;
            }
            if (!persist(allocator, io, path, data)) {
                _ = data.edit(id, previous) catch {};
                model.popup = .{ .error_message = " Taskの編集を保存できませんでした。" };
                return;
            }
            model.popup = null;
        },
        .proposal_add => {
            const value = if (proposal.*) |*current| current else return;
            value.addTask(input.value()) catch |err| {
                input.error_message = inputErrorMessage(err);
                return;
            };
            proposal_store.save(allocator, io, proposal_path, value) catch {
                value.deleteTask(value.tasks.items.len - 1) catch {};
                model.popup = .{ .error_message = " Proposalを保存できませんでした。" };
                return;
            };
            model.proposal_selected = value.tasks.items.len - 1;
            model.popup = null;
        },
        .proposal_edit => {
            const value = if (proposal.*) |*current| current else return;
            const index: usize = @intCast(input.target_id orelse return);
            if (index >= value.tasks.items.len) return;
            const previous = try allocator.dupe(u8, value.tasks.items[index].title);
            defer allocator.free(previous);
            value.editTask(index, input.value()) catch |err| {
                input.error_message = inputErrorMessage(err);
                return;
            };
            proposal_store.save(allocator, io, proposal_path, value) catch {
                value.editTask(index, previous) catch {};
                model.popup = .{ .error_message = " Proposalの編集を保存できませんでした。" };
                return;
            };
            model.popup = null;
        },
        .repository_add => {
            _ = github_config.addRepository(allocator, io, config_path, input.value()) catch |err| {
                input.error_message = repositoryErrorMessage(err);
                return;
            };
            reloadConfig(allocator, io, config_path, config) catch {
                model.popup = .{ .error_message = " Repository設定を再読み込みできませんでした。" };
                return;
            };
            model.repository_selected = config.*.?.repositories.len - 1;
            model.repository_issue_selected = null;
            model.popup = null;
        },
    }
}

fn inputErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyTitle => " タイトルを入力してください。",
        else => " 入力を適用できませんでした。",
    };
}

fn repositoryErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidRepository => " owner/repository形式で入力してください。",
        error.DuplicateConfiguredRepository => " そのRepositoryは登録済みです。",
        error.TooManyConfiguredRepositories => " Repositoryはこれ以上登録できません。",
        error.RepositoryNotConfigured => " Repositoryが見つかりません。",
        error.GitHubConfigWriteFailed, error.CreateConfigDirectoryFailed => " Repository設定を保存できませんでした。",
        else => " Repository設定を変更できませんでした。",
    };
}

fn reloadConfig(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8, config: *?github_config.Config) !void {
    const loaded = try github_config.load(allocator, io, config_path);
    if (config.*) |*current| current.deinit();
    config.* = loaded;
}

fn toggleSelected(allocator: std.mem.Allocator, io: std.Io, path: []const u8, data: *store.Data, model: *Model) !void {
    const id = data.tasks.items[model.selected].id;
    _ = try data.toggle(id);
    if (!persist(allocator, io, path, data)) {
        _ = data.toggle(id) catch {};
        model.popup = .{ .error_message = " 完了状態を保存できませんでした。" };
        return;
    }
    model.popup = null;
}

fn applyConfirmation(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    proposal_path: []const u8,
    config_path: []const u8,
    data: *store.Data,
    proposal: *?proposal_mod.Proposal,
    config: *?github_config.Config,
    model: *Model,
    confirmation: Confirmation,
) !void {
    switch (confirmation) {
        .delete_task => |target| {
            const deleted = data.delete(target.id) catch {
                model.popup = .{ .error_message = " 削除対象のTaskが見つかりません。" };
                return;
            };
            if (!persist(allocator, io, path, data)) {
                data.tasks.insertAssumeCapacity(target.index, deleted);
                model.popup = .{ .error_message = " Taskの削除を保存できませんでした。" };
                return;
            }
            allocator.free(deleted.title);
            if (data.tasks.items.len == 0) {
                model.selected = 0;
            } else if (model.selected >= data.tasks.items.len) {
                model.selected = data.tasks.items.len - 1;
            }
            model.popup = null;
        },
        .clear_tasks => {
            var empty = store.Data.init(allocator);
            defer empty.deinit();
            if (!persist(allocator, io, path, &empty)) {
                model.popup = .{ .error_message = " 全Taskの削除を保存できませんでした。" };
                return;
            }
            _ = data.clear();
            model.selected = 0;
            model.popup = null;
        },
        .delete_proposal_task => |index| {
            const value = if (proposal.*) |*current| current else return;
            if (index >= value.tasks.items.len) return;
            const previous = try allocator.dupe(u8, value.tasks.items[index].title);
            defer allocator.free(previous);
            try value.deleteTask(index);
            proposal_store.save(allocator, io, proposal_path, value) catch {
                value.addTask(previous) catch {};
                value.moveTask(value.tasks.items.len - 1, index) catch {};
                model.popup = .{ .error_message = " Proposalの削除を保存できませんでした。" };
                return;
            };
            if (value.tasks.items.len == 0) model.proposal_selected = 0 else if (model.proposal_selected >= value.tasks.items.len) model.proposal_selected = value.tasks.items.len - 1;
            model.popup = null;
        },
        .approve_proposal => {
            const value = if (proposal.*) |*current| current else return;
            _ = proposal_apply.applyProposal(allocator, io, path, proposal_path, value) catch {
                model.popup = .{ .error_message = " Proposalを承認できませんでした。TaskとProposalは保持されています。" };
                return;
            };
            const loaded = store.load(allocator, io, path) catch {
                model.popup = .{ .error_message = " 承認後のTask一覧を再読み込みできませんでした。" };
                return;
            };
            data.deinit();
            data.* = loaded;
            value.deinit();
            proposal.* = null;
            model.screen = .repositories;
            model.focus = .tasks;
            model.selected = if (data.tasks.items.len == 0) 0 else data.tasks.items.len - 1;
            model.proposal_selected = 0;
            model.popup = null;
        },
        .delete_repository => |index| {
            const value = if (config.*) |*current| current else return;
            if (index >= value.repositories.len) return;
            _ = github_config.removeRepository(allocator, io, config_path, value.repositories[index]) catch |err| {
                model.popup = .{ .error_message = repositoryErrorMessage(err) };
                return;
            };
            reloadConfig(allocator, io, config_path, config) catch {
                model.popup = .{ .error_message = " Repository設定を再読み込みできませんでした。" };
                return;
            };
            const count = config.*.?.repositories.len;
            if (count == 0) model.repository_selected = 0 else if (model.repository_selected >= count) model.repository_selected = count - 1;
            model.repository_issue_selected = null;
            model.popup = null;
        },
    }
}

fn terminalSize(io: std.Io, file: std.Io.File) Size {
    var winsize: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const result = io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &winsize,
    } }) catch return .{ .columns = 80, .rows = 24 };
    if (result.device_io_control < 0 or winsize.col == 0 or winsize.row == 0)
        return .{ .columns = 80, .rows = 24 };
    return .{ .columns = winsize.col, .rows = winsize.row };
}

fn readInputEvent(input: *std.Io.Reader) !Event {
    const first = try input.takeByte();
    if (first != 0x1b) return switch (first) {
        '\r', '\n' => .{ .key = .accept },
        3 => .{ .key = .quit },
        8, 127 => .{ .key = .backspace },
        else => .{ .byte = first },
    };

    const second = try input.takeByte();
    if (second != '[') return .{ .key = decodeKey(first, second, null) };
    const third = try input.takeByte();
    if (third != '<') return .{ .key = decodeKey(first, second, third) };

    var sequence: [48]u8 = undefined;
    var length: usize = 0;
    while (length < sequence.len) {
        const byte = try input.takeByte();
        if (byte == 'M' or byte == 'm') return .{ .key = decodeMouse(sequence[0..length]) };
        sequence[length] = byte;
        length += 1;
    }
    return .{ .key = .other };
}

fn persist(allocator: std.mem.Allocator, io: std.Io, path: []const u8, data: *const store.Data) bool {
    paths.ensureParent(io, path) catch return false;
    store.save(allocator, io, path, data) catch return false;
    return true;
}

test "model selection stays within task bounds" {
    var model: Model = .{};
    model.update(.up, 2);
    try std.testing.expectEqual(@as(usize, 0), model.selected);
    model.update(.down, 2);
    try std.testing.expectEqual(@as(usize, 1), model.selected);
    model.update(.down, 2);
    try std.testing.expectEqual(@as(usize, 1), model.selected);
    model.update(.up, 2);
    try std.testing.expectEqual(@as(usize, 0), model.selected);
    model.update(.scroll_next, 2);
    try std.testing.expectEqual(@as(usize, 1), model.selected);
    model.update(.scroll_previous, 2);
    try std.testing.expectEqual(@as(usize, 0), model.selected);
    model.update(.quit, 2);
    try std.testing.expect(model.quit);
}

test "tasks and prompt render as separated panes with contextual help" {
    var data = store.Data.init(std.testing.allocator);
    defer data.deinit();
    var buffer: [32 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try renderApplication(&writer, &data, null, null, null, null, "日本語で回答する\n変更を小さくする", .{ .screen = .prompt, .focus = .right }, 100, 30);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "ztodo v" ++ build_options.version) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, " Tasks") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "プロンプト編集") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, " Help ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[26;3H" ++ panel_style ++ " Help ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, " Tab: Tasksへ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, active_frame_style) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "日本語で回答する") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "変更を小さくする") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Prompt  e: 外部エディタで追加指示を編集") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[1;61H") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, active_heading_style) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[3;61H" ++ active_frame_style) != null);
}

test "key decoder supports arrows vim keys and interrupt" {
    try std.testing.expectEqual(Key.up, decodeKey(0x1b, '[', 'A'));
    try std.testing.expectEqual(Key.down, decodeKey(0x1b, '[', 'B'));
    try std.testing.expectEqual(Key.left, decodeKey(0x1b, '[', 'D'));
    try std.testing.expectEqual(Key.right, decodeKey(0x1b, '[', 'C'));
    try std.testing.expectEqual(Key.down, decodeKey('j', null, null));
    try std.testing.expectEqual(Key.move_up, decodeKey('K', null, null));
    try std.testing.expectEqual(Key.move_down, decodeKey('J', null, null));
    try std.testing.expectEqual(Key.help, decodeKey('?', null, null));
    try std.testing.expectEqual(Key.accept, decodeKey('\r', null, null));
    try std.testing.expectEqual(Key.quit, decodeKey(3, null, null));
}

test "trackpad wheel uses natural scrolling independently of keyboard keys" {
    try std.testing.expectEqual(Key.scroll_next, decodeMouse("64;20;10"));
    try std.testing.expectEqual(Key.scroll_previous, decodeMouse("65;20;10"));
    try std.testing.expectEqual(Key.other, decodeMouse("0;20;10"));
    try std.testing.expectEqual(Key.other, decodeMouse("broken"));
}

test "q returns from proposal screen without quitting tui" {
    var proposal: ?proposal_mod.Proposal = null;
    var model: Model = .{ .screen = .proposal };
    try handleProposalKey(std.testing.allocator, std.testing.io, "unused.json", &proposal, &model, .quit);
    try std.testing.expectEqual(Screen.repositories, model.screen);
    try std.testing.expect(!model.quit);
}

test "tui imports validated proposal bytes without overwriting" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const proposal_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "proposal.json" });
    defer allocator.free(proposal_path);
    const json =
        \\{"schema_version":1,"source":{"provider":"github","repository":"owner/repo","issue_number":12,"issue_title":"Import"},"summary":"概要","completion_criteria":[],"tasks":[{"title":"実装する"}],"excluded":[],"notes":[]}
    ;
    var proposal: ?proposal_mod.Proposal = null;
    defer if (proposal) |*value| value.deinit();

    try importProposalBytes(allocator, io, proposal_path, &proposal, json);
    try std.testing.expectEqual(@as(usize, 1), proposal.?.tasks.items.len);
    try std.testing.expectEqualStrings("実装する", proposal.?.tasks.items[0].title);
    try std.testing.expectError(error.ProposalAlreadyExists, importProposalBytes(allocator, io, proposal_path, &proposal, json));
}

test "input backspace removes one complete utf8 codepoint" {
    var input = InputState.init(.task_add, null, "Task日");
    input.backspace();
    try std.testing.expectEqualStrings("Task", input.value());
    input.append('!');
    try std.testing.expectEqualStrings("Task!", input.value());
}

test "input cursor inserts and deletes at utf8 codepoint boundaries" {
    var input = InputState.init(.task_edit, 1, "前後");
    input.moveLeft();
    for ("中") |byte| input.append(byte);
    try std.testing.expectEqualStrings("前中後", input.value());
    try std.testing.expectEqual("前中".len, input.cursor);

    input.moveLeft();
    try std.testing.expectEqual("前".len, input.cursor);
    input.moveRight();
    try std.testing.expectEqual("前中".len, input.cursor);
    input.backspace();
    try std.testing.expectEqualStrings("前後", input.value());
    try std.testing.expectEqual("前".len, input.cursor);
}

test "input cursor follows unicode display width and wrapping" {
    const panel: Panel = .{ .top = 1, .left = 1, .width = 10, .height = 12 };
    var position = inputCursorPosition(panel, "あいa");
    try std.testing.expectEqual(@as(u16, 5), position.row);
    try std.testing.expectEqual(@as(u16, 8), position.column);

    position = inputCursorPosition(panel, "あいう");
    try std.testing.expectEqual(@as(u16, 6), position.row);
    try std.testing.expectEqual(@as(u16, 3), position.column);
}

test "input cursor rendering uses the editing position" {
    const panel: Panel = .{ .top = 1, .left = 1, .width = 20, .height = 12 };
    var input = InputState.init(.task_edit, 1, "前後");
    input.moveLeft();
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try renderInputCursor(&writer, panel, input);

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[5;5H") != null);
}

test "input rendering tolerates utf8 arriving one byte at a time" {
    var data = store.Data.init(std.testing.allocator);
    defer data.deinit();
    var input = InputState.init(.task_add, null, "");

    for ("日本語") |byte| {
        input.append(byte);
        var buffer: [32 * 1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try render(&writer, &data, .{ .popup = .{ .input = input } }, 80, 24);
    }

    try std.testing.expectEqualStrings("日本語", input.displayValue());
}

test "text input popup shows the hardware cursor and normal screen hides it" {
    var data = store.Data.init(std.testing.allocator);
    defer data.deinit();
    var buffer: [32 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try render(&writer, &data, .{ .popup = .{ .input = InputState.init(.task_add, null, "日本語") } }, 80, 24);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[?25h") != null);

    var normal_buffer: [16 * 1024]u8 = undefined;
    var normal_writer: std.Io.Writer = .fixed(&normal_buffer);
    try render(&normal_writer, &data, .{}, 80, 24);
    try std.testing.expect(std.mem.indexOf(u8, normal_writer.buffered(), "\x1b[?25l") != null);
}

test "tui task operations persist through the shared store" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "tasks.json" });
    defer allocator.free(path);
    const proposal_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "proposal.json" });
    defer allocator.free(proposal_path);
    const config_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "config.json" });
    defer allocator.free(config_path);

    var data = store.Data.init(allocator);
    defer data.deinit();
    var proposal: ?proposal_mod.Proposal = null;
    var config: ?github_config.Config = null;
    var model: Model = .{};

    var add_input = InputState.init(.task_add, null, "first");
    try applyInput(allocator, io, path, proposal_path, config_path, &data, &proposal, &config, &model, &add_input);
    try std.testing.expectEqual(@as(usize, 1), data.tasks.items.len);
    try std.testing.expectEqual(@as(?Popup, null), model.popup);

    var edit_input = InputState.init(.task_edit, 1, "updated");
    try applyInput(allocator, io, path, proposal_path, config_path, &data, &proposal, &config, &model, &edit_input);
    try std.testing.expectEqualStrings("updated", data.tasks.items[0].title);
    try std.testing.expectEqual(@as(?Popup, null), model.popup);

    try toggleSelected(allocator, io, path, &data, &model);
    try std.testing.expectEqual(store.Status.done, data.tasks.items[0].status);
    try std.testing.expectEqual(@as(?Popup, null), model.popup);

    var loaded = try store.load(allocator, io, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("updated", loaded.tasks.items[0].title);
    try std.testing.expectEqual(store.Status.done, loaded.tasks.items[0].status);

    try applyConfirmation(allocator, io, path, proposal_path, config_path, &data, &proposal, &config, &model, .{ .delete_task = .{ .id = 1, .index = 0 } });
    try std.testing.expectEqual(@as(usize, 0), data.tasks.items.len);
    try std.testing.expectEqual(@as(?Popup, null), model.popup);

    var after_delete = try store.load(allocator, io, path);
    defer after_delete.deinit();
    try std.testing.expectEqual(@as(usize, 0), after_delete.tasks.items.len);

    _ = try data.add("one");
    _ = try data.add("two");
    try applyConfirmation(allocator, io, path, proposal_path, config_path, &data, &proposal, &config, &model, .clear_tasks);
    try std.testing.expectEqual(@as(usize, 0), data.tasks.items.len);
    try std.testing.expectEqual(@as(u64, 1), data.next_id);
    try std.testing.expectEqual(@as(?Popup, null), model.popup);
}

test "tui proposal operations persist and approval adds tasks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "tasks.json" });
    defer allocator.free(path);
    const proposal_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "proposal.json" });
    defer allocator.free(proposal_path);
    const config_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "config.json" });
    defer allocator.free(config_path);

    var data = store.Data.init(allocator);
    defer data.deinit();
    const json =
        \\{"source":{"provider":"github","repository":"owner/ztodo","issue_number":24,"issue_title":"TUI"},"summary":"概要","completion_criteria":[],"tasks":[{"title":"first"}],"excluded":[],"notes":[]}
    ;
    var proposal: ?proposal_mod.Proposal = try proposal_mod.decode(allocator, json);
    defer if (proposal) |*value| value.deinit();
    var config: ?github_config.Config = null;
    try proposal_store.save(allocator, io, proposal_path, &proposal.?);
    var model: Model = .{ .screen = .proposal };

    var add_input = InputState.init(.proposal_add, null, "second");
    try applyInput(allocator, io, path, proposal_path, config_path, &data, &proposal, &config, &model, &add_input);
    try std.testing.expectEqual(@as(usize, 2), proposal.?.tasks.items.len);
    try std.testing.expectEqualStrings("second", proposal.?.tasks.items[1].title);

    var edit_input = InputState.init(.proposal_edit, 1, "updated");
    try applyInput(allocator, io, path, proposal_path, config_path, &data, &proposal, &config, &model, &edit_input);
    try std.testing.expectEqualStrings("updated", proposal.?.tasks.items[1].title);
    try handleProposalKey(allocator, io, proposal_path, &proposal, &model, .move_up);
    try std.testing.expectEqualStrings("updated", proposal.?.tasks.items[0].title);

    var third_input = InputState.init(.proposal_add, null, "delete me");
    try applyInput(allocator, io, path, proposal_path, config_path, &data, &proposal, &config, &model, &third_input);
    try applyConfirmation(allocator, io, path, proposal_path, config_path, &data, &proposal, &config, &model, .{ .delete_proposal_task = 2 });
    try std.testing.expectEqual(@as(usize, 2), proposal.?.tasks.items.len);

    try applyConfirmation(allocator, io, path, proposal_path, config_path, &data, &proposal, &config, &model, .approve_proposal);
    try std.testing.expect(proposal == null);
    try std.testing.expectEqual(Screen.repositories, model.screen);
    try std.testing.expectEqual(@as(usize, 2), data.tasks.items.len);
    try std.testing.expectEqualStrings("updated", data.tasks.items[0].title);
    try std.testing.expectEqualStrings("first", data.tasks.items[1].title);
    try std.testing.expect(!try proposal_store.exists(io, proposal_path));
}

test "tui repository management persists additions and deletions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "tasks.json" });
    defer allocator.free(path);
    const proposal_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "proposal.json" });
    defer allocator.free(proposal_path);
    const config_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "config.json" });
    defer allocator.free(config_path);

    var data = store.Data.init(allocator);
    defer data.deinit();
    var proposal: ?proposal_mod.Proposal = null;
    var config: ?github_config.Config = null;
    defer if (config) |*value| value.deinit();
    var model: Model = .{ .screen = .repositories };

    var add_input = InputState.init(.repository_add, null, "owner/repository");
    try applyInput(allocator, io, path, proposal_path, config_path, &data, &proposal, &config, &model, &add_input);
    try std.testing.expectEqual(@as(usize, 1), config.?.repositories.len);
    try std.testing.expectEqualStrings("owner/repository", config.?.repositories[0]);
    try std.testing.expectEqual(@as(?Popup, null), model.popup);

    try applyConfirmation(allocator, io, path, proposal_path, config_path, &data, &proposal, &config, &model, .{ .delete_repository = 0 });
    try std.testing.expectEqual(@as(usize, 0), config.?.repositories.len);
    try std.testing.expectEqual(@as(usize, 0), model.repository_selected);

    var tree = RepositoryTree.init(allocator);
    defer tree.deinit();
    try handleRepositoryKey(allocator, io, &config, &tree, "", &model, .quit);
    try std.testing.expectEqual(Screen.repositories, model.screen);
    try std.testing.expectEqual(Focus.tasks, model.focus);
    try std.testing.expect(!model.quit);
}

test "issue screen uses j k selection and q returns to repositories" {
    var items = [_]github_client.IssueSummary{
        .{ .repository = "owner/repo", .number = 1, .title = "first" },
        .{ .repository = "owner/repo", .number = 2, .title = "second" },
    };
    var list: ?github_client.IssueList = .{ .allocator = std.testing.allocator, .items = &items };
    var model: Model = .{ .screen = .issues };
    try handleIssueKey(std.testing.allocator, std.testing.io, "", &list, &model, .down);
    try std.testing.expectEqual(@as(usize, 1), model.issue_selected);
    try handleIssueKey(std.testing.allocator, std.testing.io, "", &list, &model, .up);
    try std.testing.expectEqual(@as(usize, 0), model.issue_selected);
    try handleIssueKey(std.testing.allocator, std.testing.io, "", &list, &model, .quit);
    try std.testing.expectEqual(Screen.repositories, model.screen);
    try std.testing.expect(!model.quit);
}

test "repository tree renders expanded issues and navigates visible rows" {
    const allocator = std.testing.allocator;
    var repositories = [_][]const u8{ "owner/repo", "owner/second" };
    const config_value: github_config.Config = .{ .allocator = allocator, .repositories = &repositories };
    const config: ?github_config.Config = config_value;
    var tree = RepositoryTree.init(allocator);
    defer tree.deinit();
    const node = try tree.getOrCreate("owner/repo");
    const items = try allocator.alloc(github_client.IssueSummary, 1);
    items[0] = .{
        .repository = try allocator.dupe(u8, "owner/repo"),
        .number = 12,
        .title = try allocator.dupe(u8, "Issue title"),
    };
    node.issues = .{ .allocator = allocator, .items = items };
    node.expanded = true;

    var data = store.Data.init(allocator);
    defer data.deinit();
    var buffer: [32 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var model: Model = .{ .screen = .repositories };
    try renderApplication(&writer, &data, null, &config.?, null, &tree, "", model, 100, 30);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "▾") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "#12 Issue title") != null);

    moveRepositoryTreeSelection(&config, &tree, &model, true);
    try std.testing.expectEqual(@as(?usize, 0), model.repository_issue_selected);
    moveRepositoryTreeSelection(&config, &tree, &model, true);
    try std.testing.expectEqual(@as(usize, 1), model.repository_selected);
    try std.testing.expectEqual(@as(?usize, null), model.repository_issue_selected);
    moveRepositoryTreeSelection(&config, &tree, &model, false);
    try std.testing.expectEqual(@as(usize, 0), model.repository_selected);
    try std.testing.expectEqual(@as(?usize, 0), model.repository_issue_selected);
    moveRepositoryTreeSelection(&config, &tree, &model, false);
    try std.testing.expectEqual(@as(?usize, null), model.repository_issue_selected);
}

test "right pane rows wrap unicode and keep selected continuation full width" {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const panel: Panel = .{ .top = 1, .left = 1, .width = 20, .height = 8 };

    const lines = try renderWrappedRightLine(&writer, 2, panel.bottom(), panel, "  > #12 あいうえおかきくけこさしす", 8, true, false);

    try std.testing.expectEqual(@as(u16, 3), lines);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "        かきくけこ") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "        さしす    \x1b[0m") != null);
}

test "repository toggle reports cached preload failure without fetching again" {
    const allocator = std.testing.allocator;
    var repositories = [_][]const u8{"owner/repo"};
    var config: ?github_config.Config = .{ .allocator = allocator, .repositories = &repositories };
    var tree = RepositoryTree.init(allocator);
    defer tree.deinit();
    const node = try tree.getOrCreate("owner/repo");
    node.load_attempted = true;
    node.load_error = " cached preload error";
    var model: Model = .{ .screen = .repositories, .focus = .right };

    try handleRepositoryKey(allocator, std.testing.io, &config, &tree, "", &model, .toggle);

    try std.testing.expectEqualStrings(" cached preload error", model.popup.?.error_message);
    try std.testing.expect(!node.expanded);
}

test "opening issues without repositories shows an error" {
    var config: ?github_config.Config = null;
    var issues: ?github_client.IssueList = null;
    var model: Model = .{};
    try openIssues(std.testing.allocator, std.testing.io, &config, &issues, &model);
    try std.testing.expect(model.popup != null);
    try std.testing.expectEqual(Screen.repositories, model.screen);
}

test "popup is rendered over the task list" {
    var data = store.Data.init(std.testing.allocator);
    defer data.deinit();
    _ = try data.add("first");
    var buffer: [32 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try render(&writer, &data, .{ .popup = .help }, 80, 24);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), panelStyle(true)) == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), " Tasks") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[2;2H") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[23;2H") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "?: このヘルプ") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "ztodo v" ++ build_options.version) != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "╭") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "╯") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "▓") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), panel_style) != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[48;2;229;221;176m") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Enter / q") != null);
}

test "render shows tasks and selected row" {
    var data = store.Data.init(std.testing.allocator);
    defer data.deinit();
    _ = try data.add("first");
    _ = try data.add("second");
    _ = try data.complete(2);
    var buffer: [16 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try render(&writer, &data, .{ .selected = 1 }, 80, 24);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "[ ]    1  first") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "[x]    2  second") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[2;9m\x1b[7m> [x]") != null);
}

test "done task strikethrough extends to the right edge" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    _ = try renderTask(&writer, .{ .id = 1, .title = "done", .status = .done }, false, "", 1, 1, 2, 10, 9);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "done      \x1b[0m") != null);
}

test "long unicode task titles wrap with continuation indented one column" {
    var data = store.Data.init(std.testing.allocator);
    defer data.deinit();
    _ = try data.add("あいうえおかきくけこさしすせそたちつてと");
    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try render(&writer, &data, .{}, 48, 24);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "あいうえおか") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[5;15H") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "せそたちつて") != null);
}

test "base panel fills a larger terminal" {
    var data = store.Data.init(std.testing.allocator);
    defer data.deinit();
    var buffer: [32 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try render(&writer, &data, .{}, 120, 40);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[1;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[39;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[40;") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "ztodo v" ++ build_options.version) != null);
}

test "small terminal renders actionable fallback" {
    var data = store.Data.init(std.testing.allocator);
    defer data.deinit();
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try render(&writer, &data, .{}, 40, 10);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "terminal too small") != null);
}

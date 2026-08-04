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
const build_options = @import("build_options");

pub const min_columns: u16 = 48;
pub const min_rows: u16 = 12;

const panel_style = "\x1b[39m\x1b[49m";
const panel_heading_style = "\x1b[1;39m\x1b[49m";
const shadow_style = "\x1b[2;39m";

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
    error_message: ?[]const u8 = null,

    fn init(action: InputAction, target_id: ?u64, initial: []const u8) InputState {
        var input: InputState = .{ .action = action, .target_id = target_id };
        input.length = @min(initial.len, input.buffer.len);
        @memcpy(input.buffer[0..input.length], initial[0..input.length]);
        return input;
    }

    fn value(self: *const InputState) []const u8 {
        return self.buffer[0..self.length];
    }

    fn append(self: *InputState, byte: u8) void {
        if (self.length == self.buffer.len) return;
        self.buffer[self.length] = byte;
        self.length += 1;
        self.error_message = null;
    }

    fn backspace(self: *InputState) void {
        if (self.length == 0) return;
        self.length -= 1;
        while (self.length > 0 and self.buffer[self.length] & 0xc0 == 0x80) self.length -= 1;
        self.error_message = null;
    }
};

const Confirmation = union(enum) {
    delete_task: struct { id: u64, index: usize },
    clear_tasks,
    delete_proposal_task: usize,
    approve_proposal,
    delete_repository: usize,
};

const Screen = enum { tasks, proposal, repositories, issues };

pub const Key = enum {
    up,
    down,
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
    screen: Screen = .tasks,
    selected: usize = 0,
    proposal_selected: usize = 0,
    repository_selected: usize = 0,
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
            .move_up, .move_down, .add, .edit, .toggle, .delete, .clear, .switch_screen, .approve, .import_proposal, .open_repositories, .open_issues, .help, .accept, .backspace => {},
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
    return renderApplication(writer, data, proposal, null, null, model, columns, rows);
}

fn renderApplication(writer: *std.Io.Writer, data: *const store.Data, proposal: ?*const proposal_mod.Proposal, config: ?*const github_config.Config, issues: ?*const github_client.IssueList, model: Model, columns: u16, rows: u16) !void {
    try writer.writeAll("\x1b[2J\x1b[H");
    if (columns < min_columns or rows < min_rows) {
        try writer.print("ztodo: terminal too small ({d}x{d}); need at least {d}x{d}.\r\n", .{
            columns, rows, min_columns, min_rows,
        });
        return;
    }

    switch (model.screen) {
        .tasks => try renderBase(writer, data, model, columns, rows, model.popup != null),
        .proposal => try renderProposalBase(writer, proposal, model, columns, rows, model.popup != null),
        .repositories => try renderRepositoriesBase(writer, config, model, columns, rows, model.popup != null),
        .issues => try renderIssuesBase(writer, issues, model, columns, rows, model.popup != null),
    }
    if (model.popup) |popup| try renderPopup(writer, popup, model.screen, columns, rows);
}

fn renderBase(writer: *std.Io.Writer, data: *const store.Data, model: Model, columns: u16, rows: u16, dimmed: bool) !void {
    const style = if (dimmed) "\x1b[2m" else "";
    const panel = Panel.init(columns, rows, 0);
    try renderPanel(writer, panel, dimmed, false);
    try popupText(writer, panel.top + 1, panel.left, " ztodo  Tasks", true, dimmed);
    try popupLine(writer, panel.top + 2, panel.left, panel.width, "├", "─", "┤", panelStyle(dimmed));

    const task_row = panel.top + 3;
    const available_rows: usize = panel.height -| 5;
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
                index == model.selected,
                style,
                row,
                panel.left + 1,
                panel.bottom() - 1,
                first_columns,
                continuation_columns,
            ));
        }
    }
    try popupText(writer, panel.bottom() - 1, panel.left, " j/k or ↑/↓ select  a add  e edit  Space done  d delete  K/J move  Tab Proposal  r repos  g issues  ? help  q quit", false, dimmed);
}

fn renderProposalBase(writer: *std.Io.Writer, proposal: ?*const proposal_mod.Proposal, model: Model, columns: u16, rows: u16, dimmed: bool) !void {
    const panel = Panel.init(columns, rows, 0);
    try renderPanel(writer, panel, dimmed, false);
    try popupText(writer, panel.top + 1, panel.left, " ztodo  Proposal", true, dimmed);
    try popupLine(writer, panel.top + 2, panel.left, panel.width, "├", "─", "┤", panelStyle(dimmed));
    const current = proposal orelse {
        try popupText(writer, panel.top + 4, panel.left, " Proposalはありません。iでClipboardから取り込めます。", false, dimmed);
        try popupText(writer, panel.bottom() - 1, panel.left, " i import  q return  ? help", false, dimmed);
        return;
    };
    var source_buffer: [512]u8 = undefined;
    const source = try std.fmt.bufPrint(&source_buffer, " {s}#{d}  {s}", .{ current.source.repository, current.source.issue_number, current.source.issue_title });
    try popupText(writer, panel.top + 3, panel.left, source, false, dimmed);
    const content_columns: usize = panel.width -| 8;
    var row = panel.top + 5;
    for (current.tasks.items, 0..) |candidate, index| {
        if (row >= panel.bottom() - 1) break;
        var prefix_buffer: [32]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buffer, "{s} {d: >2}. ", .{ if (index == model.proposal_selected) ">" else " ", index + 1 });
        const length = wrapChunkLength(candidate.title, content_columns);
        try writer.print("\x1b[{d};{d}H{s}{s}{s}{s}", .{ row, panel.left + 1, panelStyle(dimmed), if (index == model.proposal_selected) "\x1b[7m" else "", prefix, candidate.title[0..length] });
        if (index == model.proposal_selected) {
            const used = displayWidth(prefix) + displayWidth(candidate.title[0..length]);
            var padding = (panel.width -| 2) -| used;
            while (padding > 0) : (padding -= 1) try writer.writeByte(' ');
        }
        try writer.writeAll("\x1b[0m");
        row += 1;
    }
    if (current.tasks.items.len == 0) try popupText(writer, row, panel.left, " Task候補はありません。", false, dimmed);
    try popupText(writer, panel.bottom() - 1, panel.left, " j/k or ↑/↓ select  a add  e edit  d delete  K/J move  A approve  i import  q return  ? help", false, dimmed);
}

fn renderRepositoriesBase(writer: *std.Io.Writer, config: ?*const github_config.Config, model: Model, columns: u16, rows: u16, dimmed: bool) !void {
    const panel = Panel.init(columns, rows, 0);
    try renderPanel(writer, panel, dimmed, false);
    try popupText(writer, panel.top + 1, panel.left, " ztodo  Repositories", true, dimmed);
    try popupLine(writer, panel.top + 2, panel.left, panel.width, "├", "─", "┤", panelStyle(dimmed));
    const repositories = if (config) |value| value.repositories else &.{};
    var row = panel.top + 4;
    if (repositories.len == 0) {
        try popupText(writer, row, panel.left, " Repositoryは登録されていません。", false, dimmed);
    } else for (repositories, 0..) |repository, index| {
        if (row >= panel.bottom() - 1) break;
        var prefix_buffer: [32]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buffer, "{s} {d: >2}. ", .{ if (index == model.repository_selected) ">" else " ", index + 1 });
        try writer.print("\x1b[{d};{d}H{s}{s}{s}{s}", .{ row, panel.left + 1, panelStyle(dimmed), if (index == model.repository_selected) "\x1b[7m" else "", prefix, repository });
        if (index == model.repository_selected) {
            const used = displayWidth(prefix) + displayWidth(repository);
            var padding = (panel.width -| 2) -| used;
            while (padding > 0) : (padding -= 1) try writer.writeByte(' ');
        }
        try writer.writeAll("\x1b[0m");
        row += 1;
    }
    try popupText(writer, panel.bottom() - 1, panel.left, " j/k or ↑/↓ select  a add  d delete  q return  ? help", false, dimmed);
}

fn renderIssuesBase(writer: *std.Io.Writer, issues: ?*const github_client.IssueList, model: Model, columns: u16, rows: u16, dimmed: bool) !void {
    const panel = Panel.init(columns, rows, 0);
    try renderPanel(writer, panel, dimmed, false);
    try popupText(writer, panel.top + 1, panel.left, " ztodo  GitHub Issues", true, dimmed);
    try popupLine(writer, panel.top + 2, panel.left, panel.width, "├", "─", "┤", panelStyle(dimmed));
    const items = if (issues) |value| value.items else &.{};
    var row = panel.top + 4;
    if (items.len == 0) {
        try popupText(writer, row, panel.left, " Open Issueはありません。", false, dimmed);
    } else for (items, 0..) |issue, index| {
        if (row >= panel.bottom() - 1) break;
        var prefix_buffer: [512]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buffer, "{s} {s}#{d} ", .{ if (index == model.issue_selected) ">" else " ", issue.repository, issue.number });
        const available = (panel.width -| 2) -| displayWidth(prefix);
        const length = wrapChunkLength(issue.title, available);
        try writer.print("\x1b[{d};{d}H{s}{s}{s}{s}", .{ row, panel.left + 1, panelStyle(dimmed), if (index == model.issue_selected) "\x1b[7m" else "", prefix, issue.title[0..length] });
        if (index == model.issue_selected) {
            const used = displayWidth(prefix) + displayWidth(issue.title[0..length]);
            var padding = (panel.width -| 2) -| used;
            while (padding > 0) : (padding -= 1) try writer.writeByte(' ');
        }
        try writer.writeAll("\x1b[0m");
        row += 1;
    }
    try popupText(writer, panel.bottom() - 1, panel.left, " j/k or ↑/↓ select  Enter copy prompt  q return  ? help", false, dimmed);
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
    const task_style = if (task.status == .done) "\x1b[2m" else style;
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
        if (selected) {
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
        const sequence_length = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
        const end = @min(text.len, offset + sequence_length);
        const codepoint = std.unicode.utf8Decode(text[offset..end]) catch @as(u21, text[offset]);
        const width = codepointWidth(codepoint);
        if (offset > 0 and columns + width > max_columns) break;
        columns += width;
        offset = end;
    }
    return @max(offset, 1);
}

fn displayWidth(text: []const u8) usize {
    var offset: usize = 0;
    var columns: usize = 0;
    while (offset < text.len) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
        const end = @min(text.len, offset + sequence_length);
        const codepoint = std.unicode.utf8Decode(text[offset..end]) catch @as(u21, text[offset]);
        columns += codepointWidth(codepoint);
        offset = end;
    }
    return columns;
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

fn renderPanel(writer: *std.Io.Writer, panel: Panel, dimmed: bool, shadow: bool) !void {
    if (shadow) try renderShadow(writer, panel);
    const style = panelStyle(dimmed);
    try popupLine(writer, panel.top, panel.left, panel.width, "┌", "─", "┐", style);
    var row = panel.top + 1;
    while (row < panel.bottom()) : (row += 1) try popupContent(writer, row, panel.left, panel.width, style);
    try popupLine(writer, panel.bottom(), panel.left, panel.width, "└", "─", "┘", style);
}

fn renderShadow(writer: *std.Io.Writer, panel: Panel) !void {
    const shadow_column = panel.left + panel.width;
    const shadow_row = panel.bottom() + 1;
    var row = panel.top + 1;
    while (row <= panel.bottom()) : (row += 1) {
        try writer.print("\x1b[{d};{d}H{s}▓\x1b[0m", .{ row, shadow_column, shadow_style });
    }
    try writer.print("\x1b[{d};{d}H{s}", .{ shadow_row, panel.left + 1, shadow_style });
    var column: u16 = 0;
    while (column < panel.width) : (column += 1) try writer.writeAll("▓");
    try writer.writeAll("\x1b[0m");
}

fn renderPopup(writer: *std.Io.Writer, popup: Popup, screen: Screen, columns: u16, rows: u16) !void {
    const margin: u16 = switch (popup) {
        .help => 1,
        else => 12,
    };
    const panel = Panel.init(columns, rows, margin);
    try renderPanel(writer, panel, false, true);

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
                    " Tab   : Proposalを開く",
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
                    " j / ↓ : 次のRepository",
                    " k / ↑ : 前のRepository",
                    " a     : Repositoryを追加",
                    " d     : Repositoryを削除",
                    " q     : Tasksへ戻る",
                },
                .issues => &.{
                    " j / ↓ : 次のIssue",
                    " k / ↑ : 前のIssue",
                    " Enter : プロンプトをコピー",
                    " q     : Tasksへ戻る",
                },
            };
            for (lines, 0..) |line, index| try popupText(writer, panel.top + 3 + @as(u16, @intCast(index)), panel.left, line, false, false);
        },
        .input => |input| {
            try popupText(writer, panel.top + 3, panel.left, if (input.action == .repository_add) " Repository:" else " タイトル:", false, false);
            try renderPopupWrapped(writer, panel, panel.top + 4, input.value());
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
        .input => " Enter: 保存   Ctrl-C: キャンセル",
        .confirmation => " y: 実行   n/q: キャンセル",
        else => " Enter / q: 閉じる",
    }, false, false);
}

fn renderPopupWrapped(writer: *std.Io.Writer, panel: Panel, first_row: u16, text: []const u8) !void {
    var offset: usize = 0;
    var row = first_row;
    const columns: usize = panel.width -| 4;
    while (offset < text.len and row < panel.bottom() - 2) : (row += 1) {
        const length = wrapChunkLength(text[offset..], columns);
        try popupText(writer, row, panel.left + 1, text[offset .. offset + length], false, false);
        offset += length;
    }
}

fn popupLine(writer: *std.Io.Writer, row: u16, column: u16, width: u16, left_edge: []const u8, fill: []const u8, right_edge: []const u8, style: []const u8) !void {
    try writer.print("\x1b[{d};{d}H{s}{s}", .{ row, column, style, left_edge });
    var index: u16 = 0;
    while (index < width -| 2) : (index += 1) try writer.writeAll(fill);
    try writer.print("{s}\x1b[0m", .{right_edge});
}

fn popupContent(writer: *std.Io.Writer, row: u16, column: u16, width: u16, style: []const u8) !void {
    try writer.print("\x1b[{d};{d}H{s}│", .{ row, column, style });
    var index: u16 = 0;
    while (index < width -| 2) : (index += 1) try writer.writeByte(' ');
    try writer.writeAll("│\x1b[0m");
}

fn popupText(writer: *std.Io.Writer, row: u16, column: u16, content: []const u8, emphasized: bool, dimmed: bool) !void {
    try writer.print("\x1b[{d};{d}H{s}{s}\x1b[0m", .{
        row,
        column + 1,
        if (emphasized and !dimmed) panel_heading_style else panelStyle(dimmed),
        content,
    });
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, path: []const u8, proposal_path: []const u8, config_path: []const u8, data: *store.Data) !void {
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
    var issues: ?github_client.IssueList = null;
    defer if (issues) |*value| value.deinit();
    while (!model.quit) {
        const size = terminalSize(io, stdout);
        try renderApplication(&out.interface, data, if (proposal) |*value| value else null, if (config) |*value| value else null, if (issues) |*value| value else null, model, size.columns, size.rows);
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
            if (model.screen == .tasks) model.screen = .proposal;
            continue;
        }
        if (key == .open_repositories and model.screen == .tasks) {
            model.screen = .repositories;
            continue;
        }
        if (key == .open_issues and model.screen == .tasks) {
            try openIssues(allocator, io, &config, &issues, &model);
            continue;
        }
        if (model.screen == .proposal) {
            try handleProposalKey(allocator, io, proposal_path, &proposal, &model, key);
            continue;
        }
        if (model.screen == .repositories) {
            try handleRepositoryKey(&config, &model, key);
            continue;
        }
        if (model.screen == .issues) {
            try handleIssueKey(allocator, io, &issues, &model, key);
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
        .quit => model.screen = .tasks,
        else => {},
    }
}

fn handleRepositoryKey(config: *?github_config.Config, model: *Model, key: Key) !void {
    const count = if (config.*) |*value| value.repositories.len else 0;
    switch (key) {
        .up, .scroll_previous => if (model.repository_selected > 0) {
            model.repository_selected -= 1;
        },
        .down, .scroll_next => if (model.repository_selected + 1 < count) {
            model.repository_selected += 1;
        },
        .add => model.popup = .{ .input = InputState.init(.repository_add, null, "") },
        .delete => if (count > 0) {
            model.popup = .{ .confirmation = .{ .delete_repository = model.repository_selected } };
        },
        .help => model.popup = .help,
        .quit => model.screen = .tasks,
        else => {},
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
            const prompt = github_prompt.build(allocator, &issue) catch {
                model.popup = .{ .error_message = " AI向けプロンプトを生成できませんでした。" };
                return;
            };
            defer allocator.free(prompt);
            clipboard.copy(allocator, io, prompt) catch |err| {
                model.popup = .{ .error_message = proposalImportErrorMessage(err) };
                return;
            };
            model.screen = .tasks;
        },
        .help => model.popup = .help,
        .quit => model.screen = .tasks,
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
            model.screen = .tasks;
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

test "key decoder supports arrows vim keys and interrupt" {
    try std.testing.expectEqual(Key.up, decodeKey(0x1b, '[', 'A'));
    try std.testing.expectEqual(Key.down, decodeKey(0x1b, '[', 'B'));
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
    try std.testing.expectEqual(Screen.tasks, model.screen);
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
    try std.testing.expectEqual(Screen.tasks, model.screen);
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

    try handleRepositoryKey(&config, &model, .quit);
    try std.testing.expectEqual(Screen.tasks, model.screen);
    try std.testing.expect(!model.quit);
}

test "issue screen uses j k selection and q returns to tasks" {
    var items = [_]github_client.IssueSummary{
        .{ .repository = "owner/repo", .number = 1, .title = "first" },
        .{ .repository = "owner/repo", .number = 2, .title = "second" },
    };
    var list: ?github_client.IssueList = .{ .allocator = std.testing.allocator, .items = &items };
    var model: Model = .{ .screen = .issues };
    try handleIssueKey(std.testing.allocator, std.testing.io, &list, &model, .down);
    try std.testing.expectEqual(@as(usize, 1), model.issue_selected);
    try handleIssueKey(std.testing.allocator, std.testing.io, &list, &model, .up);
    try std.testing.expectEqual(@as(usize, 0), model.issue_selected);
    try handleIssueKey(std.testing.allocator, std.testing.io, &list, &model, .quit);
    try std.testing.expectEqual(Screen.tasks, model.screen);
    try std.testing.expect(!model.quit);
}

test "opening issues without repositories shows an error" {
    var config: ?github_config.Config = null;
    var issues: ?github_client.IssueList = null;
    var model: Model = .{};
    try openIssues(std.testing.allocator, std.testing.io, &config, &issues, &model);
    try std.testing.expect(model.popup != null);
    try std.testing.expectEqual(Screen.tasks, model.screen);
}

test "popup is rendered over the task list" {
    var data = store.Data.init(std.testing.allocator);
    defer data.deinit();
    _ = try data.add("first");
    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try render(&writer, &data, .{ .popup = .help }, 80, 24);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), panelStyle(true)) != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "ztodo  Tasks") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[2;2H") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[23;2H") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "?: このヘルプ") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "ztodo v" ++ build_options.version) != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "┘") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "▓") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), panel_style) != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Enter / q") != null);
}

test "render shows tasks and selected row" {
    var data = store.Data.init(std.testing.allocator);
    defer data.deinit();
    _ = try data.add("first");
    _ = try data.add("second");
    _ = try data.complete(2);
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try render(&writer, &data, .{ .selected = 1 }, 80, 24);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "[ ]    1  first") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "[x]    2  second") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[2m\x1b[7m> [x]") != null);
}

test "long unicode task titles wrap with continuation indented one column" {
    var data = store.Data.init(std.testing.allocator);
    defer data.deinit();
    _ = try data.add("あいうえおかきくけこさしすせそたちつてと");
    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try render(&writer, &data, .{}, 48, 24);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "あいうえおかきくけこさしすせそたち") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[5;15H") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "つてと") != null);
}

test "base panel fills a larger terminal" {
    var data = store.Data.init(std.testing.allocator);
    defer data.deinit();
    var buffer: [32 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try render(&writer, &data, .{}, 120, 40);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[1;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[40;1H") != null);
}

test "small terminal renders actionable fallback" {
    var data = store.Data.init(std.testing.allocator);
    defer data.deinit();
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try render(&writer, &data, .{}, 40, 10);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "terminal too small") != null);
}

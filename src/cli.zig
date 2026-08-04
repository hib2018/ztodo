const std = @import("std");
const store = @import("core/store.zig");
const paths = @import("core/paths.zig");
const proposal_mod = @import("proposal/model.zig");
const proposal_store = @import("proposal/store.zig");
const proposal_editor = @import("proposal/editor.zig");
const workflow_apply = @import("proposal/apply.zig");
const github_cli = @import("integrations/github/client.zig");
const github_config = @import("integrations/github/config.zig");
const issue_selector = @import("integrations/github/selector.zig");
const ai_prompt = @import("integrations/github/prompt.zig");
const clipboard = @import("platform/clipboard.zig");
const workflow_clipboard_import = @import("proposal/clipboard_import.zig");
const tui = @import("tui/app.zig");
const build_options = @import("build_options");

pub const version = build_options.version;

pub const Command = union(enum) {
    help,
    version,
    ls,
    tui,
    add: []const []const u8,
    done: u64,
    del: u64,
    move: MoveCommand,
    clear,
    repo: RepoCommand,
    prop,
    proposal_import,
    issue: ?[]const u8,
};

pub const MoveCommand = struct {
    id: u64,
    position: usize,
};

pub const RepoCommand = union(enum) {
    ls,
    add: []const u8,
    del: []const u8,
};

pub fn parse(args: []const []const u8) !Command {
    if (args.len <= 1) return .tui;
    const name = args[1];
    if (std.mem.eql(u8, name, "help")) return requireNoExtra(args, .help);
    if (std.mem.eql(u8, name, "version")) return requireNoExtra(args, .version);
    if (std.mem.eql(u8, name, "ls")) return requireNoExtra(args, .ls);
    if (std.mem.eql(u8, name, "clear")) return requireNoExtra(args, .clear);
    if (std.mem.eql(u8, name, "repo")) {
        if (args.len < 3) return error.MissingArgument;
        const action = args[2];
        if (std.mem.eql(u8, action, "ls")) {
            if (args.len > 3) return error.UnexpectedArgument;
            return .{ .repo = .ls };
        }
        if (std.mem.eql(u8, action, "add") or
            std.mem.eql(u8, action, "del"))
        {
            if (args.len < 4) return error.MissingArgument;
            if (args.len > 4) return error.UnexpectedArgument;
            return .{ .repo = if (std.mem.eql(u8, action, "add"))
                .{ .add = args[3] }
            else
                .{ .del = args[3] } };
        }
        return error.UnknownRepoCommand;
    }
    if (std.mem.eql(u8, name, "prop")) return requireNoExtra(args, .prop);
    if (std.mem.eql(u8, name, "import")) return requireNoExtra(args, .proposal_import);
    if (std.mem.eql(u8, name, "issue")) {
        if (args.len > 3) return error.UnexpectedArgument;
        return .{ .issue = if (args.len == 3) args[2] else null };
    }
    if (std.mem.eql(u8, name, "add")) {
        if (args.len < 3) return error.MissingArgument;
        return .{ .add = args[2..] };
    }
    if (std.mem.eql(u8, name, "done")) return .{ .done = try parseId(args) };
    if (std.mem.eql(u8, name, "del")) return .{ .del = try parseId(args) };
    if (std.mem.eql(u8, name, "move")) return .{ .move = try parseMove(args) };
    return error.UnknownCommand;
}

fn parseMove(args: []const []const u8) !MoveCommand {
    if (args.len < 4) return error.MissingArgument;
    if (args.len > 4) return error.UnexpectedArgument;
    const id = std.fmt.parseInt(u64, args[2], 10) catch return error.InvalidId;
    if (id == 0) return error.InvalidId;
    const position = std.fmt.parseInt(usize, args[3], 10) catch return error.InvalidPosition;
    if (position == 0) return error.InvalidPosition;
    return .{ .id = id, .position = position };
}

fn requireNoExtra(args: []const []const u8, command: Command) !Command {
    if (args.len != 2) return error.UnexpectedArgument;
    return command;
}

fn parseId(args: []const []const u8) !u64 {
    if (args.len < 3) return error.MissingArgument;
    if (args.len > 3) return error.UnexpectedArgument;
    const id = std.fmt.parseInt(u64, args[2], 10) catch return error.InvalidId;
    if (id == 0) return error.InvalidId;
    return id;
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, args: []const []const u8) u8 {
    const command = parse(args) catch |err| {
        writeParseError(io, err);
        return 2;
    };
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    defer stdout.interface.flush() catch {};

    switch (command) {
        .help => {
            stdout.interface.writeAll(help_text) catch return 1;
            return 0;
        },
        .version => {
            stdout.interface.print("ztodo {s}\n", .{version}) catch return 1;
            return 0;
        },
        .prop => return runProp(allocator, io, environ, &stdout.interface),
        .proposal_import => return runProposalImport(
            allocator,
            io,
            environ,
            &stdout.interface,
        ),
        .repo => |repo_command| return runRepo(
            allocator,
            io,
            environ,
            repo_command,
            &stdout.interface,
        ),
        .issue => |repository| return runGithubIssue(
            allocator,
            io,
            environ,
            repository,
            &stdout.interface,
        ),
        else => {},
    }

    const path = paths.resolve(allocator, environ) catch |err| {
        writeRuntimeError(io, err, 0);
        return 1;
    };
    defer allocator.free(path);
    var data = store.load(allocator, io, path) catch |err| {
        writeRuntimeError(io, err, 0);
        return 1;
    };
    defer data.deinit();

    switch (command) {
        .tui => {
            const proposal_path = paths.resolveProposal(allocator, environ) catch |err| {
                writeRuntimeError(io, err, 0);
                return 1;
            };
            defer allocator.free(proposal_path);
            const config_path = github_config.resolvePath(allocator, environ) catch |err| {
                writeRuntimeError(io, err, 0);
                return 1;
            };
            defer allocator.free(config_path);
            tui.run(allocator, io, path, proposal_path, config_path, &data) catch |err| {
                writeRuntimeError(io, err, 0);
                return 1;
            };
        },
        .ls => {
            if (data.tasks.items.len == 0) stdout.interface.writeAll("No tasks.\n") catch return 1 else for (data.tasks.items) |task| stdout.interface.print("[{s}] {d}  {s}\n", .{ if (task.status == .done) "x" else " ", task.id, task.title }) catch return 1;
        },
        .add => |parts| {
            const joined = std.mem.join(allocator, " ", parts) catch return 1;
            defer allocator.free(joined);
            const task = data.add(joined) catch |err| {
                writeRuntimeError(io, err, 0);
                return 2;
            };
            if (!persist(allocator, io, path, &data)) return 1;
            stdout.interface.print("Added task {d}: {s}\n", .{ task.id, task.title }) catch return 1;
        },
        .done => |id| {
            const changed = data.complete(id) catch |err| {
                writeRuntimeError(io, err, id);
                return 1;
            };
            const task = data.find(id).?;
            if (!changed) stdout.interface.print("Task {d} is already completed.\n", .{id}) catch return 1 else {
                if (!persist(allocator, io, path, &data)) return 1;
                stdout.interface.print("Completed task {d}: {s}\n", .{ id, task.title }) catch return 1;
            }
        },
        .del => |id| {
            const deleted = data.delete(id) catch |err| {
                writeRuntimeError(io, err, id);
                return 1;
            };
            defer allocator.free(deleted.title);
            if (!persist(allocator, io, path, &data)) return 1;
            stdout.interface.print("Deleted task {d}: {s}\n", .{ id, deleted.title }) catch return 1;
        },
        .move => |move_command| {
            const changed = data.move(move_command.id, move_command.position) catch |err| {
                writeRuntimeError(io, err, move_command.id);
                return 1;
            };
            if (changed and !persist(allocator, io, path, &data)) return 1;
            stdout.interface.print("Moved task {d} to position {d}: {s}\n", .{
                move_command.id,
                move_command.position,
                data.tasks.items[move_command.position - 1].title,
            }) catch return 1;
        },
        .clear => {
            const count = data.clear();
            if (!persist(allocator, io, path, &data)) return 1;
            stdout.interface.print("Cleared {d} task{s}.\n", .{ count, if (count == 1) "" else "s" }) catch return 1;
        },
        else => unreachable,
    }
    return 0;
}

fn runRepo(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    command: RepoCommand,
    stdout: *std.Io.Writer,
) u8 {
    const path = github_config.resolvePath(allocator, environ) catch |err| {
        writeRepoError(io, err);
        return 1;
    };
    defer allocator.free(path);
    switch (command) {
        .ls => {
            var config = github_config.load(allocator, io, path) catch |err| {
                if (err == error.GitHubConfigNotFound) {
                    stdout.print(
                        "No repositories configured.\nConfig: {s}\n",
                        .{path},
                    ) catch return 1;
                    return 0;
                }
                writeRepoError(io, err);
                return 1;
            };
            defer config.deinit();
            if (config.repositories.len == 0) {
                stdout.writeAll("No repositories configured.\n") catch return 1;
            } else {
                for (config.repositories) |repository| {
                    stdout.print("{s}\n", .{repository}) catch return 1;
                }
            }
            stdout.print("Config: {s}\n", .{path}) catch return 1;
        },
        .add => |repository| {
            const count = github_config.addRepository(
                allocator,
                io,
                path,
                repository,
            ) catch |err| {
                writeRepoError(io, err);
                return 1;
            };
            stdout.print(
                "Added repository: {s}\nConfigured repositories: {d}\n",
                .{ repository, count },
            ) catch return 1;
        },
        .del => |repository| {
            const count = github_config.removeRepository(
                allocator,
                io,
                path,
                repository,
            ) catch |err| {
                writeRepoError(io, err);
                return 1;
            };
            stdout.print(
                "Removed repository: {s}\nConfigured repositories: {d}\n",
                .{ repository, count },
            ) catch return 1;
        },
    }
    return 0;
}

fn runProposalImport(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    stdout: *std.Io.Writer,
) u8 {
    const path = paths.resolveProposal(allocator, environ) catch |err| {
        writeProposalImportError(io, err);
        return 1;
    };
    defer allocator.free(path);
    const bytes = clipboard.read(allocator, io) catch |err| {
        writeProposalImportError(io, err);
        return 1;
    };
    defer allocator.free(bytes);
    const count = workflow_clipboard_import.import(
        allocator,
        io,
        path,
        bytes,
    ) catch |err| {
        writeProposalImportError(io, err);
        return 1;
    };
    stdout.print(
        "Imported Proposal with {d} task{s}.\nRun `ztodo prop` to review it.\n",
        .{ count, if (count == 1) "" else "s" },
    ) catch return 1;
    return 0;
}

fn runGithubIssue(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    repository_argument: ?[]const u8,
    stdout: *std.Io.Writer,
) u8 {
    var configured: ?github_config.Config = null;
    defer if (configured) |*config| config.deinit();

    var issues = if (repository_argument) |repository|
        github_cli.listOpen(allocator, io, repository) catch |err| {
            writeGithubIssueError(io, err);
            return 1;
        }
    else configured_block: {
        const config_path = github_config.resolvePath(allocator, environ) catch |err| {
            writeGithubIssueError(io, err);
            return 1;
        };
        defer allocator.free(config_path);
        configured = github_config.load(allocator, io, config_path) catch |err| {
            writeGithubIssueError(io, err);
            return 1;
        };
        if (configured.?.repositories.len == 0) {
            writeGithubIssueError(io, error.NoConfiguredRepositories);
            return 1;
        }
        break :configured_block github_cli.listOpenMany(
            allocator,
            io,
            configured.?.repositories,
        ) catch |err| {
            writeGithubIssueError(io, err);
            return 1;
        };
    };
    defer issues.deinit();

    var stdin_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &stdin_buffer);
    const selected = issue_selector.select(
        issues.items,
        &stdin.interface,
        stdout,
    ) catch |err| {
        writeGithubIssueError(io, err);
        return 1;
    } orelse return 0;

    var issue = github_cli.get(
        allocator,
        io,
        issues.items[selected].repository,
        issues.items[selected].number,
    ) catch |err| {
        writeGithubIssueError(io, err);
        return 1;
    };
    defer issue.deinit();
    const prompt = ai_prompt.build(allocator, &issue) catch {
        writeGithubIssueError(io, error.PromptGenerationFailed);
        return 1;
    };
    defer allocator.free(prompt);

    stdout.print("\n{s}", .{prompt}) catch return 1;
    stdout.flush() catch return 1;
    clipboard.copy(allocator, io, prompt) catch |err| {
        writeGithubIssueError(io, err);
        return 1;
    };
    stdout.writeAll("\nPrompt copied to clipboard.\n") catch return 1;
    return 0;
}

fn runProp(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    stdout: *std.Io.Writer,
) u8 {
    const tasks_path = paths.resolve(allocator, environ) catch |err| {
        writeProposalError(io, err);
        return 1;
    };
    defer allocator.free(tasks_path);
    const proposal_path = paths.resolveProposal(allocator, environ) catch |err| {
        writeProposalError(io, err);
        return 1;
    };
    defer allocator.free(proposal_path);

    var stdin_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &stdin_buffer);
    _ = editAndApproveAtPaths(
        allocator,
        io,
        tasks_path,
        proposal_path,
        &stdin.interface,
        stdout,
    ) catch |err| {
        writeProposalError(io, err);
        return 1;
    };
    return 0;
}

const PropResult = enum { aborted, saved, applied };

fn editAndApproveAtPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    tasks_path: []const u8,
    proposal_path: []const u8,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !PropResult {
    var proposal = try proposal_store.load(allocator, io, proposal_path);
    defer proposal.deinit();
    const edit_result = try proposal_editor.run(&proposal, reader, writer);
    if (edit_result == .aborted) return .aborted;

    try proposal_store.save(allocator, io, proposal_path, &proposal);
    if (proposal.tasks.items.len == 0) {
        try writer.writeAll("Proposal saved. No tasks to approve.\n");
        return .saved;
    }

    try writer.writeAll("\nApprove the following tasks?\n\n");
    for (proposal.tasks.items, 1..) |candidate, number| {
        try writer.print("{d}. {s}\n", .{ number, candidate.title });
    }
    try writer.writeAll("\nApprove? [y/N] ");
    try writer.flush();
    const answer = try reader.takeDelimiter('\n') orelse {
        try writer.writeAll("\nProposal saved without approval.\n");
        return .saved;
    };
    if (!std.mem.eql(u8, std.mem.trim(u8, answer, " \t\r"), "y")) {
        try writer.writeAll("Proposal saved without approval.\n");
        return .saved;
    }

    const count = try workflow_apply.applyProposal(
        allocator,
        io,
        tasks_path,
        proposal_path,
        &proposal,
    );
    try writer.print("Approved and added {d} task{s}.\n", .{
        count,
        if (count == 1) "" else "s",
    });
    return .applied;
}

fn persist(allocator: std.mem.Allocator, io: std.Io, path: []const u8, data: *const store.Data) bool {
    paths.ensureParent(io, path) catch |err| {
        writeRuntimeError(io, err, 0);
        return false;
    };
    store.save(allocator, io, path, data) catch |err| {
        writeRuntimeError(io, err, 0);
        return false;
    };
    return true;
}

fn writeParseError(io: std.Io, err: anyerror) void {
    const message = switch (err) {
        error.UnknownCommand => "unknown command.",
        error.MissingArgument => "missing required argument.",
        error.InvalidId => "id must be a positive integer.",
        error.InvalidPosition => "position must be a positive integer.",
        error.UnexpectedArgument => "unexpected argument.",
        error.UnknownRepoCommand => "repo supports `ls`, `add`, and `del`.",
        else => "invalid input.",
    };
    writeStderr(io, "Error: {s}\n\nUsage: ztodo <command> [arguments]\n", .{message});
}

fn writeRepoError(io: std.Io, err: anyerror) void {
    const message = switch (err) {
        error.InvalidRepository => "repository must use the `owner/repo` format.",
        error.DuplicateConfiguredRepository => "repository is already configured.",
        error.RepositoryNotConfigured => "repository is not configured.",
        error.TooManyConfiguredRepositories => "no more than 20 repositories can be configured.",
        error.GitHubConfigTooLarge => "GitHub repository config exceeds 64 KiB.",
        error.GitHubConfigReadFailed => "GitHub repository config could not be read.",
        error.InvalidGitHubConfig => "GitHub repository config contains invalid JSON or unknown fields.",
        error.UnsupportedGitHubConfigVersion => "GitHub repository config uses an unsupported schema version.",
        error.GitHubConfigWriteFailed => "GitHub repository config could not be saved.",
        error.CreateConfigDirectoryFailed => "GitHub repository config directory could not be created.",
        error.MissingHome => "HOME is not set and no config file override is available.",
        else => "GitHub repository config operation failed.",
    };
    writeStderr(io, "Error: {s}\n", .{message});
}

fn writeProposalImportError(io: std.Io, err: anyerror) void {
    const message = switch (err) {
        error.ClipboardCommandNotFound => "no supported clipboard command was found.",
        error.UnsupportedClipboard => "clipboard import is not supported on this OS.",
        error.ClipboardFailed => "could not read the clipboard.",
        error.ClipboardTooLarge => "clipboard content exceeds 1 MiB.",
        error.EmptyClipboard => "clipboard is empty.",
        error.ProposalAlreadyExists => "a proposal already exists; approve it with `ztodo prop` before importing another.",
        error.EmptyProposal => "the Proposal contains no tasks.",
        error.InvalidJson => "clipboard does not contain valid Proposal JSON.",
        error.UnsupportedProposalSchemaVersion => "Proposal uses an unsupported schema version.",
        error.MissingHome => "HOME is not set and no data file override is available.",
        error.WriteFailed => "could not save the Proposal.",
        error.CreateDirectoryFailed => "could not create the Proposal data directory.",
        error.EmptyText,
        error.TextTooLong,
        error.InvalidText,
        error.InvalidProvider,
        error.InvalidRepository,
        error.InvalidIssueNumber,
        error.TooManyItems,
        error.EmptyTitle,
        error.TitleTooLong,
        error.InvalidTitle,
        error.DuplicateTitle,
        error.TooManyTasks,
        => "clipboard Proposal failed validation.",
        else => "Proposal import failed.",
    };
    writeStderr(io, "Error: {s}\n", .{message});
}

fn writeGithubIssueError(io: std.Io, err: anyerror) void {
    const message = switch (err) {
        error.InvalidRepository => "repository must use the `owner/repo` format.",
        error.GitHubCliNotFound => "GitHub CLI (`gh`) was not found.",
        error.GitHubCliFailed => "GitHub CLI failed. Check `gh auth status` and repository access.",
        error.GitHubCliOutputTooLarge => "GitHub CLI returned too much data.",
        error.GitHubCliExecutionFailed => "GitHub CLI could not be executed.",
        error.GitHubConfigNotFound => "GitHub repository config was not found. Create `~/.config/ztodo/config.json`.",
        error.GitHubConfigTooLarge => "GitHub repository config exceeds 64 KiB.",
        error.GitHubConfigReadFailed => "GitHub repository config could not be read.",
        error.InvalidGitHubConfig => "GitHub repository config contains invalid JSON or unknown fields.",
        error.UnsupportedGitHubConfigVersion => "GitHub repository config uses an unsupported schema version.",
        error.NoConfiguredRepositories => "GitHub repository config contains no repositories.",
        error.TooManyConfiguredRepositories => "GitHub repository config contains more than 20 repositories.",
        error.DuplicateConfiguredRepository => "GitHub repository config contains a duplicate repository.",
        error.MissingHome => "HOME is not set and no config file override is available.",
        error.InvalidGitHubOutput => "GitHub CLI returned invalid issue data.",
        error.TooManyGitHubIssues => "GitHub CLI returned too many issues.",
        error.InvalidIssueSelection => "select a number shown in the issue list.",
        error.SelectionAborted => "issue selection ended before a choice was made.",
        error.ClipboardCommandNotFound => "no supported clipboard command was found.",
        error.UnsupportedClipboard => "clipboard copy is not supported on this OS.",
        error.ClipboardFailed => "could not copy the prompt to the clipboard.",
        error.PromptGenerationFailed => "could not generate the AI prompt.",
        else => "GitHub issue operation failed.",
    };
    writeStderr(io, "Error: {s}\n", .{message});
}

fn writeRuntimeError(io: std.Io, err: anyerror, id: u64) void {
    if (err == error.TaskNotFound) return writeStderr(io, "Error: task {d} was not found.\n", .{id});
    const message = switch (err) {
        error.EmptyTitle => "title must not be empty.",
        error.MissingHome => "HOME is not set and no data file override is available.",
        error.ReadFailed => "could not read the data file.",
        error.InvalidJson => "data file contains invalid JSON.",
        error.UnsupportedSchemaVersion => "data file uses an unsupported schema version.",
        error.WriteFailed => "could not write the data file.",
        error.CreateDirectoryFailed => "could not create the data directory.",
        error.NotATerminal => "tui requires both stdin and stdout to be terminals.",
        error.InvalidTaskPosition => "position is outside the task list.",
        else => "operation failed.",
    };
    writeStderr(io, "Error: {s}\n", .{message});
}

fn writeProposalError(io: std.Io, err: anyerror) void {
    const message = switch (err) {
        error.ProposalNotFound => "no proposal found. Copy the AI response and run `ztodo import` first.",
        error.UnsupportedProposalSchemaVersion => "proposal uses an unsupported schema version.",
        error.MissingHome => "HOME is not set and no data file override is available.",
        error.ReadFailed => "could not read the proposal file.",
        error.InvalidJson => "proposal file contains invalid JSON.",
        error.WriteFailed => "could not save the proposal; the existing proposal has been kept.",
        error.CreateDirectoryFailed => "could not create the proposal data directory.",
        error.UnsupportedSchemaVersion => "task data uses an unsupported schema version.",
        error.ProposalCleanupFailed => "tasks were added, but the proposal could not be removed; do not approve it again.",
        error.EditorFailed => "proposal editor failed; changes were not saved.",
        error.EmptyText,
        error.TextTooLong,
        error.InvalidText,
        error.InvalidProvider,
        error.InvalidRepository,
        error.InvalidIssueNumber,
        error.TooManyItems,
        error.EmptyTitle,
        error.TitleTooLong,
        error.InvalidTitle,
        error.DuplicateTitle,
        error.TooManyTasks,
        => "proposal data failed validation.",
        else => "proposal operation failed.",
    };
    writeStderr(io, "Error: {s}\n", .{message});
}

fn writeStderr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    writer.interface.print(fmt, args) catch {};
    writer.interface.flush() catch {};
}

pub const help_text =
    \\ztodo - execution-focused CLI task manager
    \\
    \\Usage:
    \\  ztodo
    \\  ztodo <command> [arguments]
    \\
    \\Commands:
    \\  add <title...>  Add a task; title arguments are joined with spaces
    \\  ls              List todo and done tasks in their current order
    \\  done <id>       Mark a task as done
    \\  move <id> <position>
    \\                  Move a task to a one-based position
    \\  del <id>        Delete one task without confirmation
    \\  clear           Delete all tasks and reset the next ID to 1
    \\  repo ls         List configured GitHub repositories
    \\  repo add <owner/repo>
    \\                  Add a GitHub repository
    \\  repo del <owner/repo>
    \\                  Remove a GitHub repository
    \\  import          Import Proposal JSON from the clipboard
    \\  prop            Review, edit, and approve the current Proposal
    \\  issue [owner/repo]
    \\                  Select an Issue and copy an AI prompt; defaults to all configured repositories
    \\  help            Show this help
    \\  version         Show version
    \\
    \\Examples:
    \\  ztodo add READMEを 更新する
    \\  ztodo done 1
    \\  ztodo move 3 1
    \\  ztodo repo add owner/repo
    \\  ztodo issue
    \\  ztodo import
    \\  ztodo prop
    \\
    \\Warning:
    \\  clear runs without confirmation and cannot be undone.
    \\
;

test "CLI argument parsing" {
    const no_args = [_][]const u8{"ztodo"};
    try std.testing.expect((try parse(&no_args)) == .tui);
    const unknown = [_][]const u8{ "ztodo", "wat" };
    try std.testing.expectError(error.UnknownCommand, parse(&unknown));
    const add = [_][]const u8{ "ztodo", "add" };
    try std.testing.expectError(error.MissingArgument, parse(&add));
    const bad_done = [_][]const u8{ "ztodo", "done", "abc" };
    try std.testing.expectError(error.InvalidId, parse(&bad_done));
    const bad_del = [_][]const u8{ "ztodo", "del", "0" };
    try std.testing.expectError(error.InvalidId, parse(&bad_del));
    const move = [_][]const u8{ "ztodo", "move", "3", "1" };
    const move_command = (try parse(&move)).move;
    try std.testing.expectEqual(@as(u64, 3), move_command.id);
    try std.testing.expectEqual(@as(usize, 1), move_command.position);
    const bad_move_position = [_][]const u8{ "ztodo", "move", "3", "0" };
    try std.testing.expectError(error.InvalidPosition, parse(&bad_move_position));
    const ls = [_][]const u8{ "ztodo", "ls" };
    try std.testing.expect((try parse(&ls)) == .ls);
    const tui_command = [_][]const u8{ "ztodo", "tui" };
    try std.testing.expectError(error.UnknownCommand, parse(&tui_command));
    const clear = [_][]const u8{ "ztodo", "clear" };
    try std.testing.expect((try parse(&clear)) == .clear);
    const clear_extra = [_][]const u8{ "ztodo", "clear", "now" };
    try std.testing.expectError(error.UnexpectedArgument, parse(&clear_extra));
    const repo_ls = [_][]const u8{ "ztodo", "repo", "ls" };
    try std.testing.expect((try parse(&repo_ls)).repo == .ls);
    const repo_add = [_][]const u8{ "ztodo", "repo", "add", "owner/repo" };
    try std.testing.expectEqualStrings(
        "owner/repo",
        (try parse(&repo_add)).repo.add,
    );
    const repo_del = [_][]const u8{ "ztodo", "repo", "del", "owner/repo" };
    try std.testing.expectEqualStrings(
        "owner/repo",
        (try parse(&repo_del)).repo.del,
    );
    const repo_unknown = [_][]const u8{ "ztodo", "repo", "set" };
    try std.testing.expectError(
        error.UnknownRepoCommand,
        parse(&repo_unknown),
    );
    const prop = [_][]const u8{ "ztodo", "prop" };
    try std.testing.expect((try parse(&prop)) == .prop);
    const prop_extra = [_][]const u8{ "ztodo", "prop", "now" };
    try std.testing.expectError(error.UnexpectedArgument, parse(&prop_extra));
    const import_command = [_][]const u8{ "ztodo", "import" };
    try std.testing.expect((try parse(&import_command)) == .proposal_import);
    const current_issue = [_][]const u8{ "ztodo", "issue" };
    try std.testing.expectEqual(@as(?[]const u8, null), (try parse(&current_issue)).issue);
    const github = [_][]const u8{ "ztodo", "issue", "owner/repo" };
    const github_command = try parse(&github);
    try std.testing.expectEqualStrings("owner/repo", github_command.issue.?);
    const github_extra = [_][]const u8{ "ztodo", "issue", "owner/repo", "extra" };
    try std.testing.expectError(error.UnexpectedArgument, parse(&github_extra));
    try std.testing.expect(std.mem.indexOf(u8, help_text, "add <title...>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "clear runs without confirmation") != null);
}

test "help lists every top-level command" {
    const command_names = [_][]const u8{
        "add",
        "ls",
        "done",
        "move",
        "del",
        "clear",
        "repo",
        "issue",
        "import",
        "prop",
        "help",
        "version",
    };

    for (command_names) |name| {
        var help_pattern_buffer: [32]u8 = undefined;
        const help_pattern = try std.fmt.bufPrint(&help_pattern_buffer, "  {s}", .{name});
        try std.testing.expect(std.mem.indexOf(u8, help_text, help_pattern) != null);
    }
}

test "prop approval saves tasks and removes proposal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tasks_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "tasks.json" });
    defer allocator.free(tasks_path);
    const proposal_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "proposal.json" });
    defer allocator.free(proposal_path);

    const json =
        \\{"source":{"provider":"github","repository":"owner/ztodo","issue_number":24,"issue_title":"保存処理"},"summary":"概要","completion_criteria":[],"tasks":[{"title":"first"},{"title":"second"}],"excluded":[],"notes":[]}
    ;
    var proposal = try proposal_mod.decode(allocator, json);
    defer proposal.deinit();
    try proposal_store.save(allocator, io, proposal_path, &proposal);

    var reader: std.Io.Reader = .fixed("q\ny\n");
    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectEqual(PropResult.applied, try editAndApproveAtPaths(
        allocator,
        io,
        tasks_path,
        proposal_path,
        &reader,
        &writer,
    ));

    var data = try store.load(allocator, io, tasks_path);
    defer data.deinit();
    try std.testing.expectEqual(@as(usize, 2), data.tasks.items.len);
    try std.testing.expect(!try proposal_store.exists(io, proposal_path));
}

test "prop rejection saves edits without adding tasks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tasks_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "tasks.json" });
    defer allocator.free(tasks_path);
    const proposal_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "proposal.json" });
    defer allocator.free(proposal_path);

    const json =
        \\{"source":{"provider":"github","repository":"owner/ztodo","issue_number":24,"issue_title":"保存処理"},"summary":"概要","completion_criteria":[],"tasks":[{"title":"first"}],"excluded":[],"notes":[]}
    ;
    var proposal = try proposal_mod.decode(allocator, json);
    defer proposal.deinit();
    try proposal_store.save(allocator, io, proposal_path, &proposal);

    var reader: std.Io.Reader = .fixed("e 1\nedited\nq\nN\n");
    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectEqual(PropResult.saved, try editAndApproveAtPaths(
        allocator,
        io,
        tasks_path,
        proposal_path,
        &reader,
        &writer,
    ));
    try std.testing.expect(!try proposal_store.exists(io, tasks_path));
    try std.testing.expect(try proposal_store.exists(io, proposal_path));
    var saved = try proposal_store.load(allocator, io, proposal_path);
    defer saved.deinit();
    try std.testing.expectEqualStrings("edited", saved.tasks.items[0].title);
}

const std = @import("std");
const proposal_mod = @import("model.zig");

pub const Result = enum {
    save,
    aborted,
};

pub const Command = union(enum) {
    add,
    edit: usize,
    delete: usize,
    move: usize,
    show,
    quit,
};

pub fn parseCommand(line: []const u8) !Command {
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    const name = tokens.next() orelse return error.InvalidCommand;

    if (std.mem.eql(u8, name, "a")) {
        if (tokens.next() != null) return error.InvalidCommand;
        return .add;
    }
    if (std.mem.eql(u8, name, "s")) {
        if (tokens.next() != null) return error.InvalidCommand;
        return .show;
    }
    if (std.mem.eql(u8, name, "q")) {
        if (tokens.next() != null) return error.InvalidCommand;
        return .quit;
    }
    if (std.mem.eql(u8, name, "e")) return .{ .edit = try parsePosition(&tokens) };
    if (std.mem.eql(u8, name, "d")) return .{ .delete = try parsePosition(&tokens) };
    if (std.mem.eql(u8, name, "m")) return .{ .move = try parsePosition(&tokens) };
    return error.InvalidCommand;
}

pub fn run(proposal: *proposal_mod.Proposal, reader: *std.Io.Reader, writer: *std.Io.Writer) !Result {
    try show(proposal, writer);

    while (true) {
        try writer.writeAll("> ");
        try writer.flush();
        const line = try readLine(reader) orelse {
            try writer.writeAll("\nInput closed. Changes were not saved.\n");
            return .aborted;
        };
        const command = parseCommand(line) catch {
            try writer.writeAll("Error: invalid editor command.\n");
            continue;
        };

        switch (command) {
            .add => {
                const title = try promptLine(reader, writer, "Task title: ") orelse {
                    try writer.writeAll("\nInput closed. Changes were not saved.\n");
                    return .aborted;
                };
                proposal.addTask(title) catch |err| {
                    try writeEditError(writer, err);
                    continue;
                };
                try writer.print("Added: {s}\n", .{proposal.tasks.items[proposal.tasks.items.len - 1].title});
            },
            .edit => |index| {
                if (index >= proposal.tasks.items.len) {
                    try writeEditError(writer, error.InvalidTaskIndex);
                    continue;
                }
                try writer.print("Current: {s}\n", .{proposal.tasks.items[index].title});
                const title = try promptLine(reader, writer, "New title: ") orelse {
                    try writer.writeAll("\nInput closed. Changes were not saved.\n");
                    return .aborted;
                };
                proposal.editTask(index, title) catch |err| {
                    try writeEditError(writer, err);
                    continue;
                };
                try writer.writeAll("Updated.\n");
            },
            .delete => |index| {
                if (index >= proposal.tasks.items.len) {
                    try writeEditError(writer, error.InvalidTaskIndex);
                    continue;
                }
                try writer.print("Delete \"{s}\"? [y/N] ", .{proposal.tasks.items[index].title});
                try writer.flush();
                const answer = try readLine(reader) orelse {
                    try writer.writeAll("\nInput closed. Changes were not saved.\n");
                    return .aborted;
                };
                if (!std.mem.eql(u8, std.mem.trim(u8, answer, " \t\r"), "y")) {
                    try writer.writeAll("Cancelled.\n");
                    continue;
                }
                try proposal.deleteTask(index);
                try writer.writeAll("Deleted.\n");
            },
            .move => |from| {
                if (from >= proposal.tasks.items.len) {
                    try writeEditError(writer, error.InvalidTaskIndex);
                    continue;
                }
                const destination = try promptLine(reader, writer, "Move to position: ") orelse {
                    try writer.writeAll("\nInput closed. Changes were not saved.\n");
                    return .aborted;
                };
                const to = parseOneBasedPosition(destination) catch {
                    try writeEditError(writer, error.InvalidTaskIndex);
                    continue;
                };
                proposal.moveTask(from, to) catch |err| {
                    try writeEditError(writer, err);
                    continue;
                };
                try writer.writeAll("Moved.\n");
            },
            .show => try show(proposal, writer),
            .quit => return .save,
        }
    }
}

fn show(proposal: *const proposal_mod.Proposal, writer: *std.Io.Writer) !void {
    try writer.print(
        "Issue #{d}: {s}\nRepository: {s}\n\n",
        .{ proposal.source.issue_number, proposal.source.issue_title, proposal.source.repository },
    );
    if (proposal.tasks.items.len == 0) {
        try writer.writeAll("No task candidates.\n");
    } else {
        for (proposal.tasks.items, 1..) |candidate, number| {
            try writer.print("{d}. {s}\n", .{ number, candidate.title });
        }
    }
    try writer.writeAll(
        \\
        \\Commands:
        \\  a       Add
        \\  e <n>   Edit
        \\  d <n>   Delete
        \\  m <n>   Move
        \\  s       Show
        \\  q       Finish editing and review for approval
        \\
        \\
    );
}

fn promptLine(reader: *std.Io.Reader, writer: *std.Io.Writer, prompt: []const u8) !?[]const u8 {
    try writer.writeAll(prompt);
    try writer.flush();
    return readLine(reader);
}

fn readLine(reader: *std.Io.Reader) !?[]const u8 {
    const line = try reader.takeDelimiter('\n') orelse return null;
    return std.mem.trimEnd(u8, line, "\r");
}

fn parsePosition(tokens: *std.mem.TokenIterator(u8, .scalar)) !usize {
    const value = tokens.next() orelse return error.InvalidCommand;
    if (tokens.next() != null) return error.InvalidCommand;
    return parseOneBasedPosition(value) catch return error.InvalidCommand;
}

fn parseOneBasedPosition(value: []const u8) !usize {
    const number = std.fmt.parseInt(usize, std.mem.trim(u8, value, " \t\r"), 10) catch return error.InvalidTaskIndex;
    if (number == 0) return error.InvalidTaskIndex;
    return number - 1;
}

fn writeEditError(writer: *std.Io.Writer, err: anyerror) !void {
    const message = switch (err) {
        error.EmptyTitle => "title must not be empty.",
        error.InvalidTitle => "title contains invalid characters.",
        error.TitleTooLong => "title must be 200 characters or fewer.",
        error.DuplicateTitle => "the proposal already contains that task.",
        error.TooManyTasks => "the proposal cannot contain more than 20 tasks.",
        error.InvalidTaskIndex => "task number is out of range.",
        else => "operation failed.",
    };
    try writer.print("Error: {s}\n", .{message});
}

test "editor command parsing uses one-based positions" {
    try std.testing.expect((try parseCommand("a")) == .add);
    try std.testing.expect((try parseCommand("s")) == .show);
    try std.testing.expect((try parseCommand("q")) == .quit);
    try std.testing.expectEqual(@as(usize, 1), (try parseCommand("e 2")).edit);
    try std.testing.expectEqual(@as(usize, 2), (try parseCommand("d 3")).delete);
    try std.testing.expectEqual(@as(usize, 3), (try parseCommand("m 4")).move);
    try std.testing.expectError(error.InvalidCommand, parseCommand(""));
    try std.testing.expectError(error.InvalidCommand, parseCommand("e 0"));
    try std.testing.expectError(error.InvalidCommand, parseCommand("e nope"));
    try std.testing.expectError(error.InvalidCommand, parseCommand("a extra"));
}

test "editor session applies commands and returns save only on quit" {
    const json =
        \\{"source":{"provider":"github","repository":"owner/ztodo","issue_number":24,"issue_title":"保存処理"},"summary":"概要","completion_criteria":[],"tasks":[{"title":"first"},{"title":"second"},{"title":"third"}],"excluded":[],"notes":[]}
    ;
    var proposal = try proposal_mod.decode(std.testing.allocator, json);
    defer proposal.deinit();

    var reader: std.Io.Reader = .fixed(
        "a\nfourth\ne 2\nupdated\nd 1\ny\nm 3\n1\ns\nq\n",
    );
    var output_buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectEqual(Result.save, try run(&proposal, &reader, &writer));

    try std.testing.expectEqual(@as(usize, 3), proposal.tasks.items.len);
    try std.testing.expectEqualStrings("fourth", proposal.tasks.items[0].title);
    try std.testing.expectEqualStrings("updated", proposal.tasks.items[1].title);
    try std.testing.expectEqualStrings("third", proposal.tasks.items[2].title);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Deleted.") != null);
}

test "editor cancels delete unless answer is exactly y" {
    const json =
        \\{"source":{"provider":"github","repository":"o/r","issue_number":1,"issue_title":"i"},"summary":"s","completion_criteria":[],"tasks":[{"title":"keep"}],"excluded":[],"notes":[]}
    ;
    var proposal = try proposal_mod.decode(std.testing.allocator, json);
    defer proposal.deinit();

    var reader: std.Io.Reader = .fixed("d 1\nN\nq\n");
    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectEqual(Result.save, try run(&proposal, &reader, &writer));
    try std.testing.expectEqual(@as(usize, 1), proposal.tasks.items.len);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Cancelled.") != null);
}

test "editor returns aborted when input closes before quit" {
    const json =
        \\{"source":{"provider":"github","repository":"o/r","issue_number":1,"issue_title":"i"},"summary":"s","completion_criteria":[],"tasks":[],"excluded":[],"notes":[]}
    ;
    var proposal = try proposal_mod.decode(std.testing.allocator, json);
    defer proposal.deinit();

    var reader: std.Io.Reader = .fixed("a\nunsaved\n");
    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectEqual(Result.aborted, try run(&proposal, &reader, &writer));
    try std.testing.expectEqual(@as(usize, 1), proposal.tasks.items.len);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Changes were not saved.") != null);
}

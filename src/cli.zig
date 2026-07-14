const std = @import("std");
const store = @import("store.zig");
const paths = @import("paths.zig");

pub const version = "0.1.0";

pub const Command = union(enum) {
    help,
    version,
    list,
    add: []const []const u8,
    done: u64,
    delete: u64,
    clear,
};

pub fn parse(args: []const []const u8) !Command {
    if (args.len <= 1) return .help;
    const name = args[1];
    if (std.mem.eql(u8, name, "help")) return requireNoExtra(args, .help);
    if (std.mem.eql(u8, name, "version")) return requireNoExtra(args, .version);
    if (std.mem.eql(u8, name, "list")) return requireNoExtra(args, .list);
    if (std.mem.eql(u8, name, "clear")) return requireNoExtra(args, .clear);
    if (std.mem.eql(u8, name, "add")) {
        if (args.len < 3) return error.MissingArgument;
        return .{ .add = args[2..] };
    }
    if (std.mem.eql(u8, name, "done")) return .{ .done = try parseId(args) };
    if (std.mem.eql(u8, name, "delete")) return .{ .delete = try parseId(args) };
    return error.UnknownCommand;
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
        .list => {
            if (data.tasks.items.len == 0) stdout.interface.writeAll("No tasks.\n") catch return 1 else for (data.tasks.items) |task| stdout.interface.print("[{s}] {d}  {s}\n", .{ if (task.status == .done) "x" else " ", task.id, task.title }) catch return 1;
        },
        .add => |parts| {
            const joined = std.mem.join(allocator, " ", parts) catch return 1;
            defer allocator.free(joined);
            var time_buffer: [20]u8 = undefined;
            const now = formatNow(io, &time_buffer) catch {
                writeRuntimeError(io, error.ClockFailed, 0);
                return 1;
            };
            const task = data.add(joined, now) catch |err| {
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
        .delete => |id| {
            const deleted = data.delete(id) catch |err| {
                writeRuntimeError(io, err, id);
                return 1;
            };
            defer {
                allocator.free(deleted.title);
                allocator.free(deleted.created_at);
            }
            if (!persist(allocator, io, path, &data)) return 1;
            stdout.interface.print("Deleted task {d}: {s}\n", .{ id, deleted.title }) catch return 1;
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

fn formatNow(io: std.Io, buffer: *[20]u8) ![]const u8 {
    const seconds_i = std.Io.Clock.real.now(io).toSeconds();
    if (seconds_i < 0) return error.ClockFailed;
    const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds_i) };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = seconds.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,                 month_day.month.numeric(),        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour(), day_seconds.getSecondsIntoMinute(),
    });
}

fn writeParseError(io: std.Io, err: anyerror) void {
    const message = switch (err) {
        error.UnknownCommand => "unknown command.",
        error.MissingArgument => "missing required argument.",
        error.InvalidId => "id must be a positive integer.",
        error.UnexpectedArgument => "unexpected argument.",
        else => "invalid input.",
    };
    writeStderr(io, "Error: {s}\n\nUsage: ztodo <command> [arguments]\n", .{message});
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
        error.ClockFailed => "could not read the current time.",
        else => "operation failed.",
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
    \\  ztodo <command> [arguments]
    \\
    \\Commands:
    \\  add <title...>  Add a task; title arguments are joined with spaces
    \\  list            List todo and done tasks in ID order
    \\  done <id>       Mark a task as done
    \\  delete <id>     Delete one task without confirmation
    \\  clear           Delete all tasks and reset the next ID to 1
    \\  help            Show this help
    \\  version         Show version
    \\
    \\Examples:
    \\  ztodo add READMEを 更新する
    \\  ztodo done 1
    \\
    \\Warning:
    \\  clear runs without confirmation and cannot be undone.
    \\
;

test "CLI argument parsing" {
    const no_args = [_][]const u8{"ztodo"};
    try std.testing.expect((try parse(&no_args)) == .help);
    const unknown = [_][]const u8{ "ztodo", "wat" };
    try std.testing.expectError(error.UnknownCommand, parse(&unknown));
    const add = [_][]const u8{ "ztodo", "add" };
    try std.testing.expectError(error.MissingArgument, parse(&add));
    const bad_done = [_][]const u8{ "ztodo", "done", "abc" };
    try std.testing.expectError(error.InvalidId, parse(&bad_done));
    const bad_delete = [_][]const u8{ "ztodo", "delete", "0" };
    try std.testing.expectError(error.InvalidId, parse(&bad_delete));
    const clear = [_][]const u8{ "ztodo", "clear" };
    try std.testing.expect((try parse(&clear)) == .clear);
    const clear_extra = [_][]const u8{ "ztodo", "clear", "now" };
    try std.testing.expectError(error.UnexpectedArgument, parse(&clear_extra));
    try std.testing.expect(std.mem.indexOf(u8, help_text, "add <title...>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "clear runs without confirmation") != null);
}

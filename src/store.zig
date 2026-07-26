const std = @import("std");
const task_mod = @import("task.zig");

pub const schema_version: u32 = 1;
pub const max_file_size = 16 * 1024 * 1024;
pub const Task = task_mod.Task;
pub const Status = task_mod.Status;

pub const Data = struct {
    allocator: std.mem.Allocator,
    next_id: u64 = 1,
    tasks: std.ArrayList(Task) = .empty,

    pub fn init(allocator: std.mem.Allocator) Data {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Data) void {
        for (self.tasks.items) |task| {
            self.allocator.free(task.title);
        }
        self.tasks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Data, title_input: []const u8) !*const Task {
        const title = try task_mod.trimmedTitle(title_input);
        const title_copy = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(title_copy);

        try self.tasks.append(self.allocator, .{
            .id = self.next_id,
            .title = title_copy,
            .status = .todo,
        });
        self.next_id += 1;
        return &self.tasks.items[self.tasks.items.len - 1];
    }

    pub fn find(self: *Data, id: u64) ?*Task {
        for (self.tasks.items) |*task| if (task.id == id) return task;
        return null;
    }

    pub fn complete(self: *Data, id: u64) error{TaskNotFound}!bool {
        const task = self.find(id) orelse return error.TaskNotFound;
        if (task.status == .done) return false;
        task.status = .done;
        return true;
    }

    pub fn delete(self: *Data, id: u64) error{TaskNotFound}!Task {
        for (self.tasks.items, 0..) |task, index| {
            if (task.id == id) return self.tasks.orderedRemove(index);
        }
        return error.TaskNotFound;
    }

    pub fn clear(self: *Data) usize {
        const count = self.tasks.items.len;
        for (self.tasks.items) |task| {
            self.allocator.free(task.title);
        }
        self.tasks.clearRetainingCapacity();
        self.next_id = 1;
        return count;
    }
};

const DiskData = struct {
    schema_version: u32,
    next_id: u64,
    tasks: []const Task,
};

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Data {
    // schema_version still guards incompatible formats; ignoring removed fields
    // keeps data written by older versions readable.
    var parsed = std.json.parseFromSlice(DiskData, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidJson;
    defer parsed.deinit();
    if (parsed.value.schema_version != schema_version) return error.UnsupportedSchemaVersion;

    var data = Data.init(allocator);
    errdefer data.deinit();
    data.next_id = parsed.value.next_id;
    for (parsed.value.tasks) |task| {
        const title = try allocator.dupe(u8, task.title);
        errdefer allocator.free(title);
        try data.tasks.append(allocator, .{
            .id = task.id,
            .title = title,
            .status = task.status,
        });
    }
    std.mem.sort(Task, data.tasks.items, {}, struct {
        fn lessThan(_: void, a: Task, b: Task) bool {
            return a.id < b.id;
        }
    }.lessThan);
    return data;
}

pub fn encode(allocator: std.mem.Allocator, data: *const Data) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, DiskData{
        .schema_version = schema_version,
        .next_id = data.next_id,
        .tasks = data.tasks.items,
    }, .{ .whitespace = .indent_2 });
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Data {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_size)) catch |err| switch (err) {
        error.FileNotFound => return Data.init(allocator),
        else => return error.ReadFailed,
    };
    defer allocator.free(bytes);
    return decode(allocator, bytes);
}

pub fn save(allocator: std.mem.Allocator, io: std.Io, path: []const u8, data: *const Data) !void {
    const bytes = try encode(allocator, data);
    defer allocator.free(bytes);

    var atomic = std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true }) catch return error.WriteFailed;
    defer atomic.deinit(io);
    std.Io.File.writeStreamingAll(atomic.file, io, bytes) catch return error.WriteFailed;
    atomic.file.sync(io) catch return error.WriteFailed;
    atomic.replace(io) catch return error.WriteFailed;
}

test "task operations preserve monotonic ids and idempotent completion" {
    var data = Data.init(std.testing.allocator);
    defer data.deinit();
    const first = try data.add(" first ");
    try std.testing.expectEqual(@as(u64, 1), first.id);
    try std.testing.expectEqual(Status.todo, first.status);
    _ = try data.add("second");
    const deleted = try data.delete(1);
    defer data.allocator.free(deleted.title);
    const third = try data.add("third");
    try std.testing.expectEqual(@as(u64, 3), third.id);
    try std.testing.expect(try data.complete(3));
    try std.testing.expect(!(try data.complete(3)));
    try std.testing.expectError(error.TaskNotFound, data.complete(99));
    try std.testing.expectError(error.TaskNotFound, data.delete(99));
}

test "clear removes tasks and resets the next id" {
    var data = Data.init(std.testing.allocator);
    defer data.deinit();
    _ = try data.add("first");
    _ = try data.add("second");

    try std.testing.expectEqual(@as(usize, 2), data.clear());
    try std.testing.expectEqual(@as(usize, 0), data.tasks.items.len);
    try std.testing.expectEqual(@as(u64, 1), data.next_id);
    try std.testing.expectEqual(@as(u64, 1), (try data.add("new")).id);
}

test "JSON round trip supports unicode quotes statuses and next id" {
    var data = Data.init(std.testing.allocator);
    defer data.deinit();
    _ = try data.add("日本語と\"引用符\"");
    _ = try data.add("todo");
    _ = try data.complete(1);
    const json = try encode(std.testing.allocator, &data);
    defer std.testing.allocator.free(json);
    var restored = try decode(std.testing.allocator, json);
    defer restored.deinit();
    try std.testing.expectEqual(@as(u64, 3), restored.next_id);
    try std.testing.expectEqualStrings("日本語と\"引用符\"", restored.tasks.items[0].title);
    try std.testing.expectEqual(Status.done, restored.tasks.items[0].status);
    try std.testing.expectEqual(Status.todo, restored.tasks.items[1].status);
}

test "legacy JSON with created_at remains readable and is rewritten without it" {
    const legacy =
        \\{"schema_version":1,"next_id":2,"tasks":[{"id":1,"title":"legacy","status":"todo","created_at":"2026-07-14T12:00:00Z"}]}
    ;
    var data = try decode(std.testing.allocator, legacy);
    defer data.deinit();
    try std.testing.expectEqualStrings("legacy", data.tasks.items[0].title);

    const json = try encode(std.testing.allocator, &data);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "created_at") == null);
}

test "unknown schema and corrupt JSON are rejected" {
    try std.testing.expectError(error.UnsupportedSchemaVersion, decode(std.testing.allocator, "{\"schema_version\":2,\"next_id\":1,\"tasks\":[]}"));
    try std.testing.expectError(error.InvalidJson, decode(std.testing.allocator, "{broken"));
}

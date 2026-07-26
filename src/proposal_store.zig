const std = @import("std");
const proposal_mod = @import("proposal.zig");

pub const max_file_size = 1024 * 1024;

pub fn exists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.ReadFailed,
    };
    return true;
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !proposal_mod.Proposal {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_size)) catch |err| switch (err) {
        error.FileNotFound => return error.ProposalNotFound,
        else => return error.ReadFailed,
    };
    defer allocator.free(bytes);
    return proposal_mod.decode(allocator, bytes);
}

pub fn save(allocator: std.mem.Allocator, io: std.Io, path: []const u8, proposal: *const proposal_mod.Proposal) !void {
    const bytes = try proposal_mod.encode(allocator, proposal);
    defer allocator.free(bytes);

    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch return error.CreateDirectoryFailed;
    }
    var atomic = std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true }) catch return error.WriteFailed;
    defer atomic.deinit(io);
    std.Io.File.writeStreamingAll(atomic.file, io, bytes) catch return error.WriteFailed;
    atomic.file.sync(io) catch return error.WriteFailed;
    atomic.replace(io) catch return error.WriteFailed;
}

pub fn delete(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return error.ProposalNotFound,
        else => return error.DeleteFailed,
    };
}

test "proposal file lifecycle" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "proposal.json" });
    defer allocator.free(path);

    try std.testing.expect(!try exists(io, path));
    try std.testing.expectError(error.ProposalNotFound, load(allocator, io, path));

    const json =
        \\{"source":{"provider":"github","repository":"owner/ztodo","issue_number":24,"issue_title":"保存処理"},"summary":"概要","completion_criteria":["保存できる"],"tasks":[{"title":"JSON保存処理を実装する"}],"excluded":[],"notes":[]}
    ;
    var proposal = try proposal_mod.decode(allocator, json);
    defer proposal.deinit();

    try save(allocator, io, path, &proposal);
    try std.testing.expect(try exists(io, path));

    var loaded = try load(allocator, io, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("owner/ztodo", loaded.source.repository);
    try std.testing.expectEqual(@as(u64, 24), loaded.source.issue_number);
    try std.testing.expectEqual(@as(usize, 1), loaded.tasks.items.len);
    try std.testing.expectEqualStrings("JSON保存処理を実装する", loaded.tasks.items[0].title);

    try delete(io, path);
    try std.testing.expect(!try exists(io, path));
    try std.testing.expectError(error.ProposalNotFound, delete(io, path));
}

test "save creates a missing parent directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "nested", "ztodo", "proposal.json" });
    defer allocator.free(path);

    const json =
        \\{"source":{"provider":"github","repository":"owner/ztodo","issue_number":24,"issue_title":"保存処理"},"summary":"概要","completion_criteria":[],"tasks":[],"excluded":[],"notes":[]}
    ;
    var proposal = try proposal_mod.decode(allocator, json);
    defer proposal.deinit();

    try std.testing.expect(!try exists(io, path));
    try save(allocator, io, path, &proposal);
    try std.testing.expect(try exists(io, path));
}

test "load rejects corrupt proposal JSON" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile(io, "proposal.json", .{});
        defer file.close(io);
        try std.Io.File.writeStreamingAll(file, io, "{broken");
    }

    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "proposal.json" });
    defer allocator.free(path);
    try std.testing.expectError(error.InvalidJson, load(allocator, io, path));
}

test "atomic save replaces the previous proposal with complete JSON" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "proposal.json" });
    defer allocator.free(path);

    const first_json =
        \\{"source":{"provider":"github","repository":"owner/ztodo","issue_number":24,"issue_title":"最初のIssue"},"summary":"置換前の長い概要","completion_criteria":["最初の条件"],"tasks":[{"title":"最初のTask"},{"title":"削除されるTask"}],"excluded":["最初の対象外"],"notes":["最初の注記"]}
    ;
    var first = try proposal_mod.decode(allocator, first_json);
    defer first.deinit();
    try save(allocator, io, path, &first);

    const second_json =
        \\{"source":{"provider":"github","repository":"owner/ztodo","issue_number":25,"issue_title":"新しいIssue"},"summary":"新しい概要","completion_criteria":[],"tasks":[{"title":"新しいTask"}],"excluded":[],"notes":[]}
    ;
    var second = try proposal_mod.decode(allocator, second_json);
    defer second.deinit();
    try save(allocator, io, path, &second);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_size));
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "置換前の長い概要") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "削除されるTask") == null);

    var loaded = try proposal_mod.decode(allocator, bytes);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u64, 25), loaded.source.issue_number);
    try std.testing.expectEqualStrings("新しい概要", loaded.summary);
    try std.testing.expectEqual(@as(usize, 1), loaded.tasks.items.len);
    try std.testing.expectEqualStrings("新しいTask", loaded.tasks.items[0].title);
}

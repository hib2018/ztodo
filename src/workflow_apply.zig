const std = @import("std");
const paths = @import("paths.zig");
const proposal_mod = @import("proposal.zig");
const proposal_store = @import("proposal_store.zig");
const store = @import("store.zig");

pub fn applyProposal(
    allocator: std.mem.Allocator,
    io: std.Io,
    tasks_path: []const u8,
    proposal_path: []const u8,
    proposal: *const proposal_mod.Proposal,
) !usize {
    var data = try store.load(allocator, io, tasks_path);
    defer data.deinit();
    return applyLoaded(allocator, io, tasks_path, proposal_path, &data, proposal);
}

fn applyLoaded(
    allocator: std.mem.Allocator,
    io: std.Io,
    tasks_path: []const u8,
    proposal_path: []const u8,
    data: *store.Data,
    proposal: *const proposal_mod.Proposal,
) !usize {
    if (proposal.tasks.items.len == 0) return error.EmptyProposal;

    for (proposal.tasks.items) |candidate| {
        _ = try data.add(candidate.title);
    }

    try paths.ensureParent(io, tasks_path);
    try store.save(allocator, io, tasks_path, data);
    proposal_store.delete(io, proposal_path) catch return error.ProposalCleanupFailed;
    return proposal.tasks.items.len;
}

test "apply adds all candidates with monotonic ids and removes proposal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tasks_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "tasks.json" });
    defer allocator.free(tasks_path);
    const proposal_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "proposal.json" });
    defer allocator.free(proposal_path);

    var data = store.Data.init(allocator);
    defer data.deinit();
    _ = try data.add("existing");
    try store.save(allocator, io, tasks_path, &data);

    const json =
        \\{"source":{"provider":"github","repository":"owner/ztodo","issue_number":24,"issue_title":"保存処理"},"summary":"概要","completion_criteria":[],"tasks":[{"title":"first"},{"title":"second"}],"excluded":[],"notes":[]}
    ;
    var proposal = try proposal_mod.decode(allocator, json);
    defer proposal.deinit();
    try proposal_store.save(allocator, io, proposal_path, &proposal);

    try std.testing.expectEqual(
        @as(usize, 2),
        try applyProposal(allocator, io, tasks_path, proposal_path, &proposal),
    );

    var applied = try store.load(allocator, io, tasks_path);
    defer applied.deinit();
    try std.testing.expectEqual(@as(usize, 3), applied.tasks.items.len);
    try std.testing.expectEqual(@as(u64, 2), applied.tasks.items[1].id);
    try std.testing.expectEqualStrings("first", applied.tasks.items[1].title);
    try std.testing.expectEqual(@as(u64, 3), applied.tasks.items[2].id);
    try std.testing.expectEqualStrings("second", applied.tasks.items[2].title);
    try std.testing.expect(!try proposal_store.exists(io, proposal_path));
}

test "empty proposal is rejected without changing files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tasks_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "tasks.json" });
    defer allocator.free(tasks_path);
    const proposal_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "proposal.json" });
    defer allocator.free(proposal_path);
    const json =
        \\{"source":{"provider":"github","repository":"owner/ztodo","issue_number":24,"issue_title":"保存処理"},"summary":"概要","completion_criteria":[],"tasks":[],"excluded":[],"notes":[]}
    ;
    var proposal = try proposal_mod.decode(allocator, json);
    defer proposal.deinit();
    try proposal_store.save(allocator, io, proposal_path, &proposal);

    try std.testing.expectError(
        error.EmptyProposal,
        applyProposal(allocator, io, tasks_path, proposal_path, &proposal),
    );
    try std.testing.expect(!try proposal_store.exists(io, tasks_path));
    try std.testing.expect(try proposal_store.exists(io, proposal_path));
}

test "task save failure keeps the proposal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tasks_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tasks_path);
    const proposal_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "proposal.json" });
    defer allocator.free(proposal_path);
    const json =
        \\{"source":{"provider":"github","repository":"owner/ztodo","issue_number":24,"issue_title":"保存処理"},"summary":"概要","completion_criteria":[],"tasks":[{"title":"first"},{"title":"second"}],"excluded":[],"notes":[]}
    ;
    var proposal = try proposal_mod.decode(allocator, json);
    defer proposal.deinit();
    try proposal_store.save(allocator, io, proposal_path, &proposal);
    var data = store.Data.init(allocator);
    defer data.deinit();

    try std.testing.expectError(
        error.WriteFailed,
        applyLoaded(allocator, io, tasks_path, proposal_path, &data, &proposal),
    );
    try std.testing.expect(try proposal_store.exists(io, proposal_path));
}

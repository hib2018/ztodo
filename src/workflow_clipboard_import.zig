const std = @import("std");
const proposal_mod = @import("proposal.zig");
const proposal_store = @import("proposal_store.zig");

pub fn import(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
) !usize {
    if (try proposal_store.exists(io, path)) return error.ProposalAlreadyExists;
    var proposal = try proposal_mod.decode(allocator, bytes);
    defer proposal.deinit();
    if (proposal.tasks.items.len == 0) return error.EmptyProposal;
    const count = proposal.tasks.items.len;
    try proposal_store.save(allocator, io, path, &proposal);
    return count;
}

test "imports validated clipboard JSON without overwriting" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(
        allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path, "proposal.json" },
    );
    defer allocator.free(path);
    const json =
        \\{"schema_version":1,"source":{"provider":"github-cli","repository":"owner/repo","issue_number":12,"issue_title":"Import"},"summary":"概要","completion_criteria":["完了する"],"tasks":[{"title":"実装する"},{"title":"テストする"}],"excluded":[],"notes":[]}
    ;
    try std.testing.expectEqual(@as(usize, 2), try import(
        allocator,
        io,
        path,
        json,
    ));
    var saved = try proposal_store.load(allocator, io, path);
    defer saved.deinit();
    try std.testing.expectEqualStrings("実装する", saved.tasks.items[0].title);
    try std.testing.expectError(
        error.ProposalAlreadyExists,
        import(allocator, io, path, json),
    );
}

test "rejects invalid or empty Proposal before saving" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(
        allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path, "proposal.json" },
    );
    defer allocator.free(path);
    try std.testing.expectError(
        error.InvalidJson,
        import(allocator, io, path, "not json"),
    );
    const empty =
        \\{"schema_version":1,"source":{"provider":"github-cli","repository":"owner/repo","issue_number":12,"issue_title":"Import"},"summary":"概要","completion_criteria":[],"tasks":[],"excluded":[],"notes":[]}
    ;
    try std.testing.expectError(
        error.EmptyProposal,
        import(allocator, io, path, empty),
    );
    try std.testing.expect(!try proposal_store.exists(io, path));
}

const std = @import("std");

pub const Issue = struct {
    allocator: std.mem.Allocator,
    provider: []const u8,
    repository: []const u8,
    number: u64,
    title: []const u8,
    body: []const u8,

    pub fn deinit(self: *Issue) void {
        self.allocator.free(self.provider);
        self.allocator.free(self.repository);
        self.allocator.free(self.title);
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    provider: []const u8,
    repository: []const u8,
    number: u64,
    title: []const u8,
    body: []const u8,
) !Issue {
    const provider_copy = try allocator.dupe(u8, provider);
    errdefer allocator.free(provider_copy);
    const repository_copy = try allocator.dupe(u8, repository);
    errdefer allocator.free(repository_copy);
    const title_copy = try allocator.dupe(u8, title);
    errdefer allocator.free(title_copy);
    const body_copy = try allocator.dupe(u8, body);
    return .{
        .allocator = allocator,
        .provider = provider_copy,
        .repository = repository_copy,
        .number = number,
        .title = title_copy,
        .body = body_copy,
    };
}

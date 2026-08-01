const std = @import("std");

pub const schema_version: u32 = 1;
pub const max_tasks = 20;
pub const max_title_codepoints = 200;
pub const max_provider_codepoints = 50;
pub const max_repository_codepoints = 200;
pub const max_issue_title_codepoints = 256;
pub const max_summary_codepoints = 2000;
pub const max_list_items = 20;
pub const max_list_item_codepoints = 500;

pub const Source = struct {
    provider: []const u8,
    repository: []const u8,
    issue_number: u64,
    issue_title: []const u8,
};

pub const Candidate = struct {
    title: []const u8,
};

pub const Proposal = struct {
    allocator: std.mem.Allocator,
    source: Source,
    summary: []const u8,
    completion_criteria: []const []const u8,
    tasks: std.ArrayList(Candidate),
    excluded: []const []const u8,
    notes: []const []const u8,

    pub fn deinit(self: *Proposal) void {
        self.allocator.free(self.source.provider);
        self.allocator.free(self.source.repository);
        self.allocator.free(self.source.issue_title);
        self.allocator.free(self.summary);
        freeStrings(self.allocator, self.completion_criteria);
        for (self.tasks.items) |task| self.allocator.free(task.title);
        self.tasks.deinit(self.allocator);
        freeStrings(self.allocator, self.excluded);
        freeStrings(self.allocator, self.notes);
        self.* = undefined;
    }

    pub fn validate(self: *const Proposal) !void {
        _ = try validateProvider(self.source.provider);
        _ = try validateRepository(self.source.repository);
        if (self.source.issue_number == 0) return error.InvalidIssueNumber;
        _ = try validateText(self.source.issue_title, max_issue_title_codepoints, false);
        _ = try validateText(self.summary, max_summary_codepoints, false);
        try validateStringList(self.completion_criteria);
        try validateStringList(self.excluded);
        try validateStringList(self.notes);
        if (self.tasks.items.len > max_tasks) return error.TooManyTasks;
        for (self.tasks.items, 0..) |candidate, index| {
            const title = try validateTitle(candidate.title);
            try self.ensureUniqueTitle(title, index);
        }
    }

    pub fn addTask(self: *Proposal, title_input: []const u8) !void {
        if (self.tasks.items.len >= max_tasks) return error.TooManyTasks;
        const title = try validateTitle(title_input);
        try self.ensureUniqueTitle(title, null);

        const title_copy = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(title_copy);
        try self.tasks.append(self.allocator, .{ .title = title_copy });
    }

    pub fn editTask(self: *Proposal, index: usize, title_input: []const u8) !void {
        if (index >= self.tasks.items.len) return error.InvalidTaskIndex;
        const title = try validateTitle(title_input);
        try self.ensureUniqueTitle(title, index);

        const title_copy = try self.allocator.dupe(u8, title);
        const old_title = self.tasks.items[index].title;
        self.tasks.items[index].title = title_copy;
        self.allocator.free(old_title);
    }

    pub fn deleteTask(self: *Proposal, index: usize) !void {
        if (index >= self.tasks.items.len) return error.InvalidTaskIndex;
        const removed = self.tasks.orderedRemove(index);
        self.allocator.free(removed.title);
    }

    pub fn moveTask(self: *Proposal, from: usize, to: usize) !void {
        if (from >= self.tasks.items.len or to >= self.tasks.items.len) return error.InvalidTaskIndex;
        if (from == to) return;
        const moved = self.tasks.orderedRemove(from);
        self.tasks.insertAssumeCapacity(to, moved);
    }

    fn ensureUniqueTitle(self: *const Proposal, title: []const u8, skip_index: ?usize) !void {
        for (self.tasks.items, 0..) |candidate, index| {
            if (skip_index != null and index == skip_index.?) continue;
            if (std.mem.eql(u8, title, candidate.title)) return error.DuplicateTitle;
        }
    }
};

const DiskProposal = struct {
    schema_version: u32 = schema_version,
    source: Source,
    summary: []const u8,
    completion_criteria: []const []const u8,
    tasks: []const Candidate,
    excluded: []const []const u8,
    notes: []const []const u8,
};

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Proposal {
    var parsed = std.json.parseFromSlice(DiskProposal, allocator, bytes, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    if (parsed.value.schema_version != schema_version) return error.UnsupportedProposalSchemaVersion;
    if (parsed.value.source.issue_number == 0) return error.InvalidIssueNumber;

    var proposal = Proposal{
        .allocator = allocator,
        .source = .{
            .provider = try dupeValidatedText(allocator, try validateProvider(parsed.value.source.provider)),
            .repository = undefined,
            .issue_number = parsed.value.source.issue_number,
            .issue_title = undefined,
        },
        .summary = undefined,
        .completion_criteria = undefined,
        .tasks = undefined,
        .excluded = undefined,
        .notes = undefined,
    };
    errdefer allocator.free(proposal.source.provider);
    proposal.source.repository = try dupeValidatedText(allocator, try validateRepository(parsed.value.source.repository));
    errdefer allocator.free(proposal.source.repository);
    proposal.source.issue_title = try dupeValidatedText(
        allocator,
        try validateText(parsed.value.source.issue_title, max_issue_title_codepoints, false),
    );
    errdefer allocator.free(proposal.source.issue_title);
    proposal.summary = try dupeValidatedText(
        allocator,
        try validateText(parsed.value.summary, max_summary_codepoints, false),
    );
    errdefer allocator.free(proposal.summary);
    proposal.completion_criteria = try dupeValidatedStrings(allocator, parsed.value.completion_criteria);
    errdefer freeStrings(allocator, proposal.completion_criteria);
    proposal.tasks = try dupeCandidates(allocator, parsed.value.tasks);
    errdefer {
        for (proposal.tasks.items) |task| allocator.free(task.title);
        proposal.tasks.deinit(allocator);
    }
    proposal.excluded = try dupeValidatedStrings(allocator, parsed.value.excluded);
    errdefer freeStrings(allocator, proposal.excluded);
    proposal.notes = try dupeValidatedStrings(allocator, parsed.value.notes);
    errdefer freeStrings(allocator, proposal.notes);
    try proposal.validate();
    return proposal;
}

pub fn encode(allocator: std.mem.Allocator, proposal: *const Proposal) ![]u8 {
    try proposal.validate();
    return std.json.Stringify.valueAlloc(allocator, DiskProposal{
        .schema_version = schema_version,
        .source = proposal.source,
        .summary = proposal.summary,
        .completion_criteria = proposal.completion_criteria,
        .tasks = proposal.tasks.items,
        .excluded = proposal.excluded,
        .notes = proposal.notes,
    }, .{ .whitespace = .indent_2 });
}

fn validateTitle(title_input: []const u8) ![]const u8 {
    return validateText(title_input, max_title_codepoints, false) catch |err| switch (err) {
        error.EmptyText => error.EmptyTitle,
        error.InvalidText => error.InvalidTitle,
        error.TextTooLong => error.TitleTooLong,
    };
}

fn validateText(value: []const u8, max_codepoints: usize, allow_empty: bool) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 and !allow_empty) return error.EmptyText;

    const view = std.unicode.Utf8View.init(trimmed) catch return error.InvalidText;
    var iterator = view.iterator();
    var count: usize = 0;
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint <= 0x1f or (codepoint >= 0x7f and codepoint <= 0x9f)) return error.InvalidText;
        count += 1;
    }
    if (count > max_codepoints) return error.TextTooLong;
    return trimmed;
}

fn validateProvider(value: []const u8) ![]const u8 {
    const provider = try validateText(value, max_provider_codepoints, false);
    for (provider) |byte| if (std.ascii.isWhitespace(byte)) return error.InvalidProvider;
    return provider;
}

fn validateRepository(value: []const u8) ![]const u8 {
    const repository = try validateText(value, max_repository_codepoints, false);
    if (std.mem.count(u8, repository, "/") != 1) return error.InvalidRepository;
    const slash = std.mem.indexOfScalar(u8, repository, '/').?;
    if (slash == 0 or slash + 1 == repository.len) return error.InvalidRepository;
    for (repository) |byte| if (std.ascii.isWhitespace(byte)) return error.InvalidRepository;
    return repository;
}

fn validateStringList(values: []const []const u8) !void {
    if (values.len > max_list_items) return error.TooManyItems;
    for (values) |value| {
        _ = try validateText(value, max_list_item_codepoints, false);
    }
}

fn dupeValidatedText(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    return allocator.dupe(u8, value);
}

fn dupeValidatedStrings(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    try validateStringList(values);
    const copies = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(copies);
    var copied: usize = 0;
    errdefer for (copies[0..copied]) |value| allocator.free(value);
    for (values, 0..) |value, index| {
        const normalized = try validateText(value, max_list_item_codepoints, false);
        copies[index] = try allocator.dupe(u8, normalized);
        copied += 1;
    }
    return copies;
}

fn dupeCandidates(allocator: std.mem.Allocator, values: []const Candidate) !std.ArrayList(Candidate) {
    var copies: std.ArrayList(Candidate) = .empty;
    errdefer {
        for (copies.items) |value| allocator.free(value.title);
        copies.deinit(allocator);
    }
    try copies.ensureTotalCapacity(allocator, values.len);
    for (values) |value| {
        const title = try validateTitle(value.title);
        copies.appendAssumeCapacity(.{ .title = try allocator.dupe(u8, title) });
    }
    return copies;
}

fn freeStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "proposal JSON round trip" {
    const json =
        \\{"source":{"provider":"github","repository":"owner/ztodo","issue_number":24,"issue_title":"保存処理"},"summary":"概要","completion_criteria":["保存できる"],"tasks":[{"title":"JSON保存処理を実装する"}],"excluded":[],"notes":[]}
    ;
    var proposal = try decode(std.testing.allocator, json);
    defer proposal.deinit();
    try std.testing.expectEqual(@as(u64, 24), proposal.source.issue_number);
    try std.testing.expectEqualStrings("JSON保存処理を実装する", proposal.tasks.items[0].title);

    const encoded = try encode(std.testing.allocator, &proposal);
    defer std.testing.allocator.free(encoded);
    var restored = try decode(std.testing.allocator, encoded);
    defer restored.deinit();
    try std.testing.expectEqualStrings("owner/ztodo", restored.source.repository);
}

test "proposal rejects invalid task candidates" {
    const empty =
        \\{"source":{"provider":"github","repository":"o/r","issue_number":1,"issue_title":"i"},"summary":"s","completion_criteria":[],"tasks":[{"title":"  "}],"excluded":[],"notes":[]}
    ;
    try std.testing.expectError(error.EmptyTitle, decode(std.testing.allocator, empty));

    const duplicate =
        \\{"source":{"provider":"github","repository":"o/r","issue_number":1,"issue_title":"i"},"summary":"s","completion_criteria":[],"tasks":[{"title":"same"},{"title":" same "}],"excluded":[],"notes":[]}
    ;
    try std.testing.expectError(error.DuplicateTitle, decode(std.testing.allocator, duplicate));
}

test "task candidates can be added edited deleted and moved" {
    const json =
        \\{"source":{"provider":"github","repository":"o/r","issue_number":1,"issue_title":"i"},"summary":"s","completion_criteria":[],"tasks":[{"title":"first"},{"title":"second"},{"title":"third"}],"excluded":[],"notes":[]}
    ;
    var proposal = try decode(std.testing.allocator, json);
    defer proposal.deinit();

    try proposal.addTask("  fourth  ");
    try std.testing.expectEqualStrings("fourth", proposal.tasks.items[3].title);

    try proposal.editTask(1, "updated");
    try std.testing.expectEqualStrings("updated", proposal.tasks.items[1].title);

    try proposal.moveTask(3, 1);
    try std.testing.expectEqualStrings("fourth", proposal.tasks.items[1].title);
    try std.testing.expectEqualStrings("updated", proposal.tasks.items[2].title);

    try proposal.deleteTask(0);
    try std.testing.expectEqual(@as(usize, 3), proposal.tasks.items.len);
    try std.testing.expectEqualStrings("fourth", proposal.tasks.items[0].title);

    try proposal.deleteTask(0);
    try proposal.deleteTask(0);
    try proposal.deleteTask(0);
    try std.testing.expectEqual(@as(usize, 0), proposal.tasks.items.len);
}

test "invalid edits leave task candidates unchanged" {
    const json =
        \\{"source":{"provider":"github","repository":"o/r","issue_number":1,"issue_title":"i"},"summary":"s","completion_criteria":[],"tasks":[{"title":"first"},{"title":"second"}],"excluded":[],"notes":[]}
    ;
    var proposal = try decode(std.testing.allocator, json);
    defer proposal.deinit();

    try std.testing.expectError(error.EmptyTitle, proposal.addTask("  "));
    try std.testing.expectError(error.DuplicateTitle, proposal.addTask("first"));
    try std.testing.expectError(error.DuplicateTitle, proposal.editTask(1, " first "));
    try std.testing.expectError(error.InvalidTaskIndex, proposal.editTask(2, "updated"));
    try std.testing.expectError(error.InvalidTaskIndex, proposal.deleteTask(2));
    try std.testing.expectError(error.InvalidTaskIndex, proposal.moveTask(0, 2));

    try std.testing.expectEqual(@as(usize, 2), proposal.tasks.items.len);
    try std.testing.expectEqualStrings("first", proposal.tasks.items[0].title);
    try std.testing.expectEqualStrings("second", proposal.tasks.items[1].title);
}

test "invalid title boundaries are rejected without mutation" {
    const json =
        \\{"source":{"provider":"github","repository":"o/r","issue_number":1,"issue_title":"i"},"summary":"s","completion_criteria":[],"tasks":[{"title":"original"}],"excluded":[],"notes":[]}
    ;
    var proposal = try decode(std.testing.allocator, json);
    defer proposal.deinit();

    const too_long: [max_title_codepoints + 1]u8 = @splat('a');
    try std.testing.expectError(error.TitleTooLong, proposal.addTask(&too_long));
    try std.testing.expectError(error.InvalidTitle, proposal.addTask("bad\nline"));
    try std.testing.expectError(error.InvalidTitle, proposal.editTask(0, "\xff"));

    try std.testing.expectEqual(@as(usize, 1), proposal.tasks.items.len);
    try std.testing.expectEqualStrings("original", proposal.tasks.items[0].title);
}

test "twenty-first task candidate is rejected" {
    const json =
        \\{"source":{"provider":"github","repository":"o/r","issue_number":1,"issue_title":"i"},"summary":"s","completion_criteria":[],"tasks":[],"excluded":[],"notes":[]}
    ;
    var proposal = try decode(std.testing.allocator, json);
    defer proposal.deinit();

    var buffer: [32]u8 = undefined;
    for (0..max_tasks) |index| {
        const title = try std.fmt.bufPrint(&buffer, "task-{d}", .{index});
        try proposal.addTask(title);
    }
    try std.testing.expectError(error.TooManyTasks, proposal.addTask("one-too-many"));
    try std.testing.expectEqual(@as(usize, max_tasks), proposal.tasks.items.len);
}

test "edited proposal survives JSON round trip" {
    const json =
        \\{"source":{"provider":"github","repository":"o/r","issue_number":1,"issue_title":"i"},"summary":"s","completion_criteria":[],"tasks":[{"title":"first"}],"excluded":[],"notes":[]}
    ;
    var proposal = try decode(std.testing.allocator, json);
    defer proposal.deinit();
    try proposal.addTask("second");
    try proposal.editTask(0, "updated");

    const encoded = try encode(std.testing.allocator, &proposal);
    defer std.testing.allocator.free(encoded);
    var restored = try decode(std.testing.allocator, encoded);
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 2), restored.tasks.items.len);
    try std.testing.expectEqualStrings("updated", restored.tasks.items[0].title);
    try std.testing.expectEqualStrings("second", restored.tasks.items[1].title);
}

test "legacy proposal gains schema version when encoded" {
    const legacy =
        \\{"source":{"provider":"github","repository":"owner/ztodo","issue_number":1,"issue_title":"issue"},"summary":"summary","completion_criteria":[],"tasks":[],"excluded":[],"notes":[]}
    ;
    var proposal = try decode(std.testing.allocator, legacy);
    defer proposal.deinit();

    const encoded = try encode(std.testing.allocator, &proposal);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"schema_version\": 1") != null);
}

test "unsupported schema and unknown fields are rejected" {
    const unsupported =
        \\{"schema_version":2,"source":{"provider":"github","repository":"owner/ztodo","issue_number":1,"issue_title":"issue"},"summary":"summary","completion_criteria":[],"tasks":[],"excluded":[],"notes":[]}
    ;
    try std.testing.expectError(
        error.UnsupportedProposalSchemaVersion,
        decode(std.testing.allocator, unsupported),
    );

    const unknown =
        \\{"schema_version":1,"unexpected":true,"source":{"provider":"github","repository":"owner/ztodo","issue_number":1,"issue_title":"issue"},"summary":"summary","completion_criteria":[],"tasks":[],"excluded":[],"notes":[]}
    ;
    try std.testing.expectError(error.InvalidJson, decode(std.testing.allocator, unknown));
}

test "source and required text fields are validated" {
    const empty_provider =
        \\{"source":{"provider":" ","repository":"owner/ztodo","issue_number":1,"issue_title":"issue"},"summary":"summary","completion_criteria":[],"tasks":[],"excluded":[],"notes":[]}
    ;
    try std.testing.expectError(error.EmptyText, decode(std.testing.allocator, empty_provider));

    const invalid_repository =
        \\{"source":{"provider":"github","repository":"owner-only","issue_number":1,"issue_title":"issue"},"summary":"summary","completion_criteria":[],"tasks":[],"excluded":[],"notes":[]}
    ;
    try std.testing.expectError(error.InvalidRepository, decode(std.testing.allocator, invalid_repository));

    const zero_issue =
        \\{"source":{"provider":"github","repository":"owner/ztodo","issue_number":0,"issue_title":"issue"},"summary":"summary","completion_criteria":[],"tasks":[],"excluded":[],"notes":[]}
    ;
    try std.testing.expectError(error.InvalidIssueNumber, decode(std.testing.allocator, zero_issue));

    const empty_summary =
        \\{"source":{"provider":"github","repository":"owner/ztodo","issue_number":1,"issue_title":"issue"},"summary":" ","completion_criteria":[],"tasks":[],"excluded":[],"notes":[]}
    ;
    try std.testing.expectError(error.EmptyText, decode(std.testing.allocator, empty_summary));
}

test "text limits and control characters are rejected" {
    const too_long_summary: [max_summary_codepoints + 1]u8 = @splat('a');
    try std.testing.expectError(
        error.TextTooLong,
        validateText(&too_long_summary, max_summary_codepoints, false),
    );
    try std.testing.expectError(error.InvalidText, validateText("bad\ttext", 100, false));
    try std.testing.expectError(error.InvalidText, validateText("bad\u{85}text", 100, false));
    try std.testing.expectError(error.InvalidText, validateText("\xff", 100, false));
}

test "proposal list limits and empty elements are rejected" {
    var too_many: [max_list_items + 1][]const u8 = undefined;
    for (&too_many) |*item| item.* = "item";
    try std.testing.expectError(error.TooManyItems, validateStringList(&too_many));
    try std.testing.expectError(error.EmptyText, validateStringList(&.{""}));
}

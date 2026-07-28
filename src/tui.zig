const std = @import("std");
const store = @import("store.zig");

pub const min_columns: u16 = 48;
pub const min_rows: u16 = 12;

pub const Key = enum { up, down, quit, other };

pub const Model = struct {
    selected: usize = 0,
    quit: bool = false,

    pub fn update(self: *Model, key: Key, task_count: usize) void {
        switch (key) {
            .up => if (self.selected > 0) {
                self.selected -= 1;
            },
            .down => if (self.selected + 1 < task_count) {
                self.selected += 1;
            },
            .quit => self.quit = true,
            .other => {},
        }
        if (task_count == 0) self.selected = 0;
    }
};

pub fn decodeKey(first: u8, second: ?u8, third: ?u8) Key {
    if (first == 'q' or first == 3) return .quit;
    if (first == 'k') return .up;
    if (first == 'j') return .down;
    if (first == 0x1b and second == '[' and third == 'A') return .up;
    if (first == 0x1b and second == '[' and third == 'B') return .down;
    return .other;
}

pub fn render(writer: *std.Io.Writer, data: *const store.Data, model: Model, columns: u16, rows: u16) !void {
    try writer.writeAll("\x1b[2J\x1b[H");
    if (columns < min_columns or rows < min_rows) {
        try writer.print("ztodo: terminal too small ({d}x{d}); need at least {d}x{d}.\r\n", .{
            columns, rows, min_columns, min_rows,
        });
        return;
    }

    try writer.writeAll("\x1b[1;36m ztodo\x1b[0m  Tasks\r\n");
    try writer.writeAll("\x1b[2m──────────────────────────────────────────────\x1b[0m\r\n");
    if (data.tasks.items.len == 0) {
        try writer.writeAll("\r\n  No tasks.\r\n");
    } else {
        const available: usize = rows -| 5;
        const start = if (model.selected >= available and available > 0)
            model.selected - available + 1
        else
            0;
        const end = @min(data.tasks.items.len, start + available);
        for (data.tasks.items[start..end], start..) |task, index| {
            const marker = if (index == model.selected) "\x1b[7m>" else " ";
            const reset = if (index == model.selected) "\x1b[0m" else "";
            try writer.print("{s} [{s}] {d: >4}  {s}{s}\r\n", .{
                marker,
                if (task.status == .done) "x" else " ",
                task.id,
                task.title,
                reset,
            });
        }
    }
    try writer.writeAll("\r\n\x1b[2m ↑/k ↓/j move   q quit\x1b[0m\r\n");
}

pub fn run(io: std.Io, data: *const store.Data) !void {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    if (!try stdin.isTty(io) or !try stdout.isTty(io)) return error.NotATerminal;
    try stdout.enableAnsiEscapeCodes(io);

    const original = try std.posix.tcgetattr(stdin.handle);
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin.handle, .FLUSH, raw);
    defer std.posix.tcsetattr(stdin.handle, .FLUSH, original) catch {};

    var out_buffer: [8192]u8 = undefined;
    var out = stdout.writer(io, &out_buffer);
    defer {
        out.interface.writeAll("\x1b[?25h\x1b[?1049l") catch {};
        out.interface.flush() catch {};
    }
    try out.interface.writeAll("\x1b[?1049h\x1b[?25l");

    var in_buffer: [64]u8 = undefined;
    var input = stdin.readerStreaming(io, &in_buffer);
    var model: Model = .{};
    while (!model.quit) {
        try render(&out.interface, data, model, 80, 24);
        try out.interface.flush();
        const first = input.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        var second: ?u8 = null;
        var third: ?u8 = null;
        if (first == 0x1b) {
            second = input.interface.takeByte() catch null;
            if (second == '[') third = input.interface.takeByte() catch null;
        }
        model.update(decodeKey(first, second, third), data.tasks.items.len);
    }
}

test "model selection stays within task bounds" {
    var model: Model = .{};
    model.update(.up, 2);
    try std.testing.expectEqual(@as(usize, 0), model.selected);
    model.update(.down, 2);
    model.update(.down, 2);
    try std.testing.expectEqual(@as(usize, 1), model.selected);
    model.update(.quit, 2);
    try std.testing.expect(model.quit);
}

test "key decoder supports arrows vim keys and interrupt" {
    try std.testing.expectEqual(Key.up, decodeKey(0x1b, '[', 'A'));
    try std.testing.expectEqual(Key.down, decodeKey('j', null, null));
    try std.testing.expectEqual(Key.quit, decodeKey(3, null, null));
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
}

test "small terminal renders actionable fallback" {
    var data = store.Data.init(std.testing.allocator);
    defer data.deinit();
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try render(&writer, &data, .{}, 40, 10);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "terminal too small") != null);
}

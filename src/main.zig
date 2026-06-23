const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("Usage: ztodo <command>\n", .{});
        return;
    }

    const command = args[1];

    std.debug.print("command: {s}\n", .{command});
}

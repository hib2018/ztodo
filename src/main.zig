const std = @import("std");
const ztodo = @import("ztodo");

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        printError(init.io, "could not read command-line arguments.");
        return 1;
    };

    return ztodo.cli.run(init.gpa, init.io, init.environ_map, args);
}

fn printError(io: std.Io, message: []const u8) void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    writer.interface.print("Error: {s}\n", .{message}) catch {};
    writer.interface.flush() catch {};
}

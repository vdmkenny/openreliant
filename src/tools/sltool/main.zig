//! sltool: command-line front end to the `openreliant` format library.

const std = @import("std");
const Io = std.Io;

const cd = @import("cd.zig");
const dte = @import("dte.zig");
const fat = @import("fat.zig");
const fnt = @import("fnt.zig");
const hog = @import("hog.zig");
const render = @import("render.zig");
const shp = @import("shp.zig");
const spr = @import("spr.zig");
const stats = @import("stats.zig");
const tcache = @import("tcache.zig");

/// What every subcommand needs to do its work.
pub const Context = struct {
    io: Io,
    arena: std.mem.Allocator,
    stdout: *Io.Writer,
};

const Command = union(enum) {
    cd: cd.Command,
    dte: dte.Command,
    fat: fat.Command,
    fnt: fnt.Command,
    hog: hog.Command,
    render: render.Command,
    shp: shp.Command,
    spr: spr.Command,
    stats: stats.Command,
    tcache: tcache.Command,
    help,

    const usage =
        \\usage: sltool <command> ...
        \\
        \\commands:
        \\
    ++ cd.Command.usage ++ dte.Command.usage ++ fat.Command.usage ++ fnt.Command.usage ++ hog.Command.usage ++ render.Command.usage ++ shp.Command.usage ++ spr.Command.usage ++ stats.Command.usage ++ tcache.Command.usage ++
        \\  help                            show this text
        \\
    ;

    fn parse(args: []const [:0]const u8) error{Usage}!Command {
        if (args.len == 0) return error.Usage;
        const group = std.meta.stringToEnum(std.meta.Tag(Command), args[0]) orelse return error.Usage;
        return switch (group) {
            .cd => .{ .cd = try .parse(args[1..]) },
            .dte => .{ .dte = try .parse(args[1..]) },
            .fat => .{ .fat = try .parse(args[1..]) },
            .fnt => .{ .fnt = try .parse(args[1..]) },
            .hog => .{ .hog = try .parse(args[1..]) },
            .render => .{ .render = try .parse(args[1..]) },
            .shp => .{ .shp = try .parse(args[1..]) },
            .spr => .{ .spr = try .parse(args[1..]) },
            .stats => .{ .stats = try .parse(args[1..]) },
            .tcache => .{ .tcache = try .parse(args[1..]) },
            .help => .help,
        };
    }

    fn run(command: Command, ctx: Context) !void {
        switch (command) {
            .cd => |group| try group.run(ctx),
            .dte => |group| try group.run(ctx),
            .fat => |group| try group.run(ctx),
            .fnt => |group| try group.run(ctx),
            .hog => |group| try group.run(ctx),
            .render => |group| try group.run(ctx),
            .shp => |group| try group.run(ctx),
            .spr => |group| try group.run(ctx),
            .stats => |group| try group.run(ctx),
            .tcache => |group| try group.run(ctx),
            .help => try ctx.stdout.writeAll(usage),
        }
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    // Streaming, not positional: stdout may be a file that other processes also append to.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);

    const command = Command.parse(args[1..]) catch {
        std.debug.print("{s}", .{Command.usage});
        return 2;
    };
    run(command, init, arena, &stdout) catch |err| switch (err) {
        // The reader went away, as `sltool ... | head` does: stop quietly, not with a trace.
        error.WriteFailed => {
            const cause = stdout.err orelse return err;
            return if (cause == error.BrokenPipe) 0 else err;
        },
        else => return err,
    };
    return 0;
}

fn run(command: Command, init: std.process.Init, arena: std.mem.Allocator, stdout: *Io.File.Writer) !void {
    try command.run(.{ .io = init.io, .arena = arena, .stdout = &stdout.interface });
    try stdout.interface.flush();
}

test Command {
    try std.testing.expectEqual(Command.help, try Command.parse(&.{"help"}));
    try std.testing.expectError(error.Usage, Command.parse(&.{}));
    try std.testing.expectError(error.Usage, Command.parse(&.{"bogus"}));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "cd", "extract", "disc.bin" }));

    const extract = try Command.parse(&.{ "cd", "extract", "disc.bin", "out" });
    try std.testing.expectEqualStrings("disc.bin", extract.cd.extract.image);
    try std.testing.expectEqualStrings("out", extract.cd.extract.out_dir);
}

test {
    std.testing.refAllDecls(@This());
}

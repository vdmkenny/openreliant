//! `sltool cd ...`: look inside a game disc image (`.bin` or `.iso`) without mounting it.

const std = @import("std");
const Io = std.Io;

const starlancer = @import("starlancer");
const cdimage = starlancer.cdimage;
const iso9660 = starlancer.iso9660;

const Context = @import("main.zig").Context;

pub const Command = union(enum) {
    info: struct { image: []const u8 },
    ls: struct { image: []const u8 },
    extract: struct { image: []const u8, out_dir: []const u8 },

    pub const usage =
        \\  cd info <image>                 describe a disc image
        \\  cd ls <image>                   list the files on a disc image
        \\  cd extract <image> <out-dir>    copy every file off a disc image
        \\
    ;

    pub fn parse(args: []const [:0]const u8) error{Usage}!Command {
        if (args.len == 0) return error.Usage;
        const verb = std.meta.stringToEnum(std.meta.Tag(Command), args[0]) orelse return error.Usage;
        const operands = args[1..];
        return switch (verb) {
            .info => if (operands.len == 1) .{ .info = .{ .image = operands[0] } } else error.Usage,
            .ls => if (operands.len == 1) .{ .ls = .{ .image = operands[0] } } else error.Usage,
            .extract => if (operands.len == 2)
                .{ .extract = .{ .image = operands[0], .out_dir = operands[1] } }
            else
                error.Usage,
        };
    }

    pub fn run(command: Command, ctx: Context) !void {
        const image_path = switch (command) {
            inline else => |operands| operands.image,
        };
        const image: cdimage.Image = try .open(ctx.io, .cwd(), image_path);
        defer image.close();
        const volume: iso9660.Volume = try .open(image);

        switch (command) {
            .info => try info(ctx, &volume),
            .ls => try list(ctx, &volume),
            .extract => |operands| try extract(ctx, &volume, operands.out_dir),
        }
    }
};

fn info(ctx: Context, volume: *const iso9660.Volume) !void {
    const image = volume.image;
    try ctx.stdout.print(
        \\layout:     {t} ({d} byte sectors)
        \\blocks:     {d} ({Bi:.1})
        \\volume:     {s}
        \\namespace:  {t}
        \\
    , .{
        image.layout,                image.layout.sectorSize(),
        image.block_count,           @as(u64, image.block_count) * cdimage.block_size,
        try volume.label(ctx.arena), volume.namespace,
    });
}

fn list(ctx: Context, volume: *const iso9660.Volume) !void {
    var walker = try volume.walk(ctx.arena);
    while (try walker.next()) |item| switch (item.entry.kind) {
        .directory => try ctx.stdout.print("{s:>10}  {f}  {s}/\n", .{ "", item.entry.recorded_at, item.path }),
        .file => try ctx.stdout.print("{d:>10}  {f}  {s}\n", .{ item.entry.extent.len, item.entry.recorded_at, item.path }),
    };
}

fn extract(ctx: Context, volume: *const iso9660.Volume, out_path: []const u8) !void {
    const io = ctx.io;
    try Io.Dir.cwd().createDirPath(io, out_path);
    var out_dir = try Io.Dir.cwd().openDir(io, out_path, .{});
    defer out_dir.close(io);

    var files: usize = 0;
    var bytes: u64 = 0;
    var walker = try volume.walk(ctx.arena);
    while (try walker.next()) |item| switch (item.entry.kind) {
        .directory => try out_dir.createDirPath(io, item.path),
        .file => {
            const file = try out_dir.createFile(io, item.path, .{});
            defer file.close(io);
            var buffer: [64 * 1024]u8 = undefined;
            var writer = file.writer(io, &buffer);
            try volume.image.streamExtent(item.entry.extent.lba, item.entry.extent.len, &writer.interface);
            try writer.interface.flush();
            files += 1;
            bytes += item.entry.extent.len;
        },
    };
    try ctx.stdout.print("extracted {d} files ({Bi:.1}) to {s}\n", .{ files, bytes, out_path });
}

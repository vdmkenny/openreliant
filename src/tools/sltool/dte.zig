//! `sltool dte ...`: read `.DTE` mission files.

const std = @import("std");
const Io = std.Io;

const starlancer = @import("starlancer");
const dte = starlancer.dte;

const Context = @import("main.zig").Context;

pub const Command = union(enum) {
    info: struct { mission: []const u8 },
    /// The 27-entry directory.
    sections: struct { mission: []const u8 },
    ships: struct { mission: []const u8 },
    triggers: struct { mission: []const u8 },
    strings: struct { mission: []const u8 },
    /// Lists the script's named routines.
    parts: struct { mission: []const u8 },
    /// Disassembles the script bytecode.
    script: struct { mission: []const u8 },

    pub const usage =
        \\  dte info <mission>              summarise a mission
        \\  dte sections <mission>          list the 27-section directory
        \\  dte ships <mission>             list the placed ships and nav points
        \\  dte triggers <mission>          list the scripted triggers
        \\  dte strings <mission>           dump the string pool
        \\  dte parts <mission>             list the script's named routines
        \\  dte script <mission>            disassemble the script bytecode
        \\
    ;

    pub fn parse(args: []const [:0]const u8) error{Usage}!Command {
        if (args.len != 2) return error.Usage;
        const verb = std.meta.stringToEnum(std.meta.Tag(Command), args[0]) orelse return error.Usage;
        return switch (verb) {
            .info => .{ .info = .{ .mission = args[1] } },
            .sections => .{ .sections = .{ .mission = args[1] } },
            .ships => .{ .ships = .{ .mission = args[1] } },
            .triggers => .{ .triggers = .{ .mission = args[1] } },
            .strings => .{ .strings = .{ .mission = args[1] } },
            .parts => .{ .parts = .{ .mission = args[1] } },
            .script => .{ .script = .{ .mission = args[1] } },
        };
    }

    pub fn run(command: Command, ctx: Context) !void {
        const path = switch (command) {
            inline else => |operands| operands.mission,
        };
        const image = try Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(16 << 20));
        const mission: dte.Mission = try .parse(image);

        switch (command) {
            .info => try info(ctx, mission),
            .sections => try sections(ctx, mission),
            .ships => try ships(ctx, mission),
            .triggers => try triggers(ctx, mission),
            .strings => try strings(ctx, mission),
            .parts => try parts(ctx, mission),
            .script => try script(ctx, mission),
        }
    }
};

fn info(ctx: Context, mission: dte.Mission) !void {
    const ship_list = try mission.ships();
    var named: usize = 0;
    var player: ?[]const u8 = null;
    for (ship_list) |ship| {
        if (mission.name(ship.name).len > 0) named += 1;
        if (ship.iff == 255 and player == null) player = mission.name(ship.name);
    }

    try ctx.stdout.print(
        \\image:     {Bi:.1}
        \\ships:     {d} ({d} named)
        \\triggers:  {d}
        \\globals:   {d}
        \\strings:   {d} in a {d}-byte pool
        \\script:    {d} bytes
        \\
    , .{
        mission.image.len,
        ship_list.len,
        named,
        (try mission.triggers()).len,
        (try mission.globals()).len,
        mission.entry(.strings).count,
        mission.stringPoolEnd() -| mission.entry(.strings).offset,
        mission.entry(.script).count,
    });
    if (player) |name| try ctx.stdout.print("player:    {s}\n", .{name});
}

fn sections(ctx: Context, mission: dte.Mission) !void {
    try ctx.stdout.writeAll("  #  count  flags    offset  section\n");
    for (mission.directory, 0..) |entry, i| {
        const section: dte.Section = @enumFromInt(i);
        if (!entry.isUsed()) {
            try ctx.stdout.print("{d:>3}  {s:>5}  {s:>5}  {s:>8}  ", .{ i, "-", "-", "unused" });
        } else {
            try ctx.stdout.print("{d:>3}  {d:>5}   0x{x:0>2}  {x:0>8}  ", .{
                i, entry.count, entry.relocation_flags, entry.offset,
            });
        }
        try dte.formatTag(dte.Section, section, ctx.stdout);
        try ctx.stdout.writeByte('\n');
    }
}

fn ships(ctx: Context, mission: dte.Mission) !void {
    try ctx.stdout.writeAll("  fg  iff  kind  name                            position                          yaw pitch roll\n");
    for (try mission.ships()) |ship| {
        try ctx.stdout.print("{d:>4} {d:>4} {d:>5}  {s:<30}  ({d:>12.0},{d:>9.0},{d:>12.0}) {d:>5}{d:>5}{d:>5}\n", .{
            ship.flight_group,
            ship.iff,
            ship.kind,
            mission.name(ship.name),
            ship.position[0],
            ship.position[1],
            ship.position[2],
            ship.yaw,
            ship.pitch,
            ship.roll,
        });
    }
}

fn triggers(ctx: Context, mission: dte.Mission) !void {
    const ship_list = try mission.ships();
    try ctx.stdout.writeAll("index  subject                         condition                 repeat   action\n");
    for (try mission.triggers(), 0..) |trigger, i| {
        const subject = if (trigger.subject < ship_list.len)
            mission.name(ship_list[trigger.subject].name)
        else
            "";
        // A custom formatter does not pad, so render into a buffer to keep the columns straight.
        var condition: [24]u8 = undefined;
        var repeat: [8]u8 = undefined;
        try ctx.stdout.print("{d:>5}  {s:<30}  {s:<26}  {s:<7}  {d}\n", .{
            i,
            subject,
            std.fmt.bufPrint(&condition, "{f}", .{trigger.condition}) catch "?",
            std.fmt.bufPrint(&repeat, "{f}", .{trigger.repeat}) catch "?",
            trigger.action,
        });
    }
}

/// Decodes the first block of the script section.
///
/// Blocks are entered by address, so only the one at the start of the section can be found without
/// the part table; the rest are reached by `call_part`.
fn parts(ctx: Context, mission: dte.Mission) !void {
    const code = try mission.script();
    const list = try mission.parts();
    try ctx.stdout.print("{d} parts over {d} bytes of script\n\n", .{ list.len, code.len });
    try ctx.stdout.writeAll("  #  offset  bytes  args  block  name\n");

    var decoded: usize = 0;
    var filled: usize = 0;
    for (list, 0..) |part, index| {
        try ctx.stdout.print("{d:>3}  ", .{index});
        if (part.isEmpty()) {
            try ctx.stdout.print("{s:>6}  {s:>5}  {s:>4}  {s:>5}  ", .{ "-", "-", "-", "-" });
        } else {
            filled += 1;
            const listing = try dte.disassemble(ctx.arena, code, part.start());
            const block: usize = if (dte.BlockReader.at(code, part.start())) |r| r.declared else 0;
            if (listing) |found| {
                if (!found.incomplete and found.unreached == 0) decoded += 1;
            }
            try ctx.stdout.print("{d:>6}  {d:>5}  {d:>4}  {d:>5}  ", .{
                part.start(), part.size(), part.arguments, block,
            });
        }
        try ctx.stdout.print("{s}\n", .{mission.name(part.name)});
    }
    try ctx.stdout.print("\n{d} of {d} entry blocks decode cleanly\n", .{ decoded, filled });
}

fn script(ctx: Context, mission: dte.Mission) !void {
    const code = try mission.script();
    const list = try mission.parts();
    try ctx.stdout.print("{d} bytes of script in {d} parts\n", .{ code.len, list.len });

    for (list, 0..) |part, index| {
        if (part.isEmpty()) continue;
        try ctx.stdout.print("\npart {d} at {d}, {d} bytes", .{ index, part.start(), part.size() });
        const name = mission.name(part.name);
        if (name.len != 0) try ctx.stdout.print(": {s}", .{name});
        try ctx.stdout.writeByte('\n');

        const listing = try dte.disassemble(ctx.arena, code, part.start()) orelse {
            try ctx.stdout.writeAll("  no block here\n");
            continue;
        };
        try printListing(ctx, listing);
    }
}

fn printListing(ctx: Context, listing: dte.Disassembly) !void {
    var previous: ?usize = null;
    for (listing.instructions) |instruction| {
        // A hole means the bytes between two reached instructions are not reached themselves.
        if (previous) |end| {
            if (instruction.address > end) {
                try ctx.stdout.print("  {d:>6}  ... {d} bytes not reached\n", .{ end, instruction.address - end });
            }
        }
        previous = instruction.address + instruction.size();

        // Long inline runs are shown as their text, so only the head needs a hex column.
        var bytes: [11]u8 = undefined;
        var at: usize = 0;
        at += (std.fmt.bufPrint(bytes[at..], "{x:0>2}", .{@intFromEnum(instruction.opcode)}) catch break).len;
        for (instruction.operands) |b| {
            at += (std.fmt.bufPrint(bytes[at..], " {x:0>2}", .{b}) catch break).len;
        }
        try ctx.stdout.print("  {d:>6}  {s:<11} ", .{ instruction.address, bytes[0..@min(at, bytes.len)] });
        try dte.formatTag(dte.Opcode, instruction.opcode, ctx.stdout);

        switch (instruction.form) {
            .sequential => {},
            .branch => try ctx.stdout.print("   -> {d}", .{instruction.branchTarget().?}),
            .inline_data => try printInline(ctx, instruction.inlineData().?),
            .transfer => try ctx.stdout.writeAll("   (transfer)"),
        }
        try ctx.stdout.writeByte('\n');
    }
    if (listing.incomplete) try ctx.stdout.writeAll("  a reached byte is not an opcode\n");
}

/// Renders an inline run as text when it is one, and as hex otherwise.
fn printInline(ctx: Context, data: []const u8) !void {
    const text = std.mem.sliceTo(data, 0);
    const printable = text.len + 1 == data.len and
        text.len != 0 and
        for (text) |c| {
            if (!std.ascii.isPrint(c)) break false;
        } else true;

    if (printable) {
        try ctx.stdout.print("   \"{s}\"", .{text});
        return;
    }
    try ctx.stdout.writeAll("  ");
    for (data) |b| try ctx.stdout.print(" {x:0>2}", .{b});
}

fn strings(ctx: Context, mission: dte.Mission) !void {
    const pool = mission.entry(.strings);
    if (!pool.isUsed()) return;
    const end = mission.stringPoolEnd();

    var offset: usize = pool.offset;
    while (offset < end) {
        const rest = mission.image[offset..end];
        const len = std.mem.indexOfScalar(u8, rest, 0) orelse break;
        if (len > 0) {
            try ctx.stdout.print("{d:>6}  {s}\n", .{ offset - pool.offset, rest[0..len] });
        }
        offset += len + 1;
    }
}

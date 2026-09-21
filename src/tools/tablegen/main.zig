//! tablegen: derives the engine's static tables from the game binary.
//!
//!     tablegen opcodes <LANCER.EXE> <disassembly.asm> <output.zig>
//!     tablegen commands <LANCER.EXE> <output.zig>
//!     tablegen conditions <LANCER.EXE> <output.zig>
//!     tablegen models <LANCER.EXE> <disassembly.asm> <output.zig>
//!     tablegen controls <LANCER.EXE> <output.zig>
//!
//! `opcodes`: the VM dispatches on a byte through a table of handler addresses. Reading that table
//! gives the opcode set, and following each handler gives the size and shape of the instruction it
//! decodes. `disassembly.asm` is what `make ghidra-export` writes for the payload executable.
//!
//! `commands`: the Executor catalogue that `0x21 command` indexes, which needs only the binary.
//!
//! `conditions`: the trigger condition catalogue, which also needs only the binary.
//!
//! `models`: the model of each ship type, and the models mounted on attachment points, which the
//! engine loads in code that the listing lets this follow.
//!
//! `controls`: the player's actions and the bindings the game starts with.
//!
//! All come straight out of the binary, so the tables written are transcripts of the engine rather
//! than readings of the mission files.

const std = @import("std");
const Io = std.Io;

const starlancer = @import("starlancer");
const pe = starlancer.pe;

const commands = @import("commands.zig");
const conditions = @import("conditions.zig");
const controls = @import("controls.zig");
const eval = @import("eval.zig");
const image = @import("image.zig");
const models = @import("models.zig");
const x86 = @import("x86.zig");

/// Virtual address of the dispatch table, found from the `CALL dword ptr [...]` that the
/// interpreter's inner loop makes.
const dispatch_table: u32 = 0x004F6350;

/// Entries the table could hold. The real one is shorter; where it ends is worked out below.
const max_opcodes = 256;

const Handler = struct {
    opcode: u8,
    address: u32,
    shape: eval.Shape,
};

const usage =
    \\usage: tablegen opcodes <LANCER.EXE> <disassembly.asm> <output.zig>
    \\       tablegen commands <LANCER.EXE> <output.zig>
    \\       tablegen conditions <LANCER.EXE> <output.zig>
    \\       tablegen models <LANCER.EXE> <disassembly.asm> <output.zig>
    \\       tablegen controls <LANCER.EXE> <output.zig>
    \\
;

const Mode = union(enum) {
    opcodes: struct { binary: []const u8, listing: []const u8, output: []const u8 },
    commands: struct { binary: []const u8, output: []const u8 },
    conditions: struct { binary: []const u8, output: []const u8 },
    models: struct { binary: []const u8, listing: []const u8, output: []const u8 },
    controls: struct { binary: []const u8, output: []const u8 },

    fn parse(args: []const [:0]const u8) ?Mode {
        if (args.len == 0) return null;
        const tag = std.meta.stringToEnum(std.meta.Tag(Mode), args[0]) orelse return null;
        const rest = args[1..];
        return switch (tag) {
            .opcodes => if (rest.len == 3) .{ .opcodes = .{ .binary = rest[0], .listing = rest[1], .output = rest[2] } } else null,
            .commands => if (rest.len == 2) .{ .commands = .{ .binary = rest[0], .output = rest[1] } } else null,
            .conditions => if (rest.len == 2) .{ .conditions = .{ .binary = rest[0], .output = rest[1] } } else null,
            .models => if (rest.len == 3) .{ .models = .{ .binary = rest[0], .listing = rest[1], .output = rest[2] } } else null,
            .controls => if (rest.len == 2) .{ .controls = .{ .binary = rest[0], .output = rest[1] } } else null,
        };
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const mode = Mode.parse(args[1..]) orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    return switch (mode) {
        .opcodes => |paths| opcodes(init, arena, paths.binary, paths.listing, paths.output),
        .commands => |paths| catalogue(init, arena, paths.binary, paths.output),
        .conditions => |paths| conditionCatalogue(init, arena, paths.binary, paths.output),
        .models => |paths| modelTables(init, arena, paths.binary, paths.listing, paths.output),
        .controls => |paths| controlTable(init, arena, paths.binary, paths.output),
    };
}

fn catalogue(init: std.process.Init, arena: std.mem.Allocator, binary_path: []const u8, output: []const u8) !u8 {
    const cwd: Io.Dir = .cwd();
    const binary = try cwd.readFileAlloc(init.io, binary_path, arena, .limited(64 << 20));
    const pe_image: pe.Image = try .parse(binary);
    const all = try commands.read(arena, .init(pe_image, binary));

    var buffer: [16 << 10]u8 = undefined;
    var out: Io.File.Writer = .init(try cwd.createFile(init.io, output, .{}), init.io, &buffer);
    defer out.file.close(init.io);
    try commands.emit(&out.interface, all);
    try out.interface.flush();

    std.debug.print("{d} commands -> {s}\n", .{ all.len, output });
    return 0;
}

fn conditionCatalogue(init: std.process.Init, arena: std.mem.Allocator, binary_path: []const u8, output: []const u8) !u8 {
    const cwd: Io.Dir = .cwd();
    const binary = try cwd.readFileAlloc(init.io, binary_path, arena, .limited(64 << 20));
    const pe_image: pe.Image = try .parse(binary);
    const catalogue_read = try conditions.read(arena, .init(pe_image, binary));

    var buffer: [16 << 10]u8 = undefined;
    var out: Io.File.Writer = .init(try cwd.createFile(init.io, output, .{}), init.io, &buffer);
    defer out.file.close(init.io);
    try conditions.emit(&out.interface, catalogue_read);
    try out.interface.flush();

    std.debug.print("{d} conditions -> {s}\n", .{ catalogue_read.conditions.len, output });
    return 0;
}

fn modelTables(
    init: std.process.Init,
    arena: std.mem.Allocator,
    binary_path: []const u8,
    listing_path: []const u8,
    output: []const u8,
) !u8 {
    const cwd: Io.Dir = .cwd();
    const binary = try cwd.readFileAlloc(init.io, binary_path, arena, .limited(64 << 20));
    const listing = try cwd.readFileAlloc(init.io, listing_path, arena, .limited(256 << 20));
    const pe_image: pe.Image = try .parse(binary);
    const tables = try models.read(arena, .init(pe_image, binary), try x86.parse(arena, listing));

    var buffer: [16 << 10]u8 = undefined;
    var out: Io.File.Writer = .init(try cwd.createFile(init.io, output, .{}), init.io, &buffer);
    defer out.file.close(init.io);
    try models.emit(&out.interface, tables);
    try out.interface.flush();

    std.debug.print("{d} ship types and the attachment models -> {s}\n", .{ tables.ship_types.len, output });
    return 0;
}

fn controlTable(init: std.process.Init, arena: std.mem.Allocator, binary_path: []const u8, output: []const u8) !u8 {
    const cwd: Io.Dir = .cwd();
    const binary = try cwd.readFileAlloc(init.io, binary_path, arena, .limited(64 << 20));
    const pe_image: pe.Image = try .parse(binary);
    const bindings = try controls.read(arena, .init(pe_image, binary));

    var buffer: [16 << 10]u8 = undefined;
    var out: Io.File.Writer = .init(try cwd.createFile(init.io, output, .{}), init.io, &buffer);
    defer out.file.close(init.io);
    try controls.emit(&out.interface, bindings);
    try out.interface.flush();

    std.debug.print("{d} actions -> {s}\n", .{ bindings.len, output });
    return 0;
}

fn opcodes(
    init: std.process.Init,
    arena: std.mem.Allocator,
    binary_path: []const u8,
    listing_path: []const u8,
    output: []const u8,
) !u8 {
    const cwd: Io.Dir = .cwd();
    const binary = try cwd.readFileAlloc(init.io, binary_path, arena, .limited(64 << 20));
    const listing = try cwd.readFileAlloc(init.io, listing_path, arena, .limited(256 << 20));

    const pe_image: pe.Image = try .parse(binary);
    const base = pe_image.optional_header.image_base;
    const text = pe_image.sectionByName(".text") orelse {
        std.debug.print("{s}: no .text section\n", .{binary_path});
        return 1;
    };
    const text_start = base + text.virtual_address;
    const text_end = text_start + text.virtual_size;

    const table_offset = pe_image.fileOffset(dispatch_table - base) orelse {
        std.debug.print("dispatch table at {x} is not in the image\n", .{dispatch_table});
        return 1;
    };

    const functions = try x86.parse(arena, listing);
    var by_address: std.AutoHashMapUnmanaged(u32, x86.Function) = .empty;
    for (functions) |function| try by_address.put(arena, function.address, function);

    // The table runs from its start to the first entry that is neither empty nor a code address.
    // Past that point the data is some other structure, which holds values that happen to look
    // like addresses.
    var handlers: std.ArrayList(Handler) = .empty;
    var length: usize = 0;
    for (0..max_opcodes) |opcode| {
        const entry = std.mem.readInt(u32, binary[table_offset + opcode * 4 ..][0..4], .little);
        if (entry == 0) continue;
        if (entry < text_start or entry >= text_end) break;
        length = opcode + 1;

        const handler = by_address.get(entry) orelse {
            std.debug.print("opcode {x:0>2}: no function at {x:0>8} in the listing\n", .{ opcode, entry });
            return 1;
        };
        const shape = eval.analyze(arena, handler) catch |err| {
            std.debug.print("opcode {x:0>2} ({s}): {t}\n", .{ opcode, handler.name, err });
            return 1;
        };
        try handlers.append(arena, .{ .opcode = @intCast(opcode), .address = entry, .shape = shape });
    }

    var buffer: [16 << 10]u8 = undefined;
    var out: Io.File.Writer = .init(try cwd.createFile(init.io, output, .{}), init.io, &buffer);
    defer out.file.close(init.io);
    try emit(&out.interface, handlers.items, length);
    try out.interface.flush();

    std.debug.print("{d} opcodes over a table of {d} entries -> {s}\n", .{
        handlers.items.len, length, output,
    });
    return 0;
}

fn emit(w: *Io.Writer, handlers: []const Handler, length: usize) !void {
    try w.print(
        \\//! The mission script VM's instruction set.
        \\//!
        \\//! Generated by `src/tools/tablegen` from the payload executable's dispatch table at
        \\//! 0x{[table]X:0>8}, which holds {[length]d} entries. Do not edit by hand; run `make vm-opcodes`.
        \\
        \\
        \\/// What an instruction does to the instruction pointer.
        \\pub const Form = enum {{
        \\    /// Execution continues at the instruction after the operands.
        \\    sequential,
        \\    /// The operand bytes hold a displacement, relative to their own position, to where
        \\    /// execution resumes. The instruction itself still ends after them.
        \\    branch,
        \\    /// The one operand byte is a total length, covering itself: `length - 1` bytes of
        \\    /// inline data follow it, and execution resumes after them.
        \\    inline_data,
        \\    /// Control passes somewhere a linear decoder cannot follow.
        \\    transfer,
        \\}};
        \\
        \\pub const Info = struct {{
        \\    opcode: u8,
        \\    /// Operand bytes between the opcode and the next instruction. For `inline_data` this
        \\    /// counts only the length byte.
        \\    operands: u8,
        \\    form: Form,
        \\    /// Whether execution can continue at the instruction after the operands. Where it
        \\    /// cannot, the bytes that follow are reached only by a branch, so a linear sweep
        \\    /// would decode whatever happens to sit there.
        \\    falls_through: bool,
        \\    /// Address of the handler in the payload executable.
        \\    handler: u32,
        \\}};
        \\
        \\/// Every opcode the VM implements, in order.
        \\pub const table = [_]Info{{
        \\
    , .{ .table = dispatch_table, .length = length });

    for (handlers) |handler| {
        try w.print(
            "    .{{ .opcode = 0x{X:0>2}, .operands = {d}, .form = .{t}, .falls_through = {}, .handler = 0x{X:0>8} }},\n",
            .{
                handler.opcode,              handler.shape.operands, handler.shape.form,
                handler.shape.falls_through, handler.address,
            },
        );
    }

    try w.writeAll(
        \\};
        \\
        \\/// Looks up `opcode`, or null when the VM has no handler for it.
        \\pub fn find(opcode: u8) ?Info {
        \\    // The table is sorted, and short enough that a scan beats anything cleverer.
        \\    for (table) |info| {
        \\        if (info.opcode == opcode) return info;
        \\        if (info.opcode > opcode) break;
        \\    }
        \\    return null;
        \\}
        \\
        \\test find {
        \\    const std = @import("std");
        \\    try std.testing.expect(find(table[0].opcode) != null);
        \\    try std.testing.expect(find(0x00) == null);
        \\    for (table[1..], table[0 .. table.len - 1]) |next, previous| {
        \\        try std.testing.expect(next.opcode > previous.opcode);
        \\    }
        \\}
        \\
    );
}

test Mode {
    const both = Mode.parse(&.{ "commands", "LANCER.EXE", "out.zig" }).?;
    try std.testing.expectEqualStrings("out.zig", both.commands.output);
    try std.testing.expectEqual(@as(?Mode, null), Mode.parse(&.{ "opcodes", "LANCER.EXE" }));
    try std.testing.expectEqual(@as(?Mode, null), Mode.parse(&.{"bogus"}));

    const models_mode = Mode.parse(&.{ "models", "LANCER.EXE", "disassembly.asm", "out.zig" }).?;
    try std.testing.expectEqualStrings("disassembly.asm", models_mode.models.listing);
    const controls_mode = Mode.parse(&.{ "controls", "LANCER.EXE", "out.zig" }).?;
    try std.testing.expectEqualStrings("LANCER.EXE", controls_mode.controls.binary);
    try std.testing.expectEqual(@as(?Mode, null), Mode.parse(&.{ "controls", "LANCER.EXE" }));
}

test {
    std.testing.refAllDecls(@This());
    _ = commands;
    _ = conditions;
    _ = controls;
    _ = eval;
    _ = image;
    _ = models;
    _ = x86;
}

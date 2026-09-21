//! Reads the engine's model tables out of the payload: a model and a comms sprite for each ship
//! type, and the models it mounts on attachment points, by kind and id.
//!
//! The ship type table is data in the image. The attachment table is filled when the game starts,
//! by `0x0045DE70`, which loads each file with `MOV ECX, name` and a `CALL`, then stores what the
//! call returns; this reader follows those instructions in Ghidra's exported listing.

const std = @import("std");
const Io = std.Io;

const starlancer = @import("starlancer");
const Kind = starlancer.shp.Attachment.Kind;

const image = @import("image.zig");
const x86 = @import("x86.zig");

/// The ship type table: a record of `ship_type_size` bytes for each of the 256 types, with the
/// model file's name at `+0` and the comms sprite's at `+4`.
pub const ship_types: u32 = 0x004F7490;
pub const ship_type_size = 0x14;
pub const ship_type_count = 256;

/// The function that fills `attachment_table`.
pub const attachment_loader: u32 = 0x0045DE70;
pub const attachment_table: u32 = 0x00538CA8;
pub const attachment_size = 0x10;
pub const ids_per_kind = 20;
pub const attachment_kinds = 9;

const load_model: u32 = 0x004A44D0;
const load_sprite: u32 = 0x00494A30;

/// Offsets within an attachment entry.
const field = struct {
    const model = 0x0;
    const second_model = 0x4;
    const count = 0x8;
    const sprite = 0xC;
};

pub const ShipType = struct {
    model: ?[]const u8,
    schematic: ?[]const u8,
};

pub const Attachment = struct {
    model: ?[]const u8 = null,
    second_model: ?[]const u8 = null,
    count: u32 = 1,
    sprite: ?[]const u8 = null,
};

pub const Tables = struct {
    ship_types: []const ShipType,
    attachments: [attachment_kinds][ids_per_kind]Attachment,
};

pub const Error = image.Error || error{ NoLoader, UnexpectedStore };

pub fn read(
    arena: std.mem.Allocator,
    reader: image.Reader,
    functions: []const x86.Function,
) (Error || std.mem.Allocator.Error)!Tables {
    const types = try arena.alloc(ShipType, ship_type_count);
    for (types, 0..) |*ship_type, index| {
        const at = ship_types + @as(u32, @intCast(index)) * ship_type_size;
        ship_type.* = .{
            .model = try optionalString(reader, try reader.word(at)),
            .schematic = try optionalString(reader, try reader.word(at + 4)),
        };
    }

    const loader = for (functions) |function| {
        if (function.address == attachment_loader) break function;
    } else return error.NoLoader;

    var tables: Tables = .{ .ship_types = types, .attachments = @splat(@splat(.{})) };
    var ecx: ?u32 = null;
    const Loaded = struct { name: u32, sprite: bool };
    var loaded: ?Loaded = null;
    for (loader.instructions) |instruction| switch (instruction.mnemonic) {
        .call => {
            const target = instruction.target orelse continue;
            if (target != load_model and target != load_sprite) continue;
            loaded = .{ .name = ecx orelse return error.UnexpectedStore, .sprite = target == load_sprite };
            ecx = null;
        },
        .mov => {
            const destination = instruction.destination orelse continue;
            const source = instruction.source orelse continue;
            switch (destination) {
                .register => |register| if (register == .ecx) {
                    ecx = switch (source) {
                        .immediate => |value| std.math.cast(u32, value),
                        else => null,
                    };
                },
                .memory => |address| {
                    if (address.base != null or address.index != null) continue;
                    const slot = std.math.cast(u32, address.displacement) orelse continue;
                    const end = attachment_table + attachment_kinds * ids_per_kind * attachment_size;
                    if (slot < attachment_table or slot >= end) continue;
                    const offset = slot - attachment_table;
                    const index = offset / attachment_size;
                    const entry = &tables.attachments[index / ids_per_kind][index % ids_per_kind];
                    switch (source) {
                        .register => |register| {
                            if (register != .eax) return error.UnexpectedStore;
                            const file = loaded orelse return error.UnexpectedStore;
                            loaded = null;
                            const name = try reader.string(file.name);
                            switch (offset % attachment_size) {
                                field.model => if (!file.sprite) {
                                    entry.model = name;
                                } else return error.UnexpectedStore,
                                field.second_model => if (!file.sprite) {
                                    entry.second_model = name;
                                } else return error.UnexpectedStore,
                                field.sprite => if (file.sprite) {
                                    entry.sprite = name;
                                } else return error.UnexpectedStore,
                                else => return error.UnexpectedStore,
                            }
                        },
                        .immediate => |value| {
                            if (offset % attachment_size != field.count) return error.UnexpectedStore;
                            entry.count = std.math.cast(u32, value) orelse return error.UnexpectedStore;
                        },
                        else => return error.UnexpectedStore,
                    }
                },
                else => {},
            }
        },
        else => {},
    };
    return tables;
}

/// A file name, or null for a null pointer or an empty name, neither of which names a file.
fn optionalString(reader: image.Reader, va: u32) image.Error!?[]const u8 {
    if (va == 0) return null;
    const name = try reader.string(va);
    return if (name.len == 0) null else name;
}

/// Writes `models.zig`.
pub fn emit(w: *Io.Writer, tables: Tables) !void {
    try w.print(
        \\//! The models the engine loads by number: one for each ship type, and those it mounts on
        \\//! attachment points, by kind and id.
        \\//!
        \\//! Generated by `src/tools/tablegen` from the payload executable: the ship type table at
        \\//! 0x{X:0>8}, and the loader at 0x{X:0>8} that fills the attachment table at 0x{X:0>8}. The
        \\//! file names are the engine's own. Do not edit by hand; run `make model-tables`.
        \\
        \\const Kind = @import("shp.zig").Attachment.Kind;
        \\
        \\/// A ship type's model, and the sprite of it the comms screen shows. Types are numbered like
        \\/// the records of `shipstats.bin`.
        \\pub const ShipType = struct {{
        \\    model: ?[]const u8,
        \\    schematic: ?[]const u8,
        \\}};
        \\
        \\/// What the engine loads for attachment points of one kind and id.
        \\pub const Attachment = struct {{
        \\    model: ?[]const u8 = null,
        \\    /// A second model loaded with the first: the missile, for a missile pod.
        \\    second_model: ?[]const u8 = null,
        \\    /// **Unknown.** 1 unless the loader sets it.
        \\    count: u32 = 1,
        \\    sprite: ?[]const u8 = null,
        \\}};
        \\
        \\pub const ids_per_kind = {d};
        \\
        \\pub const ship_types = [_]ShipType{{
        \\
    , .{ ship_types, attachment_loader, attachment_table, ids_per_kind });

    for (tables.ship_types, 0..) |ship_type, index| {
        try w.print("    // 0x{X:0>2}\n    .{{ .model = ", .{index});
        try optional(w, ship_type.model);
        try w.writeAll(", .schematic = ");
        try optional(w, ship_type.schematic);
        try w.writeAll(" },\n");
    }

    try w.print(
        \\}};
        \\
        \\/// Indexed by kind, then id.
        \\pub const attachments = [{d}][ids_per_kind]Attachment{{
        \\
    , .{attachment_kinds});
    for (tables.attachments, 0..) |kind, kind_index| {
        const name = std.enums.tagName(Kind, @enumFromInt(kind_index)) orelse "unknown";
        try w.print("    // Kind {d}: {s}\n    .{{\n", .{ kind_index, name });
        for (kind) |entry| {
            if (entry.model == null and entry.second_model == null and entry.sprite == null and entry.count == 1) {
                try w.writeAll("        .{},\n");
                continue;
            }
            try w.writeAll("        .{");
            var first = true;
            inline for (.{ "model", "second_model", "sprite" }) |name_field| {
                if (@field(entry, name_field)) |text| {
                    try w.print("{s} .{s} = \"{f}\"", .{ if (first) "" else ",", name_field, std.zig.fmtString(text) });
                    first = false;
                }
            }
            if (entry.count != 1) try w.print("{s} .count = {d}", .{ if (first) "" else ",", entry.count });
            try w.writeAll(" },\n");
        }
        try w.writeAll("    },\n");
    }

    try w.writeAll(
        \\};
        \\
        \\/// The ship type numbered `index`, or null past the table.
        \\pub fn shipType(index: usize) ?ShipType {
        \\    return if (index < ship_types.len) ship_types[index] else null;
        \\}
        \\
        \\/// What the engine loads for an attachment point, or null when it loads nothing for it.
        \\pub fn attachment(kind: Kind, id: u32) ?Attachment {
        \\    const index = @intFromEnum(kind);
        \\    if (index >= attachments.len or id >= ids_per_kind) return null;
        \\    const entry = attachments[index][id];
        \\    if (entry.model == null and entry.sprite == null) return null;
        \\    return entry;
        \\}
        \\
        \\test attachment {
        \\    const std = @import("std");
        \\    try std.testing.expect(attachment(.gun, 0) != null);
        \\    try std.testing.expect(attachment(.gun, ids_per_kind) == null);
        \\    try std.testing.expect(shipType(0).?.model != null);
        \\}
        \\
    );
}

fn optional(w: *Io.Writer, text: ?[]const u8) !void {
    if (text) |value| {
        try w.print("\"{f}\"", .{std.zig.fmtString(value)});
    } else {
        try w.writeAll("null");
    }
}

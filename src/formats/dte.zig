//! `.DTE` missions: the 44 campaign and multiplayer missions, and everything scripted in them.
//!
//! A mission is a fixed-capacity image. A 27-entry directory at offset zero gives each section a
//! count and an offset, and the offsets are the same in every mission built from the same
//! template, so a section is a reservation that a mission fills as far as it needs.
//!
//! Inside a `.HOG` the image is RefPack compressed; a mission sitting loose in `missions\` is
//! stored expanded. `hog.Archive.read` handles the first case, so this module always sees the
//! expanded form.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const section_count = 27;

/// Writes an enum's tag name, or its number when the file carries a value this enum does not name.
///
/// The branch per named tag is generated at compile time and the open `_` case is handled
/// explicitly, so there is no runtime lookup that can fail. Formatting with `{t}` would instead
/// panic on any value the format uses but the enum omits, which is a category of data this project
/// meets constantly.
pub fn formatTag(comptime T: type, value: T, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    return switch (value) {
        _ => writer.print("{d}", .{@intFromEnum(value)}),
        inline else => |tag| writer.writeAll(@tagName(tag)),
    };
}

/// What each directory slot holds. Sections the loader reads but this module does not interpret
/// keep their index as a name.
pub const Section = enum(u8) {
    /// NUL-terminated names, addressed by byte offset rather than by index.
    strings = 0,
    operands_a = 1,
    /// `u16` name offset and a `u32` value, read and written by script.
    globals = 2,
    /// The flight groups: every ship, station and nav point the mission places.
    ships = 3,
    objectives = 4,
    triggers = 5,
    /// Where the script bytecode starts; the VM's instruction pointer is an offset into it.
    script = 6,
    /// Per-ship index into the trigger list.
    ship_triggers = 7,
    objects = 8,
    unknown_9 = 9,
    /// One flag per bytecode byte, marking where the VM may yield.
    script_flags = 10,
    targets = 11,
    conditions = 12,
    squads = 13,
    unknown_14 = 14,
    nav_geometry = 15,
    sub_objects = 16,
    unused_17 = 17,
    unused_18 = 18,
    unused_19 = 19,
    unused_20 = 20,
    transient_21 = 21,
    operands_b = 22,
    unknown_23 = 23,
    unknown_24 = 24,
    unknown_25 = 25,
    unknown_26 = 26,
    _,
};

pub const DirectoryEntry = extern struct {
    /// Records in use, not the capacity reserved for them.
    count: u16,
    _unused: u8,
    /// Which of the section's fields the loader turns into live pointers.
    relocation_flags: u8,
    offset: u32,

    /// Sections the template reserves but this mission does not use.
    pub const unused_offset: u32 = 0xFFFF;

    pub fn isUsed(entry: DirectoryEntry) bool {
        return entry.offset != unused_offset;
    }

    comptime {
        assert(@sizeOf(DirectoryEntry) == 8);
    }
};

/// One placed object: a ship, a capital ship, a station or a nav point.
pub const Ship = extern struct {
    flight_group: u32,
    /// Byte offset into the string pool.
    name: u16,
    _unknown_06: u16,
    /// Mirrored from `position` when the mission loads.
    runtime_position: [3]f32,
    _unknown_14: u8,
    /// Side. 255 marks the player's own record.
    iff: u8,
    _unknown_16: u8,
    flags: Flags,
    /// Role. Ordinary ships stay below `0x100`; nav points and markers use 999 and the `0x3E3` to
    /// `0x3E8` range, so reading this as a byte truncates about two records in five.
    kind: u16,
    _unknown_1a: u16,
    /// As authored. The loader copies it into `runtime_position`.
    position: [3]f32,
    _unknown_28: u32,
    runtime_yaw: i16,
    /// Whole degrees. The engine scales it by pi/180, which is what proves the unit.
    yaw: i16,
    /// Live object handle, `0xFFFFFFFF` until the mission arms.
    handle: u32,
    _unknown_34: u32,
    runtime_pitch: i16,
    pitch: i16,
    _unknown_3c: [12]u8,
    runtime_roll: i16,
    roll: i16,

    pub const Flags = packed struct(u8) {
        disabled: bool,
        _unknown: u7,
    };

    comptime {
        assert(@offsetOf(Ship, "name") == 0x04);
        assert(@offsetOf(Ship, "iff") == 0x15);
        assert(@offsetOf(Ship, "kind") == 0x18);
        assert(@offsetOf(Ship, "position") == 0x1C);
        assert(@offsetOf(Ship, "yaw") == 0x2E);
        assert(@offsetOf(Ship, "pitch") == 0x3A);
        assert(@offsetOf(Ship, "roll") == 0x4A);
        assert(@sizeOf(Ship) == 0x4C);
    }
};

/// A named value the script reads and writes.
pub const Global = extern struct {
    name: u16,
    _unknown_02: u16,
    value: u32,
    _unknown_08: u32,

    comptime {
        assert(@sizeOf(Global) == 0x0C);
    }
};

pub const Objective = extern struct {
    data: [0x14]u8,

    comptime {
        assert(@sizeOf(Objective) == 0x14);
    }
};

/// Fires an action when its condition holds for its subject.
pub const Trigger = extern struct {
    /// Ship or flight group the condition watches.
    subject: u8,
    repeat: Repeat,
    /// Linked action or script index; `0xFFFF` for none.
    link: u16,
    _unknown_04: [16]u8,
    /// Armed to 1 when the mission starts.
    enabled: u8,
    condition: Condition,
    /// Spawns the script thread that runs when the condition holds.
    action: u8,
    /// Byte arrays rather than wider types: these sit at odd offsets, and an `extern struct` would
    /// pad a `u16` here into the wrong place.
    _unknown_17: [2]u8,
    repeat_counter: u8,
    _unknown_1a: [2]u8,
    /// Condition arguments, four bytes each.
    operands: [5]u32,

    pub const Repeat = enum(u8) {
        /// Clears `enabled` when it fires.
        once = 0,
        /// Fires up to `repeat_counter` times.
        counted = 2,
        _,

        pub fn format(repeat: Repeat, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return formatTag(Repeat, repeat, writer);
        }
    };

    comptime {
        assert(@offsetOf(Trigger, "enabled") == 0x14);
        assert(@offsetOf(Trigger, "condition") == 0x15);
        assert(@offsetOf(Trigger, "action") == 0x16);
        assert(@offsetOf(Trigger, "operands") == 0x1C);
        assert(@sizeOf(Trigger) == 0x30);
    }
};

/// The 33 conditions a mission may script, in the order the engine's own name table lists them.
pub const Condition = enum(u8) {
    shot_at = 0x00,
    destroyed = 0x01,
    launched = 0x02,
    camera_reached = 0x03,
    ship_reached = 0x04,
    proximity_close = 0x05,
    proximity_general = 0x06,
    object_scooped = 0x07,
    player_ready_to_jump = 0x08,
    jumped_in = 0x09,
    flight_group_jumped_in = 0x0A,
    player_ready_to_warp = 0x0B,
    jumped_through_hoop = 0x0C,
    player_wants_backup = 0x0D,
    ripper_grabbed_object = 0x0E,
    ripper_dropped_object = 0x0F,
    cloaked = 0x10,
    decloaked = 0x11,
    targetted = 0x12,
    player_l1_doubletap = 0x13,
    player_l2_doubletap = 0x14,
    player_r1_doubletap = 0x15,
    player_r2_doubletap = 0x16,
    player_l1_l2_r1_r2_pressed = 0x17,
    player_l1_r1_pressed = 0x18,
    game_timer_expired = 0x19,
    tractor_beam_locked = 0x1A,
    tractor_beam_broken = 0x1B,
    inside_object = 0x1C,
    outside_object = 0x1D,
    docked = 0x1E,
    undocked = 0x1F,
    being_chased = 0x20,
    /// No condition. Most trigger slots carry this: see `docs/formats/dte.md`.
    none = 0xFF,
    _,

    /// Conditions above this are internal to the engine and cannot be scripted.
    pub const last_scriptable: Condition = .being_chased;

    pub fn format(condition: Condition, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return formatTag(Condition, condition, writer);
    }
};

/// Script bytecode.
///
/// The interpreter is a plain dispatch loop: fetch one byte, index a 256-entry handler table,
/// advance the instruction pointer by one, call the handler, and repeat until a handler returns
/// zero. A parallel flag array, section `script_flags`, is indexed by the same instruction pointer
/// and marks where the VM may suspend across frames.
///
/// The handler table is stored in the payload with **`0x02` to `0x07` and `0x14` to `0x55`
/// filled**; every other entry is null, so only those 72 opcodes exist.
pub const Opcode = enum(u8) {
    /// Compare not-equal.
    compare_ne = 0x02,
    /// Compare equal.
    compare_eq = 0x03,
    /// Squad or condition membership test.
    membership = 0x14,
    /// Call Executor command `n` from the catalogue the engine installs at load.
    command = 0x21,
    push_immediate_a = 0x23,
    push_immediate_b = 0x24,
    /// Read the value of global `n`.
    read_global = 0x27,
    /// Wait, or fetch an operand in a compare.
    wait = 0x28,
    /// Play speech `n`.
    speech = 0x2A,
    /// Reference a single object.
    object = 0x2C,
    /// Reference a flight group.
    flight_group = 0x2D,
    /// Set AI behaviour `n` on the current entity.
    ai = 0x32,
    /// Push the address of array slot `n`.
    array_slot = 0x3F,
    /// Push the address of global `n`, as somewhere to write.
    write_global = 0x40,
    /// Calls the script part named by its operand, through a table of parts.
    call_part = 0x22,
    /// Jumps by a **big-endian** 16-bit displacement, the one place the format is not
    /// little-endian.
    jump = 0x42,
    /// End of a block.
    end = 0x43,
    /// Branch into part `n`.
    jump_part = 0x4D,
    _,

    /// Opcodes the payload's handler table implements.
    pub fn isImplemented(opcode: Opcode) bool {
        const value = @intFromEnum(opcode);
        return (value >= 0x02 and value <= 0x07) or (value >= 0x14 and value <= 0x55);
    }

    pub fn format(opcode: Opcode, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return formatTag(Opcode, opcode, writer);
    }
};

/// What an opcode does to the instruction pointer.
pub const OpcodeInfo = struct {
    opcode: u8,
    /// Operand bytes that follow the opcode.
    operands: u8,
    /// Whether the handler redirects the instruction pointer rather than stepping past its
    /// operands: a call, a jump, or the end of a block.
    control: bool,
};

/// Every opcode the VM implements, with how far its handler moves the instruction pointer.
///
/// Derived from the handlers themselves rather than from patterns in the mission data: the
/// payload's handler table is read, `ghidra/scripts/DefineVmHandlers.java` defines a function at
/// each entry so the decompiler can reach them, and each handler's first action on the pointer
/// gives its width. A handler that steps past operands reports that count; one that assigns the
/// pointer from elsewhere is a call or jump, and its width is however many bytes it read first.
pub const opcodes = [_]OpcodeInfo{
    .{ .opcode = 0x02, .operands = 0, .control = false },
    .{ .opcode = 0x03, .operands = 0, .control = false },
    .{ .opcode = 0x04, .operands = 0, .control = false },
    .{ .opcode = 0x05, .operands = 0, .control = false },
    .{ .opcode = 0x06, .operands = 0, .control = false },
    .{ .opcode = 0x07, .operands = 0, .control = false },
    .{ .opcode = 0x14, .operands = 0, .control = false },
    .{ .opcode = 0x15, .operands = 0, .control = false },
    .{ .opcode = 0x16, .operands = 0, .control = false },
    .{ .opcode = 0x17, .operands = 0, .control = false },
    .{ .opcode = 0x18, .operands = 0, .control = false },
    .{ .opcode = 0x19, .operands = 0, .control = false },
    .{ .opcode = 0x1A, .operands = 0, .control = false },
    .{ .opcode = 0x1B, .operands = 0, .control = false },
    .{ .opcode = 0x1C, .operands = 0, .control = false },
    .{ .opcode = 0x1D, .operands = 0, .control = false },
    .{ .opcode = 0x1E, .operands = 0, .control = false },
    .{ .opcode = 0x1F, .operands = 0, .control = false },
    .{ .opcode = 0x20, .operands = 0, .control = false },
    .{ .opcode = 0x21, .operands = 1, .control = false },
    .{ .opcode = 0x22, .operands = 1, .control = false },
    .{ .opcode = 0x23, .operands = 2, .control = true },
    .{ .opcode = 0x24, .operands = 2, .control = true },
    .{ .opcode = 0x25, .operands = 0, .control = true },
    .{ .opcode = 0x26, .operands = 1, .control = false },
    .{ .opcode = 0x27, .operands = 1, .control = false },
    .{ .opcode = 0x28, .operands = 1, .control = false },
    .{ .opcode = 0x29, .operands = 2, .control = false },
    .{ .opcode = 0x2A, .operands = 1, .control = true },
    .{ .opcode = 0x2B, .operands = 1, .control = true },
    .{ .opcode = 0x2C, .operands = 1, .control = false },
    .{ .opcode = 0x2D, .operands = 1, .control = false },
    .{ .opcode = 0x2E, .operands = 1, .control = false },
    .{ .opcode = 0x2F, .operands = 1, .control = false },
    .{ .opcode = 0x30, .operands = 1, .control = false },
    .{ .opcode = 0x31, .operands = 1, .control = false },
    .{ .opcode = 0x32, .operands = 1, .control = false },
    .{ .opcode = 0x33, .operands = 0, .control = false },
    .{ .opcode = 0x34, .operands = 0, .control = false },
    .{ .opcode = 0x35, .operands = 0, .control = false },
    .{ .opcode = 0x36, .operands = 0, .control = false },
    .{ .opcode = 0x37, .operands = 0, .control = false },
    .{ .opcode = 0x38, .operands = 0, .control = false },
    .{ .opcode = 0x39, .operands = 0, .control = false },
    .{ .opcode = 0x3A, .operands = 0, .control = false },
    .{ .opcode = 0x3B, .operands = 0, .control = false },
    .{ .opcode = 0x3C, .operands = 0, .control = false },
    .{ .opcode = 0x3D, .operands = 0, .control = false },
    .{ .opcode = 0x3E, .operands = 0, .control = false },
    .{ .opcode = 0x3F, .operands = 1, .control = false },
    .{ .opcode = 0x40, .operands = 1, .control = false },
    .{ .opcode = 0x41, .operands = 1, .control = false },
    .{ .opcode = 0x42, .operands = 2, .control = true },
    .{ .opcode = 0x43, .operands = 0, .control = true },
    .{ .opcode = 0x44, .operands = 1, .control = false },
    .{ .opcode = 0x45, .operands = 0, .control = false },
    .{ .opcode = 0x46, .operands = 0, .control = false },
    .{ .opcode = 0x47, .operands = 1, .control = true },
    .{ .opcode = 0x48, .operands = 0, .control = false },
    .{ .opcode = 0x49, .operands = 1, .control = false },
    .{ .opcode = 0x4A, .operands = 1, .control = false },
    .{ .opcode = 0x4B, .operands = 0, .control = true },
    .{ .opcode = 0x4C, .operands = 0, .control = false },
    .{ .opcode = 0x4D, .operands = 1, .control = false },
    .{ .opcode = 0x4E, .operands = 1, .control = false },
    .{ .opcode = 0x4F, .operands = 1, .control = false },
    .{ .opcode = 0x51, .operands = 2, .control = true },
    .{ .opcode = 0x52, .operands = 0, .control = true },
    .{ .opcode = 0x53, .operands = 0, .control = false },
    .{ .opcode = 0x54, .operands = 1, .control = false },
    .{ .opcode = 0x55, .operands = 1, .control = true },
    .{ .opcode = 0xD6, .operands = 0, .control = false },
    .{ .opcode = 0xD7, .operands = 0, .control = false },
    .{ .opcode = 0xD8, .operands = 0, .control = false },
    .{ .opcode = 0xDD, .operands = 0, .control = false },
    .{ .opcode = 0xDE, .operands = 0, .control = false },
    .{ .opcode = 0xDF, .operands = 0, .control = false },
};

/// Looks up an opcode, or null when the handler table leaves it unimplemented.
pub fn opcodeInfo(opcode: u8) ?OpcodeInfo {
    for (opcodes) |info| {
        if (info.opcode == opcode) return info;
    }
    return null;
}

pub const Instruction = struct {
    /// Offset from the start of the block.
    address: usize,
    opcode: Opcode,
    operands: []const u8,
    control: bool,
};

/// Decodes one block of bytecode.
///
/// A block begins with a `u16` length and ends at an `end` opcode; anything after that within the
/// length is a trailer the decoder does not interpret. Blocks are entered by address, from a part
/// table a `call_part` reaches, so a section cannot simply be walked from its start.
pub const BlockReader = struct {
    code: []const u8,
    pos: usize = 0,
    finished: bool = false,

    pub const Stop = enum { end, unimplemented, truncated };

    pub fn next(reader: *BlockReader) ?Instruction {
        if (reader.finished or reader.pos >= reader.code.len) return null;
        const opcode = reader.code[reader.pos];
        const info = opcodeInfo(opcode) orelse return null;
        if (reader.pos + 1 + info.operands > reader.code.len) return null;

        const address = reader.pos;
        const operands = reader.code[reader.pos + 1 ..][0..info.operands];
        reader.pos += 1 + info.operands;
        if (opcode == @intFromEnum(Opcode.end)) reader.finished = true;
        return .{
            .address = address,
            .opcode = @enumFromInt(opcode),
            .operands = operands,
            .control = info.control,
        };
    }

    /// Why decoding stopped, once `next` has returned null.
    pub fn stop(reader: BlockReader) Stop {
        if (reader.finished) return .end;
        if (reader.pos >= reader.code.len) return .truncated;
        return if (opcodeInfo(reader.code[reader.pos]) == null) .unimplemented else .truncated;
    }
};

pub const Error = error{
    /// Too small to hold a directory.
    NotAMission,
    /// A section runs past the end of the image.
    Truncated,
    /// Still RefPack compressed. Read it through a `.HOG` archive, which expands it.
    Compressed,
};

pub const Mission = struct {
    image: []const u8,
    directory: []align(1) const DirectoryEntry,

    pub fn parse(image: []const u8) Error!Mission {
        if (image.len >= 2 and image[0] == 0x10 and image[1] == 0xFB) return error.Compressed;
        const bytes = section_count * @sizeOf(DirectoryEntry);
        if (image.len < bytes) return error.NotAMission;
        return .{
            .image = image,
            .directory = @alignCast(std.mem.bytesAsSlice(DirectoryEntry, image[0..bytes])),
        };
    }

    pub fn entry(mission: Mission, section: Section) DirectoryEntry {
        const index = @intFromEnum(section);
        return if (index < mission.directory.len) mission.directory[index] else .{
            .count = 0,
            ._unused = 0,
            .relocation_flags = 0,
            .offset = DirectoryEntry.unused_offset,
        };
    }

    /// The records of a fixed-stride section, as `T`.
    pub fn records(mission: Mission, comptime T: type, section: Section) Error![]align(1) const T {
        const slot = mission.entry(section);
        if (!slot.isUsed() or slot.count == 0) return &.{};
        const bytes = @as(usize, slot.count) * @sizeOf(T);
        if (slot.offset + bytes > mission.image.len) return error.Truncated;
        return @alignCast(std.mem.bytesAsSlice(T, mission.image[slot.offset..][0..bytes]));
    }

    /// The bytecode of section `script`.
    pub fn script(mission: Mission) Error![]const u8 {
        const slot = mission.entry(.script);
        if (!slot.isUsed() or slot.count == 0) return &.{};
        if (slot.offset + slot.count > mission.image.len) return error.Truncated;
        return mission.image[slot.offset..][0..slot.count];
    }

    pub fn ships(mission: Mission) Error![]align(1) const Ship {
        return mission.records(Ship, .ships);
    }

    pub fn triggers(mission: Mission) Error![]align(1) const Trigger {
        return mission.records(Trigger, .triggers);
    }

    pub fn globals(mission: Mission) Error![]align(1) const Global {
        return mission.records(Global, .globals);
    }

    /// Resolves a name. Offsets are relative to the start of the string pool, not to the file, and
    /// the pool is a run of NUL-terminated strings rather than an indexed table.
    pub fn name(mission: Mission, offset: u16) []const u8 {
        const pool = mission.entry(.strings);
        if (!pool.isUsed()) return "";
        const start = pool.offset + offset;
        if (start >= mission.image.len) return "";
        const rest = mission.image[start..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse return "";
        return rest[0..end];
    }

    /// Where the string pool ends, which is where the next used section begins.
    pub fn stringPoolEnd(mission: Mission) usize {
        const pool = mission.entry(.strings);
        if (!pool.isUsed()) return 0;
        var end = mission.image.len;
        for (mission.directory) |slot| {
            if (slot.isUsed() and slot.offset > pool.offset and slot.offset < end) end = slot.offset;
        }
        return end;
    }
};

test "directory and records line up" {
    // A mission image with a string pool and one ship.
    var image: [0x400]u8 = @splat(0);
    const directory: []align(1) DirectoryEntry =
        @alignCast(std.mem.bytesAsSlice(DirectoryEntry, image[0 .. section_count * 8]));
    for (directory) |*slot| slot.* = .{
        .count = 0,
        ._unused = 0,
        .relocation_flags = 0,
        .offset = DirectoryEntry.unused_offset,
    };

    const pool_at = 0x100;
    directory[@intFromEnum(Section.strings)] = .{
        .count = 2,
        ._unused = 0,
        .relocation_flags = 0xF,
        .offset = pool_at,
    };
    @memcpy(image[pool_at..][0..12], "Player_Ship\x00");

    const ships_at = 0x200;
    directory[@intFromEnum(Section.ships)] = .{
        .count = 1,
        ._unused = 0,
        .relocation_flags = 0xF,
        .offset = ships_at,
    };
    const ship: *align(1) Ship = @ptrCast(image[ships_at..][0..@sizeOf(Ship)]);
    ship.* = std.mem.zeroes(Ship);
    ship.flight_group = 3;
    ship.name = 0;
    ship.iff = 255;
    ship.kind = 999;
    ship.yaw = 90;
    ship.roll = -1;

    const mission: Mission = try .parse(&image);
    const list = try mission.ships();
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("Player_Ship", mission.name(list[0].name));
    try std.testing.expectEqual(@as(u16, 999), list[0].kind);
    try std.testing.expectEqual(@as(i16, 90), list[0].yaw);

    // An unused section yields nothing rather than reading stray bytes.
    try std.testing.expectEqual(@as(usize, 0), (try mission.triggers()).len);
}

test "rejects a compressed or truncated image" {
    try std.testing.expectError(error.Compressed, Mission.parse(&.{ 0x10, 0xFB, 0, 0, 0 }));
    try std.testing.expectError(error.NotAMission, Mission.parse(&.{ 0, 1, 2 }));
}

test "condition names cover the scriptable range" {
    try std.testing.expectEqual(@as(u8, 0x20), @intFromEnum(Condition.last_scriptable));
    try std.testing.expectEqual(Condition.proximity_close, @as(Condition, @enumFromInt(5)));
    // Beyond the scriptable range the enum stays open rather than misnaming an internal type.
    const internal: Condition = @enumFromInt(0x22);
    try std.testing.expect(std.enums.tagName(Condition, internal) == null);
}

test "decodes a block and stops at its end marker" {
    // The opening block of mission1: call, command, read a global, wait, compare, branch, call,
    // jump, call, command, set AI, end, then a trailer the block length still covers.
    const block = [_]u8{
        0x22, 0x01, 0x21, 0x17, 0x27, 0x00, 0x28, 0x00, 0x02, 0x24, 0x00, 0x07,
        0x22, 0x15, 0x42, 0x00, 0x04, 0x22, 0x18, 0x21, 0x17, 0x32, 0x01, 0x43,
        0x32, 0x01, 0x01, 0x00,
    };
    var reader: BlockReader = .{ .code = &block };

    const expected = [_]Opcode{
        .call_part, .command, .read_global, .wait,    .compare_ne, .push_immediate_b,
        .call_part, .jump,    .call_part,   .command, .ai,         .end,
    };
    for (expected) |opcode| {
        try std.testing.expectEqual(opcode, reader.next().?.opcode);
    }
    // The end opcode terminates the block; the four trailing bytes are not instructions.
    try std.testing.expectEqual(@as(?Instruction, null), reader.next());
    try std.testing.expectEqual(BlockReader.Stop.end, reader.stop());
    try std.testing.expectEqual(@as(usize, 24), reader.pos);
}

test "the implemented opcode range matches the payload's handler table" {
    try std.testing.expect(Opcode.compare_ne.isImplemented());
    try std.testing.expect(Opcode.jump_part.isImplemented());
    try std.testing.expect(@as(Opcode, @enumFromInt(0x55)).isImplemented());
    // Null entries in the table: no handler, so the opcode does not exist.
    try std.testing.expect(!@as(Opcode, @enumFromInt(0x00)).isImplemented());
    try std.testing.expect(!@as(Opcode, @enumFromInt(0x10)).isImplemented());
    try std.testing.expect(!@as(Opcode, @enumFromInt(0x56)).isImplemented());
}

test "an unnamed value formats as a number instead of panicking" {
    var buffer: [32]u8 = undefined;

    var named: std.Io.Writer = .fixed(&buffer);
    try named.print("{f}", .{Condition.destroyed});
    try std.testing.expectEqualStrings("destroyed", named.buffered());

    // `{t}` would panic here; this path is generated per tag at comptime and cannot.
    var unnamed: std.Io.Writer = .fixed(&buffer);
    try unnamed.print("{f}", .{@as(Condition, @enumFromInt(0x22))});
    try std.testing.expectEqualStrings("34", unnamed.buffered());

    var repeat: std.Io.Writer = .fixed(&buffer);
    try repeat.print("{f}", .{@as(Trigger.Repeat, @enumFromInt(1))});
    try std.testing.expectEqualStrings("1", repeat.buffered());
}

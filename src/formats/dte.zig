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

pub const vm_opcodes = @import("vm_opcodes.zig");

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
/// The handler table holds 86 entries, of which 71 are filled: `0x02` to `0x07` and `0x14` to
/// `0x55`, minus `0x50`. Those 71 are the whole instruction set. Their sizes and shapes are in
/// [`vm_opcodes`](vm_opcodes.zig), derived from the handlers themselves by `src/tools/vmgen`.
pub const Opcode = enum(u8) {
    /// Compare not-equal.
    compare_ne = 0x02,
    /// Compare equal.
    compare_eq = 0x03,
    /// Squad or condition membership test.
    membership = 0x14,
    /// Call Executor command `n` from the catalogue the engine installs at load.
    command = 0x21,
    /// Calls the script part named by its operand, through a table of parts.
    call_part = 0x22,
    /// Pops a value and branches when it is zero, over a big-endian displacement counted from the
    /// displacement's own position. `0x24` runs the same handler, so the two are one operation.
    branch_if_zero = 0x23,
    branch_if_zero_alt = 0x24,
    /// Read the value of global `n`.
    read_global = 0x27,
    /// Wait, or fetch an operand in a compare.
    wait = 0x28,
    /// Pushes a pointer to the bytes that follow and steps over them. The operand byte is the
    /// length of the whole run, itself included, and what follows is a NUL-terminated file name:
    /// a `.wav` of speech or a `.ut` cutscene. `0x2B` runs the same handler.
    speech = 0x2A,
    speech_alt = 0x2B,
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
    /// Jumps by a **big-endian** 16-bit displacement, the one place the format is not
    /// little-endian.
    jump = 0x42,
    /// Returns from a part: restores the caller's frame, instruction pointer and block end. When
    /// the call depth is already zero the thread is finished instead. `0x25` is the same handler.
    @"return" = 0x43,
    return_alt = 0x25,
    /// Branch into part `n`.
    jump_part = 0x4D,
    /// Branches to one of a table of arms, chosen by a roll against each arm's threshold. A count
    /// byte, a big-endian default target, then that many four-byte arms.
    random_branch = 0x51,
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
pub const Instruction = struct {
    /// Offset from the start of the block's instructions.
    address: usize,
    opcode: Opcode,
    /// The operand bytes, and for `inline_data` the data they introduce.
    operands: []const u8,
    form: vm_opcodes.Form,

    /// Bytes the whole instruction occupies.
    pub fn size(instruction: Instruction) usize {
        return 1 + instruction.operands.len;
    }

    /// The bytes an `inline_data` instruction carries, after the length byte. Null for every
    /// other form.
    pub fn inlineData(instruction: Instruction) ?[]const u8 {
        if (instruction.form != .inline_data) return null;
        return instruction.operands[1..];
    }
};

/// How many bytes the instruction at `code[pos]` occupies, or null when it cannot be decoded.
///
/// Most opcodes are a fixed size. Three shapes are not, and each carries its length in its own
/// operands, so the size is still known without tracking any state:
///
/// - `inline_data` (`0x2A`, `0x2B`): one byte holding the total length of the operand run.
/// - `jump_table` (`0x51`): a count, a two-byte default target, then that many four-byte arms.
///   The handler is the only one whose encoding this module reads rather than `vmgen` deriving
///   it, because its length depends on a byte the instruction-pointer analysis cannot follow.
/// - `branch` and `transfer` are fixed sizes; only where execution resumes differs.
fn instructionSize(code: []const u8, pos: usize) ?usize {
    const info = vm_opcodes.find(code[pos]) orelse return null;
    const operands = code[pos + 1 ..];
    const length: usize = switch (info.form) {
        .inline_data => blk: {
            if (operands.len < 1) return null;
            // The byte counts itself, so a run of 1 is the byte alone.
            break :blk @max(operands[0], 1);
        },
        else => if (info.opcode == @intFromEnum(Opcode.random_branch)) blk: {
            if (operands.len < 3) return null;
            break :blk 3 + 4 * @as(usize, operands[0]);
        } else info.operands,
    };
    if (pos + 1 + length > code.len) return null;
    return 1 + length;
}

/// Decodes one block of bytecode.
///
/// A block begins with a `u16` length that **counts its own two bytes**: the engine starts a
/// thread with its instruction pointer at `block + 2` and its limit at `block + length`, so the
/// instructions occupy `length - 2` bytes. The last of those is a `return`, followed by up to
/// three bytes of padding that bring the block to a four-byte boundary. Decoding therefore runs to
/// the limit rather than stopping at the first `return`, which may be an early exit from a branch,
/// and treats only a short run after a `return` as padding.
///
/// Blocks are entered by address, from a part table a `call_part` reaches, so a section cannot
/// simply be walked from its start.
pub const BlockReader = struct {
    code: []const u8,
    pos: usize = 0,
    /// Set once a `return` has been decoded, after which a short tail is padding.
    returned: bool = false,
    /// The length the block's header declares. A handful of missions declare more than their
    /// script section holds, so `code` is clamped to the section and this records the claim.
    declared: u16 = 0,

    /// Blocks are padded out to this many bytes.
    pub const alignment = 4;

    /// Bytes of a block header, which its length field includes.
    pub const header_len = 2;

    /// Reads the block at `offset` in `section`, returning a reader over its instructions.
    pub fn at(section: []const u8, offset: usize) ?BlockReader {
        if (offset + header_len > section.len) return null;
        const declared = std.mem.readInt(u16, section[offset..][0..header_len], .little);
        if (declared <= header_len) return null;
        const body = section[offset + header_len ..];
        return .{
            .code = body[0..@min(declared - header_len, body.len)],
            .declared = declared,
        };
    }

    /// Whether the block runs past the end of its section.
    pub fn isShort(reader: BlockReader) bool {
        return reader.code.len + header_len < reader.declared;
    }

    /// Why decoding stopped, once `next` has returned null.
    pub const Stop = enum {
        /// The block's instructions were decoded in full.
        complete,
        /// A byte the handler table leaves unimplemented.
        unimplemented,
        /// An instruction runs past the block's end.
        truncated,
    };

    /// The bytes from the cursor to the end of the block.
    pub fn rest(reader: BlockReader) []const u8 {
        return reader.code[reader.pos..];
    }

    /// The block's trailing padding, once decoding has reached it. Empty until then, and empty
    /// once the block is exhausted.
    pub fn padding(reader: BlockReader) []const u8 {
        const left = reader.rest();
        const is_padding = reader.returned and left.len != 0 and left.len < alignment;
        return if (is_padding) left else &.{};
    }

    pub fn next(reader: *BlockReader) ?Instruction {
        const left = reader.rest();
        if (left.len == 0 or reader.padding().len != 0) return null;

        const opcode = left[0];
        const info = vm_opcodes.find(opcode) orelse return null;
        const length = instructionSize(reader.code, reader.pos) orelse return null;

        const address = reader.pos;
        reader.pos += length;
        if (opcode == @intFromEnum(Opcode.@"return")) reader.returned = true;
        return .{
            .address = address,
            .opcode = @enumFromInt(opcode),
            .operands = left[1..length],
            .form = info.form,
        };
    }

    pub fn stop(reader: BlockReader) Stop {
        const left = reader.rest();
        if (left.len == 0 or reader.padding().len != 0) return .complete;
        return if (vm_opcodes.find(left[0]) == null) .unimplemented else .truncated;
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

test "decodes a block down to its alignment padding" {
    // The opening block of mission1: call, command, read a global, wait, compare, branch, call,
    // jump, call, command, set AI, return, then two bytes that pad the block to a multiple of four.
    const section = [_]u8{
        0x1C, 0x00, 0x22, 0x01, 0x21, 0x17, 0x27, 0x00, 0x28, 0x00, 0x02, 0x24, 0x00, 0x07,
        0x22, 0x15, 0x42, 0x00, 0x04, 0x22, 0x18, 0x21, 0x17, 0x32, 0x01, 0x43, 0x32, 0x01,
    };
    var reader = BlockReader.at(&section, 0).?;
    try std.testing.expectEqual(@as(u16, 0x1C), reader.declared);
    try std.testing.expect(!reader.isShort());
    try std.testing.expectEqual(@as(usize, 26), reader.code.len);

    const expected = [_]Opcode{
        .call_part, .command, .read_global, .wait,    .compare_ne, .branch_if_zero_alt,
        .call_part, .jump,    .call_part,   .command, .ai,         .@"return",
    };
    for (expected) |opcode| {
        try std.testing.expectEqual(opcode, reader.next().?.opcode);
    }
    try std.testing.expectEqual(@as(?Instruction, null), reader.next());
    try std.testing.expectEqual(BlockReader.Stop.complete, reader.stop());
    try std.testing.expectEqual(@as(usize, 24), reader.pos);
    try std.testing.expectEqualSlices(u8, &.{ 0x32, 0x01 }, reader.padding());
}

test "decodes an inline string and steps over it" {
    // The opening block of mission81, which cues a speech file by name.
    const section = [_]u8{
        0x58, 0x00, 0x28, 0x00, 0x21, 0x05, 0x2A, 0x0F,
    } ++ "new_sim02.wav\x00".* ++ [_]u8{ 0x28, 0x01 };
    var reader = BlockReader.at(&section, 0).?;
    // The block claims more than the section holds, so it is clamped rather than rejected.
    try std.testing.expect(reader.isShort());

    try std.testing.expectEqual(Opcode.wait, reader.next().?.opcode);
    try std.testing.expectEqual(Opcode.command, reader.next().?.opcode);

    const speech = reader.next().?;
    try std.testing.expectEqual(Opcode.speech, speech.opcode);
    try std.testing.expectEqual(vm_opcodes.Form.inline_data, speech.form);
    try std.testing.expectEqualStrings("new_sim02.wav", speech.inlineData().?[0..13]);
    try std.testing.expectEqual(Opcode.wait, reader.next().?.opcode);
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

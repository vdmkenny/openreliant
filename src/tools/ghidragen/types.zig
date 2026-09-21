//! The type schema: every exported Zig type as rows that `ghidra/scripts/ApplyTypes.java` turns
//! into Ghidra data types.
//!
//! Rows are tab-separated. The first column says what a row is:
//!
//!     struct    <name> <size>
//!     field     <struct> <offset> <field> <type>
//!     bits      <struct> <offset> <bytes> <bit offset> <bits> <field> <base type>
//!     union     <name> <size>
//!     member    <union> <field> <type>
//!     enum      <name> <size>
//!     value     <enum> <label> <value>
//!     function  <name> <signature>
//!
//! A type is a Ghidra type string: a name, then `*` and `[n]` decorations, as Ghidra's
//! `DataTypeParser` reads them. A signature is C with no function name, which the script inserts.
//! A packed struct becomes a structure of bitfields over its backing integer. A run of unknown
//! bytes, a `_unknown` field of `u8` array type, gets no row: Ghidra leaves it undefined and names
//! what reads it by offset. A `u8` array whose field name says it is a name becomes `char`.

const std = @import("std");
const Io = std.Io;

const starlancer = @import("starlancer");
const dte = starlancer.dte;
const lancer = starlancer.lancer;
const shp = starlancer.shp;

const Export = struct { []const u8, type };

/// Every type the schema defines, under its Ghidra name. A struct, union, enum or code type that
/// one of these refers to must be listed as well, or the tool does not compile.
pub const exported = [_]Export{
    // Mission records, which the engine uses in place.
    .{ "SectionEntry", dte.DirectoryEntry },
    .{ "MissionGlobal", dte.Global },
    .{ "MissionShip", dte.Ship },
    .{ "MissionShipFlags", dte.Ship.Flags },
    .{ "FlightGroup", dte.FlightGroup },
    .{ "Trigger", dte.Trigger },
    .{ "TriggerRepeat", dte.Trigger.Repeat },
    .{ "TriggerReference", dte.Reference },
    .{ "ReferenceTag", dte.Reference.Tag },
    .{ "Condition", dte.Condition },
    .{ "MissionObject", dte.Object },
    .{ "ObjectKind", dte.Object.Kind },
    .{ "ObjectKindSet", dte.Object.KindSet },
    .{ "MissionPart", dte.Part },
    .{ "MissionPartFlags", dte.Part.Flags },
    .{ "Squad", dte.Squad },
    .{ "SquadMember", dte.SquadMember },

    // The script VM.
    .{ "VmHandler", lancer.vm.Handler },
    .{ "VmCommand", lancer.vm.Command },
    .{ "VmShipCommand", lancer.vm.ShipCommand },
    .{ "VmThread", lancer.vm.Thread },
    .{ "VmCallRecord", lancer.vm.CallRecord },
    .{ "VmFunction", lancer.vm.Function },
    .{ "VmFunctionEntry", lancer.vm.Function.Entry },
    .{ "VmParam", lancer.vm.Function.Param },
    .{ "ParamKinds", dte.vm_commands.Kinds },
    .{ "VmTimer", lancer.vm.Timer },
    .{ "ConditionDescriptor", lancer.vm.ConditionDescriptor },
    .{ "EventValue", lancer.vm.EventValue },
    .{ "ObjectEvents", lancer.vm.ObjectEvents },
    .{ "QueuedEvent", lancer.vm.QueuedEvent },
    .{ "ComponentTag", lancer.vm.ComponentTag },

    // Stat tables.
    .{ "FlightModel", lancer.stats.FlightModel },
    .{ "ShipCombat", lancer.stats.ShipCombat },
    .{ "GunStats", lancer.stats.Gun },
    .{ "MissileStats", lancer.stats.Missile },
    .{ "PilotStats", lancer.stats.Pilot },

    // Sound.
    .{ "SoundVoice", lancer.sound.Voice },

    // Player input.
    .{ "JoystickState", lancer.input.JoystickState },
    .{ "JoystickAxes", lancer.input.JoystickAxes },
    .{ "MouseState", lancer.input.MouseState },
    .{ "ControlBinding", lancer.input.ControlBinding },
    .{ "ControlModifier", lancer.input.ControlBinding.Modifier },
    .{ "ControlAction", starlancer.controls.Action },
    .{ "ControlMode", lancer.input.ControlMode },

    // Orders.
    .{ "Order", starlancer.orders.Order },
    .{ "OrderRecord", lancer.orders.Record },
    .{ "OrderFlags", lancer.orders.Record.Flags },
    .{ "OrderTarget", lancer.orders.Target },
    .{ "OrderTargetKind", lancer.orders.Target.Kind },
    .{ "OrderEntry", lancer.orders.Entry },
    .{ "QueuedOrder", lancer.orders.Queued },
    .{ "OrderState", lancer.orders.State },

    // Live objects and their models.
    .{ "GameObject", lancer.game.GameObject },
    .{ "ObjectFlags", lancer.game.GameObject.Flags },
    .{ "ObjectRoutine", lancer.game.Routine },
    .{ "ModelNode", lancer.game.Node },
    .{ "SurrenderFrame", lancer.game.Frame },
    .{ "ObjectComponent", lancer.game.Component },
    .{ "ShipTypeEntry", lancer.game.ShipType },
    .{ "MountedModel", lancer.game.MountedModel },
    .{ "ShpPart", shp.Part },
    .{ "ShpPartFlags", shp.Part.Flags },
    .{ "ShpAttachment", shp.Attachment },
    .{ "ShpAttachmentKind", shp.Attachment.Kind },
    .{ "Vec3", shp.Vec3 },
};

comptime {
    @setEvalBranchQuota(100_000);
    for (exported, 0..) |a, i| {
        for (exported[0..i]) |b| {
            if (std.mem.eql(u8, a[0], b[0])) @compileError("ghidragen: two types named " ++ a[0]);
            if (a[1] == b[1]) @compileError("ghidragen: " ++ @typeName(a[1]) ++ " is listed twice");
        }
    }
}

/// The Ghidra name of an exported type.
fn nameOf(comptime T: type) []const u8 {
    for (exported) |entry| {
        if (entry[1] == T) return entry[0];
    }
    @compileError("ghidragen: " ++ @typeName(T) ++ " is referred to but not exported");
}

/// Ghidra's type string for `T`.
fn typeString(comptime T: type) []const u8 {
    if (lancer.isPointer(T)) {
        if (T.Target == anyopaque) return "void *";
        return typeString(T.Target) ++ " *";
    }
    return switch (@typeInfo(T)) {
        .bool => "bool",
        .int => |int| switch (int.bits) {
            8 => if (int.signedness == .signed) "sbyte" else "byte",
            16 => if (int.signedness == .signed) "short" else "ushort",
            32 => if (int.signedness == .signed) "int" else "uint",
            64 => if (int.signedness == .signed) "longlong" else "ulonglong",
            else => @compileError("ghidragen: no Ghidra type for " ++ @typeName(T)),
        },
        .float => |float| switch (float.bits) {
            32 => "float",
            64 => "double",
            else => @compileError("ghidragen: no Ghidra type for " ++ @typeName(T)),
        },
        // Consecutive dimensions go outermost first, as in C.
        .array => arrayString(T, ""),
        .@"struct", .@"union", .@"enum", .@"opaque" => nameOf(T),
        else => @compileError("ghidragen: no Ghidra type for " ++ @typeName(T)),
    };
}

fn arrayString(comptime T: type, comptime dimensions: []const u8) []const u8 {
    return switch (@typeInfo(T)) {
        .array => |array| arrayString(array.child, dimensions ++ std.fmt.comptimePrint("[{d}]", .{array.len})),
        else => typeString(T) ++ dimensions,
    };
}

/// The rows defining `T`: a comptime string, so that a type the schema cannot express, or one that
/// refers to a type not exported, is a compile error rather than a failure at run time.
fn Definition(comptime T: type) []const u8 {
    @setEvalBranchQuota(1_000_000);
    const name = nameOf(T);
    if (lancer.isCode(T)) {
        return "function\t" ++ name ++ "\t" ++ T.c_signature ++ "\n";
    }
    return switch (@typeInfo(T)) {
        .@"struct" => |info| switch (info.layout) {
            .@"extern" => structRows(T, name, info),
            .@"packed" => bitsRows(T, name, info),
            .auto => @compileError("ghidragen: " ++ @typeName(T) ++ " has no fixed layout"),
        },
        .@"union" => |info| switch (info.layout) {
            .@"extern" => unionRows(T, name, info),
            else => @compileError("ghidragen: " ++ @typeName(T) ++ " has no fixed layout"),
        },
        .@"enum" => |info| enumRows(T, name, info),
        else => @compileError("ghidragen: cannot define " ++ @typeName(T)),
    };
}

fn structRows(comptime T: type, comptime name: []const u8, comptime info: std.builtin.Type.Struct) []const u8 {
    var rows: []const u8 = std.fmt.comptimePrint("struct\t{s}\t{d}\n", .{ name, @sizeOf(T) });
    for (info.fields) |field| {
        const bytes: ?usize = switch (@typeInfo(field.type)) {
            .array => |array| if (array.child == u8) array.len else null,
            else => null,
        };
        if (bytes != null and std.mem.startsWith(u8, field.name, "_unknown")) continue;
        const field_type = if (bytes != null and std.mem.indexOf(u8, field.name, "name") != null)
            std.fmt.comptimePrint("char[{d}]", .{bytes.?})
        else
            typeString(field.type);
        rows = rows ++ std.fmt.comptimePrint("field\t{s}\t{d}\t{s}\t{s}\n", .{
            name, @offsetOf(T, field.name), field.name, field_type,
        });
    }
    return rows;
}

fn bitsRows(comptime T: type, comptime name: []const u8, comptime info: std.builtin.Type.Struct) []const u8 {
    const base = typeString(info.backing_integer.?);
    var rows: []const u8 = std.fmt.comptimePrint("struct\t{s}\t{d}\n", .{ name, @sizeOf(T) });
    for (info.fields) |field| {
        const field_base = switch (@typeInfo(field.type)) {
            .bool, .int => base,
            .@"enum" => nameOf(field.type),
            else => @compileError("ghidragen: cannot make a bitfield of " ++ @typeName(field.type)),
        };
        rows = rows ++ std.fmt.comptimePrint("bits\t{s}\t0\t{d}\t{d}\t{d}\t{s}\t{s}\n", .{
            name, @sizeOf(T), @bitOffsetOf(T, field.name), @bitSizeOf(field.type), field.name, field_base,
        });
    }
    return rows;
}

fn unionRows(comptime T: type, comptime name: []const u8, comptime info: std.builtin.Type.Union) []const u8 {
    var rows: []const u8 = std.fmt.comptimePrint("union\t{s}\t{d}\n", .{ name, @sizeOf(T) });
    for (info.fields) |field| {
        rows = rows ++ std.fmt.comptimePrint("member\t{s}\t{s}\t{s}\n", .{ name, field.name, typeString(field.type) });
    }
    return rows;
}

fn enumRows(comptime T: type, comptime name: []const u8, comptime info: std.builtin.Type.Enum) []const u8 {
    var rows: []const u8 = std.fmt.comptimePrint("enum\t{s}\t{d}\n", .{ name, @sizeOf(T) });
    for (info.fields) |field| {
        rows = rows ++ std.fmt.comptimePrint("value\t{s}\t{s}\t{d}\n", .{ name, field.name, field.value });
    }
    return rows;
}

/// Every row, in the order `exported` lists the types.
pub const schema = blk: {
    @setEvalBranchQuota(10_000_000);
    var rows: []const u8 = "";
    for (exported) |entry| rows = rows ++ Definition(entry[1]);
    break :blk rows;
};

pub fn write(w: *Io.Writer) Io.Writer.Error!void {
    try w.writeAll("# Generated by ghidragen types from the Zig definitions in src/.\n");
    try w.writeAll(schema);
}

test typeString {
    try std.testing.expectEqualStrings("uint[2][5]", comptime typeString([2][5]u32));
    try std.testing.expectEqualStrings("VmThread *", comptime typeString(lancer.Pointer(lancer.vm.Thread)));
    try std.testing.expectEqualStrings("byte *[4]", comptime typeString([4]lancer.Pointer(u8)));
    try std.testing.expectEqualStrings("void *", comptime typeString(lancer.Pointer(anyopaque)));
}

test structRows {
    const rows = comptime Definition(lancer.game.Node);
    try std.testing.expect(std.mem.indexOf(u8, rows, "_unknown_14") == null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "field\tModelNode\t164\tpart\tShpPart *\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, comptime Definition(shp.Part), "\tname_bytes\tchar[64]\n") != null);
}

test schema {
    try std.testing.expect(std.mem.indexOf(u8, schema, "struct\tVmThread\t184\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "field\tVmThread\t173\tcall_depth\tbyte\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "bits\tMissionPartFlags\t0\t1\t0\t1\tstart\tbyte\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "value\tTriggerRepeat\tcounted\t2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "member\tVmFunctionEntry\timplementation\tVmCommand *\n") != null);
}

//! `C:\lancer\game\Executor.cpp`: the mission script's commands.
//! [`executor/commands.zig`](executor/commands.zig) transcribes the command catalogue.
//! **Unverified:** the catalogue lies in the data before this file's path, and some commands lie
//! outside this file's code.

const std = @import("std");

const engine = @import("../../engine.zig");
const Code = engine.Code;
const vm = @import("../vm.zig");

pub const commands = @import("executor/commands.zig");

/// The catalogue's number of the command `name`: the operand of `command` that runs it.
pub fn commandIndex(comptime name: []const u8) u8 {
    return comptime for (commands.table, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, name)) break index;
    } else @compileError("the Executor has no command " ++ name);
}

/// The implementation of command `number`, or null for one not ported yet
/// ([#36](https://github.com/vdmkenny/openreliant/issues/36),
/// [#281](https://github.com/vdmkenny/openreliant/issues/281)).
pub fn implementation(number: u8) ?vm.Implementation {
    return if (number < implementations.len) implementations[number] else null;
}

const implementations = table: {
    var table: [commands.table.len]?vm.Implementation = @splat(null);
    for ([_]struct { []const u8, vm.Implementation }{
        .{ "CreateTimer", vm.Machine.createTimer },
        .{ "DestroyTimer", vm.Machine.destroyTimer },
        .{ "Wait", vm.Machine.wait },
        .{ "InterruptTriggerCode", vm.Machine.interruptTriggerCode },
        .{ "KillAllScriptExecutionExecptMe", vm.Machine.killAllScriptExecutionExceptMe },
    }) |pair| table[commandIndex(pair[0])] = pair[1];
    break :table table;
};

/// A command's implementation. `args` points at its first argument on the stack. The result is
/// stored in `Thread.result`, and a zero result also ends the handler loop.
pub const Command = Code("uint __fastcall (byte **ip, uint *args)");

/// What a command hands `for_each_ship` to run for each ship its first argument names: the ship,
/// and the command's remaining arguments.
pub const ShipCommand = Code("uint __fastcall (MissionShip *ship, uint *args)");

test commandIndex {
    try std.testing.expectEqual(0x05, commandIndex("Wait"));
    try std.testing.expectEqualStrings("Wait", commands.table[commandIndex("Wait")].name);
}

test implementation {
    try std.testing.expect(implementation(commandIndex("Wait")) != null);
    try std.testing.expectEqual(null, implementation(commandIndex("PrintShipName")));
    try std.testing.expectEqual(null, implementation(0xFF));
}

test {
    std.testing.refAllDecls(@This());
}

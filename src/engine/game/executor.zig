//! `C:\lancer\game\Executor.cpp`: the mission script's commands.
//! [`executor/commands.zig`](executor/commands.zig) transcribes the command catalogue.
//! **Unverified:** the catalogue lies in the data before this file's path, and some commands lie
//! outside this file's code.

const std = @import("std");

const engine = @import("../../engine.zig");
const Code = engine.Code;

pub const commands = @import("executor/commands.zig");

/// A command's implementation. `args` points at its first argument on the stack. The result is
/// stored in `Thread.result`, and a zero result also ends the handler loop.
pub const Command = Code("uint __fastcall (byte **ip, uint *args)");

/// What a command hands `for_each_ship` to run for each ship its first argument names: the ship,
/// and the command's remaining arguments.
pub const ShipCommand = Code("uint __fastcall (MissionShip *ship, uint *args)");

test {
    std.testing.refAllDecls(@This());
}

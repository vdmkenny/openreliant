//! ghidragen: writes the tables the Ghidra scripts apply to the payload, from the Zig definitions.
//!
//!     ghidragen names <output.tsv>
//!     ghidragen types <output.tsv>
//!
//! `names`: a row naming each VM opcode handler and command implementation, which nothing calls
//! directly, for `ghidra/scripts/ApplyNames.java`. It comes from the committed opcode and command
//! tables and `dte.Opcode`.
//!
//! `types`: the data types of `src/lancer.zig` and the mission records of `src/formats/dte.zig`, for
//! `ghidra/scripts/ApplyTypes.java`. The schema is built at compile time.

const std = @import("std");
const Io = std.Io;

const names = @import("names.zig");
const types = @import("types.zig");

const usage =
    \\usage: ghidragen names <output.tsv>
    \\       ghidragen types <output.tsv>
    \\
;

const Mode = enum { names, types };

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    const mode = std.meta.stringToEnum(Mode, args[1]) orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };

    const cwd: Io.Dir = .cwd();
    var buffer: [16 << 10]u8 = undefined;
    var out: Io.File.Writer = .init(try cwd.createFile(init.io, args[2], .{}), init.io, &buffer);
    defer out.file.close(init.io);
    switch (mode) {
        .names => try names.write(&out.interface),
        .types => try types.write(&out.interface),
    }
    try out.interface.flush();
    return 0;
}

test {
    std.testing.refAllDecls(names);
    std.testing.refAllDecls(types);
}

//! ghidragen: writes the tables the Ghidra scripts apply to the payload, from the Zig definitions.
//!
//!     ghidragen names <output.tsv>
//!     ghidragen types <output.tsv>
//!     ghidragen sources <output.tsv>
//!
//! `names`: a row naming each VM opcode handler, command implementation and order routine, which
//! nothing calls directly, and each group of the order table, for `ghidra/scripts/Annotate.java`.
//! It comes from the committed opcode, command and order tables and `dte.Opcode`.
//!
//! `types`: the data types of `src/lancer.zig` and the mission records of `src/formats/dte.zig`, for
//! `ghidra/scripts/Annotate.java`. The schema is built at compile time.
//!
//! `sources`: the Sources program tree of `src/lancer/sources.zig`, for
//! `ghidra/scripts/ApplySources.java`: each source file's known code, the stretches between files,
//! and the C runtime.

const std = @import("std");
const Io = std.Io;

const names = @import("names.zig");
const sources = @import("sources.zig");
const types = @import("types.zig");

const usage =
    \\usage: ghidragen names <output.tsv>
    \\       ghidragen types <output.tsv>
    \\       ghidragen sources <output.tsv>
    \\
;

const Mode = enum { names, types, sources };

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
        .sources => try sources.write(&out.interface),
    }
    try out.interface.flush();
    return 0;
}

test {
    std.testing.refAllDecls(names);
    std.testing.refAllDecls(types);
    std.testing.refAllDecls(sources);
    std.testing.refAllDecls(@import("tables.zig"));
}

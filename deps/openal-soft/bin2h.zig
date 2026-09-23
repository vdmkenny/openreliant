//! Writes a file's bytes as a C++ array, as OpenAL Soft's `bin2h.script.cmake` does, for the HRTF
//! data the library embeds.
//!
//!     bin2h <input> <output.hpp> <name>

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) return error.Usage;
    const cwd: std.Io.Dir = .cwd();
    const bytes = try cwd.readFileAlloc(init.io, args[1], arena, .limited(64 << 20));

    var buffer: [64 << 10]u8 = undefined;
    var out: std.Io.File.Writer = .init(try cwd.createFile(init.io, args[2], .{}), init.io, &buffer);
    defer out.file.close(init.io);
    const w = &out.interface;
    try w.print("#pragma once\n\nchar {s}[] = {{\n", .{args[3]});
    for (bytes, 0..) |byte, index| {
        try w.print("static_cast<char>(0x{x:0>2}),", .{byte});
        if (index % 8 == 7) try w.writeByte('\n');
    }
    try w.writeAll("};\n");
    try w.flush();
}

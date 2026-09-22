//! `C:\lancer\game\guns.cpp`: guns. `stats_load_guns` (`0x004788F0`) fills `gun_stats` from
//! `gunstats.bin`, [`formats/stats.zig`](../../formats/stats.zig).

const std = @import("std");
const assert = std.debug.assert;

/// One gun of `gun_stats`.
pub const Gun = extern struct {
    /// `Gun.range`, truncated.
    range: i32,
    /// `Gun._unknown_44`.
    _unknown_04: f32,
    damage: [2]f32,
    /// `100 / Gun.fire_rate`, truncated: the interval between shots.
    refire_interval: i32,
    /// `Gun._unknown_54`, truncated.
    _unknown_14: i32,
    _unknown_18: [5]u32,

    comptime {
        assert(@offsetOf(Gun, "refire_interval") == 0x10);
        assert(@sizeOf(Gun) == 0x2C);
    }
};

/// Gun types `gun_stats` holds, which `stats_load_guns` fills from `gunstats.bin`.
pub const max_types = 15;

/// `gun_stats` (`0x00500CE4`): every gun type's figures at run time.
pub const Stats = struct {
    types: [max_types]Gun = @splat(std.mem.zeroes(Gun)),

    /// `stats_load_guns` (`0x004788F0`): each record of `gunstats.bin` in turn, keeping in whole
    /// numbers what the runtime's `__ftol` cuts down.
    pub fn load(stats: *Stats, file: []align(1) const formats.Gun) void {
        for (stats.types[0..@min(file.len, max_types)], file[0..@min(file.len, max_types)]) |*gun, record| {
            gun.range = std.math.lossyCast(i32, record.range);
            gun._unknown_04 = record._unknown_44;
            gun.damage = record.damage;
            gun.refire_interval = std.math.lossyCast(i32, 100 / record.fire_rate);
            gun._unknown_14 = std.math.lossyCast(i32, record._unknown_54);
        }
    }
};

/// One of an object's guns, as the game keeps it in the 0x60 bytes at `GameObject.guns`.
pub const Fitted = struct {
    /// The turret kind of the part it stands on, or 0 for a gun that does not move.
    turret: u16 = 0,
    /// The part it fires from, and where on the part.
    part: *const objects.Model.Part,
    muzzle: shp.Attachment,
    /// Its type, into `Stats.types`.
    type: u8,
    /// Which of the object's gun groups fires it (`gun_groups_build`).
    group: u8 = 0,
};

/// `0x00479800` with `0x00479640`: the guns a model gives an object, one for each `gun_muzzle`
/// attachment of its parts and of the models mounted on them, each of the type the muzzle holds.
/// A muzzle that names type 0 is taken as type 1, as the game does after warning about it.
///
/// Not ported: the turrets' own aiming, which the game sets up here by the part's turret kind
/// ([#71](https://github.com/vdmkenny/openreliant/issues/71)).
pub fn fit(gpa: Allocator, model: *const objects.Model) Allocator.Error![]Fitted {
    var made: std.ArrayList(Fitted) = .empty;
    errdefer made.deinit(gpa);
    try collect(gpa, &made, model);
    return made.toOwnedSlice(gpa);
}

fn collect(gpa: Allocator, made: *std.ArrayList(Fitted), model: *const objects.Model) Allocator.Error!void {
    for (model.parts) |*part| {
        for (part.attachments) |attachment| {
            if (attachment.kind != .gun_muzzle) continue;
            const kind: u8 = if (attachment.gun_type == 0 or attachment.gun_type >= max_types) 1 else @intCast(attachment.gun_type);
            try made.append(gpa, .{ .part = part, .muzzle = attachment, .type = kind });
        }
    }
    for (model.mounts) |*mount| try collect(gpa, made, &mount.model);
}

test Stats {
    var stats: Stats = .{};
    var file: [2]formats.Gun = @splat(std.mem.zeroes(formats.Gun));
    file[0].range = 1500.7;
    file[0].fire_rate = 8;
    file[0].damage = .{ 30, 40 };
    stats.load(&file);
    try std.testing.expectEqual(1500, stats.types[0].range);
    try std.testing.expectEqual(12, stats.types[0].refire_interval);
    try std.testing.expectEqual(30, stats.types[0].damage[0]);
}

test fit {
    const create = @import("create.zig");
    const gpa = std.testing.allocator;
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    // Two muzzles on the part: one that names a type, one that names none.
    var muzzles = [_]shp.Attachment{ std.mem.zeroes(shp.Attachment), std.mem.zeroes(shp.Attachment) };
    muzzles[0].kind = .gun_muzzle;
    muzzles[0].gun_type = 3;
    muzzles[1].kind = .gun_muzzle;
    muzzles[1].gun_type = 0;
    model.data[0].attachments = &muzzles;

    var live = try objects.Model.create(gpa, &model.source, &model.loaded, .{});
    defer live.deinit(gpa);
    const fitted = try fit(gpa, &live);
    defer gpa.free(fitted);
    try std.testing.expectEqual(2, fitted.len);
    try std.testing.expectEqual(3, fitted[0].type);
    // A muzzle that names no type fires type 1.
    try std.testing.expectEqual(1, fitted[1].type);
    try std.testing.expectEqual(&live.parts[0], fitted[0].part);
}

test {
    std.testing.refAllDecls(@This());
}

const Allocator = std.mem.Allocator;
const formats = @import("../../formats/stats.zig");
const objects = @import("objects.zig");
const shp = @import("../../formats/shp.zig");

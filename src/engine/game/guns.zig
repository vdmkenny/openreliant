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
    /// Which side of its group it is, 0 or 1, as `create_object` marks it from the type's groups.
    side: u8 = 0,
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

/// Gun groups a ship type holds (`0x00545900`, `0x78` bytes a type).
pub const max_groups = 20;

/// A ship type's gun group: a gun and the one nearest its mirror image across the ship, or one
/// alone.
pub const Group = struct {
    first: i16 = -1,
    second: i16 = -1,
};

/// The turret kinds `gun_groups_build` leaves out of the groups.
fn grouped(gun: Fitted) bool {
    return gun.turret != 1 and gun.turret != 3;
}

/// `gun_groups_build` (`0x004667F0`): pairs a ship type's guns into groups, each gun with the gun
/// of its own type nearest its mirror image across the ship, the closest pair first. A gun left
/// over makes a group of its own, and the gun further to the left comes first in its group.
///
/// The groups belong to the ship type, not the object: the game works them out from whichever
/// object of the type is created and keeps them in the type's table.
pub fn buildGroups(fitted: []const Fitted, groups: *[max_groups]Group) u16 {
    const Entry = struct {
        gun: u16,
        at: math.Vector,
        type: u8,
        partner: ?usize = null,
        apart: f32 = 0,
        left: bool = true,
    };
    var list: [max_groups * 2]Entry = undefined;
    var count: usize = 0;
    for (fitted, 0..) |gun, index| {
        if (!grouped(gun) or count == list.len) continue;
        list[count] = .{ .gun = @intCast(index), .at = place(gun), .type = gun.type };
        count += 1;
    }

    groups.* = @splat(.{});
    var made: u16 = 0;
    while (made < max_groups) {
        // Each gun's nearest mirror of its own type.
        for (list[0..count]) |*entry| {
            if (!entry.left) continue;
            entry.apart = std.math.floatMax(f32);
            entry.partner = null;
            for (list[0..count], 0..) |other, index| {
                if (!other.left or other.gun == entry.gun or other.type != entry.type) continue;
                var mirrored = entry.at;
                mirrored[0] = -mirrored[0];
                const apart = math.lengthSquared(mirrored - other.at);
                if (apart >= entry.apart) continue;
                entry.apart = apart;
                entry.partner = index;
            }
        }
        // The closest pair goes first.
        var nearest: ?usize = null;
        for (list[0..count], 0..) |entry, index| {
            if (!entry.left) continue;
            if (nearest == null or entry.apart < list[nearest.?].apart) nearest = index;
        }
        const first = nearest orelse return made;
        const partner = list[first].partner orelse {
            groups[made] = .{ .first = @intCast(list[first].gun) };
            list[first].left = false;
            made += 1;
            continue;
        };
        const leftmost = if (list[partner].at[0] <= list[first].at[0]) partner else first;
        const other = if (leftmost == first) partner else first;
        groups[made] = .{ .first = @intCast(list[leftmost].gun), .second = @intCast(list[other].gun) };
        list[first].left = false;
        list[partner].left = false;
        made += 1;
    }
    return made;
}

/// Where a gun sits in its object's frame: its muzzle on the part that carries it.
fn place(gun: Fitted) math.Vector {
    const at: math.Vector = .{ gun.muzzle.position.x, gun.muzzle.position.y, gun.muzzle.position.z };
    return math.transform(gun.part.object.orientation, at) + gun.part.object.position;
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

test buildGroups {
    const gpa = std.testing.allocator;
    const create = @import("create.zig");
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    // Four muzzles: a pair of type 1 either side of the nose, a pair of type 2 further out, and
    // one of type 3 on the centreline.
    const places = [_][3]f32{ .{ -100, 0, 50 }, .{ 100, 0, 50 }, .{ -300, 0, 0 }, .{ 300, 0, 0 }, .{ 0, 0, 80 } };
    const types = [_]u32{ 1, 1, 2, 2, 3 };
    var muzzles: [5]shp.Attachment = @splat(std.mem.zeroes(shp.Attachment));
    for (&muzzles, places, types) |*muzzle, at, kind| {
        muzzle.kind = .gun_muzzle;
        muzzle.position = .{ .x = at[0], .y = at[1], .z = at[2] };
        muzzle.gun_type = kind;
    }
    model.data[0].attachments = &muzzles;

    var live = try objects.Model.create(gpa, &model.source, &model.loaded, .{});
    defer live.deinit(gpa);
    live.place(@splat(0), math.identity);
    const fitted = try fit(gpa, &live);
    defer gpa.free(fitted);

    var groups: [max_groups]Group = @splat(.{});
    const made = buildGroups(fitted, &groups);
    try std.testing.expectEqual(3, made);
    // The closest mirrored pair comes first, the left gun of each pair leading.
    try std.testing.expectEqual(0, groups[0].first);
    try std.testing.expectEqual(1, groups[0].second);
    try std.testing.expectEqual(2, groups[1].first);
    try std.testing.expectEqual(3, groups[1].second);
    // The gun with nothing to mirror stands alone.
    try std.testing.expectEqual(4, groups[2].first);
    try std.testing.expectEqual(-1, groups[2].second);
}

test {
    std.testing.refAllDecls(@This());
}

const Allocator = std.mem.Allocator;
const formats = @import("../../formats/stats.zig");
const objects = @import("objects.zig");
const math = @import("../surrender/math.zig");
const shp = @import("../../formats/shp.zig");

//! `C:\lancer\game\guns.cpp`: guns. `stats_load_guns` (`0x004788F0`) fills `gun_stats` from
//! `gunstats.bin`, [`formats/stats.zig`](../../formats/stats.zig).

const std = @import("std");
const assert = std.debug.assert;

/// What a gun draws for each shot (`Gun.kind`).
pub const Kind = enum(i32) {
    /// The guns' charge, by `Gun.shot_energy`.
    energy = 0,
    /// One of the object's rounds (`GameObject.rounds`).
    rounds = 1,
    _,
};

/// One record of `gun_stats`, a gun type. The executable holds the first five words itself, the
/// rest come from `gunstats.bin` (`Stats.load`).
pub const Gun = extern struct {
    /// What a shot costs the ship.
    kind: Kind,
    /// **Unknown.** Always the same as `_unknown_08`.
    _unknown_04: f32,
    /// **Unknown.**
    _unknown_08: f32,
    /// **Unknown.** Between 50 and 1400.
    _unknown_0c: f32,
    /// The sound a shot makes (`bullet_fire`).
    sound: i32,
    /// `Gun.range`, truncated: the ticks a shot lives, which is what gives the gun its range.
    lifetime: i32,
    /// `Gun.speed`: how fast a shot flies.
    speed: f32,
    damage: [2]f32,
    /// `100 / Gun.fire_rate`, truncated: the interval between shots.
    refire_interval: i32,
    /// `Gun.shot_energy`, truncated: what a shot draws from the guns' charge, for a gun of kind
    /// `energy`.
    shot_energy: i32,

    comptime {
        assert(@offsetOf(Gun, "lifetime") == 0x14);
        assert(@offsetOf(Gun, "refire_interval") == 0x24);
        assert(@sizeOf(Gun) == 0x2C);
    }
};

/// The records of `gun_stats`. Type 0 is no gun, so `gunstats.bin`'s 15 records are the types 1
/// to 15 a muzzle can name.
pub const max_types = 16;

/// `gun_stats` (`0x00500CA4`): every gun type's figures at run time.
pub const Stats = struct {
    types: [max_types]Gun,

    /// The table as the executable holds it before `stats_load_guns` runs: each type's own words,
    /// and no figures from the file.
    pub const initial: Stats = built: {
        var table: Stats = .{ .types = @splat(std.mem.zeroes(Gun)) };
        for (&table.types, gun_stats.gun_types) |*gun, static| {
            gun.kind = static.kind;
            gun._unknown_04 = static._unknown_04;
            gun._unknown_08 = static._unknown_08;
            gun._unknown_0c = static._unknown_0c;
            gun.sound = static.sound;
        }
        break :built table;
    };

    /// `stats_load_guns` (`0x004788F0`): each record of `gunstats.bin` in turn, the first into
    /// type 1, keeping in whole numbers what the runtime's `__ftol` cuts down.
    pub fn load(stats: *Stats, file: []align(1) const formats.Gun) void {
        const count = @min(file.len, max_types - 1);
        for (stats.types[1..][0..count], file[0..count]) |*gun, record| {
            gun.lifetime = std.math.lossyCast(i32, record.range);
            gun.speed = record.speed;
            gun.damage = record.damage;
            gun.refire_interval = std.math.lossyCast(i32, formats.Gun.refire_scale / record.fire_rate);
            gun.shot_energy = std.math.lossyCast(i32, record.shot_energy);
        }
    }
};

/// One of an object's guns, as the game keeps it in the 0x60 bytes at `GameObject.guns`.
pub const Fitted = struct {
    /// The turret kind of the part it stands on (`+0x00`), or 0 for a gun that does not move.
    turret: i32 = 0,
    /// The part it fires from (`+0x04`), and where on the part.
    part: *const objects.Model.Part,
    muzzle: shp.Attachment,
    /// Its type, 1 to 15, which is the record of `Stats.types` it fires and keeps every lookup in
    /// bounds. The game keeps the record's address at `+0x08`.
    type: u4,
    /// The tick the trigger is held until (`+0x0C`): the gun fires while the frame begins before
    /// it (`fire`).
    firing_until: i32 = 0,
    /// Which side of its group it is, 0 or 1 (`+0x14`), as `create_object` marks it from the
    /// type's groups.
    side: u8 = 0,
    /// The tick it may next fire (`+0x18`).
    next_shot: i32 = 0,
    /// The steps it has been firing, over the sound's period (`gun_stats.sound_periods`), which
    /// the game keeps in its own array at `GameObject+0x138`.
    sounded: i32 = 0,
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
            const kind: u4 = if (attachment.gun_type == 0 or attachment.gun_type >= max_types) 1 else @intCast(attachment.gun_type);
            try made.append(gpa, .{ .part = part, .muzzle = attachment, .type = kind });
        }
    }
    for (model.mounts) |*mount| try collect(gpa, made, &mount.model);
}

test Stats {
    var stats: Stats = .initial;
    var file: [2]formats.Gun = @splat(std.mem.zeroes(formats.Gun));
    file[0].range = 1500.7;
    file[0].fire_rate = 8;
    file[0].damage = .{ 30, 40 };
    file[0].speed = 1200;
    file[0].shot_energy = 3.5;
    stats.load(&file);
    // The file's first record is gun type 1; type 0 stays the no gun it starts as.
    try std.testing.expectEqual(1500, stats.types[1].lifetime);
    try std.testing.expectEqual(12, stats.types[1].refire_interval);
    try std.testing.expectEqual(30, stats.types[1].damage[0]);
    try std.testing.expectEqual(1200, stats.types[1].speed);
    try std.testing.expectEqual(3, stats.types[1].shot_energy);
    try std.testing.expectEqual(0, stats.types[0].lifetime);
    // The types the executable's own words name stay as they are.
    try std.testing.expectEqual(Kind.energy, stats.types[1].kind);
    try std.testing.expectEqual(Kind.rounds, stats.types[8].kind);
}

/// Gun groups a ship type holds (`0x00545900`, `0x78` bytes a type).
pub const max_groups = 20;

/// A ship type with no guns in groups, which an object that has none points at.
pub const no_groups: [max_groups]Group = @splat(.{});

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

// --- Firing ------------------------------------------------------------------------------------

/// Simulation steps a second, which `ShipCombat.gun_recharge` is counted in (`0x004DC7F0`).
const recharge_steps: f32 = 25;

/// The gun condition a ship fires steadily at (`0x004DC470`). Below it a shot goes off only as
/// often as the condition and `condition_margin` allow.
const steady_condition: f32 = 0.9;

/// What a ship fires beyond its gun condition (`0x004DC420`).
const condition_margin: f32 = 0.1;

/// The interval between the shots of a ship aiming blind, over a hundred (`0x00477464`).
const blind_refire: i32 = 135;

/// The gun type that charges up before it fires, the Nova Cannon. The trigger passes it over: it
/// is held by `GameObject.nova_charge` instead, which isn't ported
/// ([#150](https://github.com/vdmkenny/openreliant/issues/150)).
const charging_type: u4 = 11;

const Clock = @import("main.zig").Clock;

/// A ship's guns as the trigger needs them (`fire`).
pub const Trigger = struct {
    /// Its guns (`create.Slot.guns`).
    fitted: []Fitted,
    /// Its type's gun groups (`create.Slot.gun_groups`).
    groups: *const [max_groups]Group,
    /// `frame_start`: the tick this frame began.
    frame_start: i32,
};

/// The ticks FIRE LASERS holds the trigger for (`player_controls`), so the player's guns fire
/// this frame and stop unless the key is held into the next.
pub const held_ticks: i32 = 1;

/// `object_fire_guns` (`0x0047B1F0`): holds the trigger of the guns that fire for `ticks` ticks
/// from the start of the frame. FIRE LASERS holds it for one tick, so the guns fire this frame and
/// stop unless it is held again; the mission script's Fire command holds it for longer.
///
/// With FULL GUNS every gun fires but a turret's; otherwise the two guns of the chosen group do.
/// A muzzle of the charging type is passed over either way, as is a ship whose guns are disabled.
///
/// Not ported: the charge the trigger builds up for a gun of the charging type
/// ([#150](https://github.com/vdmkenny/openreliant/issues/150)); `0x004BA780` for the player.
pub fn fire(object: *gameobj.GameObject, trigger: Trigger, ticks: i32) void {
    if (object.flags.guns_disabled or object.gun_count == 0) return;
    const until = trigger.frame_start + ticks;
    if (!object.gun_mode.all) {
        const group = trigger.groups[object.gun_mode.group];
        for ([2]i16{ group.first, group.second }) |index| {
            if (index < 0 or index >= trigger.fitted.len) continue;
            const gun = &trigger.fitted[@intCast(index)];
            if (gun.type != charging_type) gun.firing_until = until;
        }
        return;
    }
    for (trigger.fitted) |*gun| {
        if (gun.turret == 1 or gun.turret == -1 or gun.type == charging_type) continue;
        gun.firing_until = until;
    }
}

/// `guns_step` (`0x004770E0`), which `simulation_step` runs for every object after its shields
/// recharge. The guns' charge grows by `gun_energy` times the guns' share of the power and their
/// condition, over `ShipCombat.gun_recharge` seconds of steps, up to `gun_energy`, while no gun is
/// charging up. Then each gun whose trigger is held fires once its refire interval has passed, as
/// long as the ship has the charge or the rounds for it: the guns firing this step share out the
/// charge the step began with, so a ship fires none of them rather than some.
///
/// A ship whose gun condition is below `steady_condition` misfires, the more the lower it is, and
/// one aiming blind fires more slowly. While it fires one group of guns out of step, the group's
/// two guns fire in turn (`takesTurn`).
///
/// An object whose components are listed steps no guns of its own, and one that is jumping fires
/// none.
///
/// Not ported: the particles a gun of turret kind 2 puffs.
pub fn step(world: gameobj.World, clock: *const Clock, index: u16) void {
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const combat = slot.combat orelse return;
    const fitted = slot.guns;
    const groups = slot.gun_groups;
    const stats = &all.gun_stats;
    if (object.flags.components) return;
    if (object.nova_charge == 0) {
        object.gun_charge += combat.gun_energy * object.gun_factor * object.gun_condition /
            (combat.gun_recharge * recharge_steps);
    }
    if (object.gun_charge > combat.gun_energy) object.gun_charge = combat.gun_energy;

    // What the guns firing this step will draw between them.
    var needed: f32 = 0;
    for (fitted) |gun| {
        const record = stats.types[gun.type];
        if (clock.frame_start <= gun.firing_until and gun.turret == 0 and
            record.kind == .energy and gun.next_shot <= clock.frame_start)
        {
            needed += @floatFromInt(record.shot_energy);
        }
    }
    // The charge as the step began, which the guns are held against as they fire.
    const charge = object.gun_charge;
    if (object.flags.jumping) return;

    var alternated = false;
    for (fitted) |*gun| {
        if (clock.frame_start >= gun.firing_until) continue;
        const record = stats.types[gun.type];
        // The sound's turn comes round before the shot that would be heard (`heard`). Every gun
        // type's period is at least one; only type 0, which no gun has, would divide by zero.
        if (gun.turret != -1 and (record.kind == .energy or record.kind == .rounds)) {
            gun.sounded = @rem(gun.sounded + 1, @max(1, gun_stats.sound_periods[gun.type]));
        }
        if (gun.turret == 0) {
            if (gun.next_shot > clock.frame_start) continue;
            shot: {
                switch (record.kind) {
                    .energy => {
                        if (needed >= charge) break :shot;
                        if (takesTurn(object, groups, gun.*)) |takes| {
                            if (!takes) break :shot;
                            alternated = true;
                        }
                        if (!fires(world, object)) break :shot;
                        shoot(world, clock, index, gun.*);
                        object.gun_charge -= @floatFromInt(record.shot_energy);
                    },
                    .rounds => {
                        if (object.rounds <= 0) break :shot;
                        if (takesTurn(object, groups, gun.*)) |takes| {
                            if (!takes) break :shot;
                            alternated = true;
                        }
                        if (!fires(world, object)) break :shot;
                        shoot(world, clock, index, gun.*);
                        object.rounds -= 1;
                    },
                    else => {},
                }
            }
            gun.next_shot = clock.frame_start + refire(record, object.blind_fire_aim != 0);
        } else if (gun.turret == 2 and gun.next_shot <= clock.frame_start and object.rounds > 0) {
            gun.next_shot = clock.frame_start + refire(record, object.blind_fire_aim != 0);
            if (takesTurn(object, groups, gun.*)) |takes| {
                if (!takes) continue;
                alternated = true;
            }
            // Not ported: the particles the muzzle puffs (`clip_event_particles`).
            shoot(world, clock, index, gun.*);
            object.rounds -= 1;
        }
    }
    if (alternated) object.gun_turn ^= 1;
}

/// Whether a gun takes this shot, for a ship firing one group of guns out of step: the group's two
/// guns fire in turn (`GameObject.gun_turn`). Null for a ship firing every group or firing in
/// step, and for a group of one gun, none of which take turns.
fn takesTurn(object: *const gameobj.GameObject, groups: *const [max_groups]Group, gun: Fitted) ?bool {
    const mode = object.gun_mode;
    if (mode.all or mode.synchronised) return null;
    if (groups[mode.group].second < 0) return null;
    return gun.side == object.gun_turn;
}

/// Whether a shot goes off: a ship whose guns are in good condition always fires, a damaged one
/// only as often as its condition allows.
fn fires(world: gameobj.World, object: *const gameobj.GameObject) bool {
    if (object.gun_condition >= steady_condition) return true;
    const draw = @as(f32, @floatFromInt(world.random.rand())) * (1.0 / @as(f32, libcmt.Rand.max));
    return draw <= object.gun_condition + condition_margin;
}

/// The ticks between a gun's shots: a ship aiming blind fires a third again as slowly.
fn refire(record: Gun, blind: bool) i32 {
    return if (blind) @divTrunc(record.refire_interval * blind_refire, 100) else record.refire_interval;
}

/// Whether a gun's shot is heard: the player's shots all are, and another ship's one in every
/// `gun_stats.sound_periods` steps of firing. The step works this out before it advances the
/// count, so it holds for the shot the gun is about to take.
///
/// Nothing asks yet: the sound a shot makes isn't ported
/// ([#47](https://github.com/vdmkenny/openreliant/issues/47)).
pub fn heard(world: gameobj.World, owner: u16, gun: Fitted) bool {
    return owner == world.objects.player or gun.sounded == 0;
}

test fire {
    var object = gameobj.testing.object();
    var part: objects.Model.Part = undefined;
    var fitted = [_]Fitted{
        .{ .part = &part, .muzzle = std.mem.zeroes(shp.Attachment), .type = 1, .side = 0 },
        .{ .part = &part, .muzzle = std.mem.zeroes(shp.Attachment), .type = 1, .side = 1 },
        .{ .part = &part, .muzzle = std.mem.zeroes(shp.Attachment), .type = 2 },
        .{ .part = &part, .muzzle = std.mem.zeroes(shp.Attachment), .type = charging_type },
    };
    var groups: [max_groups]Group = @splat(.{});
    groups[0] = .{ .first = 0, .second = 1 };
    groups[1] = .{ .first = 2 };
    object.gun_count = fitted.len;
    const trigger: Trigger = .{ .fitted = &fitted, .groups = &groups, .frame_start = 700 };

    // Firing every group holds the trigger of every gun but the one that charges up.
    object.gun_mode = .created(2);
    fire(&object, trigger, held_ticks);
    for (fitted[0..3]) |gun| try std.testing.expectEqual(701, gun.firing_until);
    try std.testing.expectEqual(0, fitted[3].firing_until);

    // Firing one group holds only that group's guns.
    for (&fitted) |*gun| gun.firing_until = 0;
    object.gun_mode.all = false;
    object.gun_mode.group = 1;
    fire(&object, trigger, held_ticks);
    try std.testing.expectEqual(0, fitted[0].firing_until);
    try std.testing.expectEqual(701, fitted[2].firing_until);

    // A ship whose guns are disabled fires none of them.
    for (&fitted) |*gun| gun.firing_until = 0;
    object.flags.guns_disabled = true;
    fire(&object, trigger, held_ticks);
    for (fitted) |gun| try std.testing.expectEqual(0, gun.firing_until);
}

/// A world with one ship of two guns, one either side of its nose, for the tests here. Its type
/// costs 2 a shot and fires every 20 ticks.
const testing = struct {
    const gun_type: u4 = 1;
    const ship_type: u32 = 7;

    const Ship = struct {
        all: *create.Objects,
        tables: create.Stats,
        model: create.testing.Model,
        muzzles: [2]shp.Attachment,
        random: libcmt.Rand,
        controls: input.Player,
        shake: f32,
        clock: Clock,
        index: u16,

        /// Fills in every field, so a field added here has to be filled in too.
        fn init(ship: *Ship, gpa: Allocator) !void {
            ship.* = .{
                .all = try .create(gpa, &ship.random),
                .tables = create.testing.tables(),
                .model = undefined,
                .muzzles = @splat(std.mem.zeroes(shp.Attachment)),
                .random = .{},
                .controls = .{},
                .shake = 0,
                .clock = .{ .frame_start = 700, .mission_ticks = 700 },
                .index = 0,
            };
            try ship.model.init(gpa);
            for (&ship.muzzles, [_]f32{ -100, 100 }) |*muzzle, x| {
                muzzle.kind = .gun_muzzle;
                muzzle.gun_type = gun_type;
                muzzle.position = .{ .x = x, .y = 0, .z = 0 };
                muzzle.orientation = math.identity;
            }
            ship.model.data[0].attachments = &ship.muzzles;
            ship.all.gun_stats.types[gun_type].shot_energy = 2;
            ship.all.gun_stats.types[gun_type].refire_interval = 20;
            ship.all.gun_stats.types[gun_type].speed = 500;
            ship.all.gun_stats.types[gun_type].lifetime = 100;
            ship.all.gun_stats.types[gun_type].damage = .{ 10, 4 };
            ship.index = try create.createObject(ship.all, &ship.tables, ship.model.types(), null, ship_type, @splat(0), &ship.random);
            // Its guns hold 100 and charge fully in four seconds, so a step gives them one.
            ship.tables.combat[ship_type].gun_recharge = 4;
            ship.object().gun_charge = 50;
        }

        fn deinit(ship: *Ship, gpa: Allocator) void {
            ship.all.destroy();
            ship.model.deinit(gpa);
        }

        fn world(ship: *Ship) gameobj.World {
            return .{ .objects = ship.all, .player = &ship.controls, .view = .chase, .shake = &ship.shake, .random = &ship.random };
        }

        fn object(ship: *Ship) *gameobj.GameObject {
            return &ship.all.slots[ship.index].object;
        }

        fn guns(ship: *Ship) []Fitted {
            return ship.all.slots[ship.index].guns;
        }

        /// Holds both guns' triggers for the frame.
        fn hold(ship: *Ship) void {
            for (ship.guns()) |*gun| gun.firing_until = ship.clock.frame_start + 1;
        }

        /// Lets both guns fire again at once.
        fn ready(ship: *Ship) void {
            for (ship.guns()) |*gun| gun.next_shot = 0;
        }
    };
};

test step {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();
    const object = ship.object();
    try std.testing.expectEqual(2, ship.guns().len);

    // A step recharges the guns by the ship's energy over the seconds it takes, and no further
    // than full.
    step(world, &ship.clock, ship.index);
    try std.testing.expectEqual(51, object.gun_charge);
    object.gun_charge = 100;
    step(world, &ship.clock, ship.index);
    try std.testing.expectEqual(100, object.gun_charge);

    // With the trigger held both guns fire, each drawing its shot's energy, and neither fires
    // again until its interval has passed.
    object.gun_charge = 50;
    ship.hold();
    step(world, &ship.clock, ship.index);
    try std.testing.expectEqual(47, object.gun_charge);
    for (ship.guns()) |gun| try std.testing.expectEqual(ship.clock.frame_start + 20, gun.next_shot);
    // Each shot left the muzzle.
    try std.testing.expectEqual(2, flying(world));

    // Held again before the interval has passed, nothing is drawn.
    step(world, &ship.clock, ship.index);
    try std.testing.expectEqual(48, object.gun_charge);
    try std.testing.expectEqual(2, flying(world));

    // A ship that cannot pay for every gun firing this step fires none of them, but their
    // intervals still begin again.
    object.gun_charge = 3;
    ship.hold();
    ship.ready();
    step(world, &ship.clock, ship.index);
    try std.testing.expectEqual(4, object.gun_charge);
    for (ship.guns()) |gun| try std.testing.expectEqual(ship.clock.frame_start + 20, gun.next_shot);
    try std.testing.expectEqual(2, flying(world));

    // A gun that fires rounds takes one instead of the charge.
    object.gun_charge = 50;
    object.rounds = 2;
    world.objects.gun_stats.types[8] = world.objects.gun_stats.types[testing.gun_type];
    world.objects.gun_stats.types[8].kind = .rounds;
    for (ship.guns()) |*gun| gun.type = 8;
    ship.hold();
    ship.ready();
    step(world, &ship.clock, ship.index);
    try std.testing.expectEqual(0, object.rounds);
    try std.testing.expectEqual(51, object.gun_charge);

    // A ship that is jumping fires nothing, though its guns still recharge.
    for (ship.guns()) |*gun| gun.type = testing.gun_type;
    object.gun_charge = 50;
    object.flags.jumping = true;
    ship.hold();
    ship.ready();
    step(world, &ship.clock, ship.index);
    try std.testing.expectEqual(51, object.gun_charge);
    for (ship.guns()) |gun| try std.testing.expectEqual(0, gun.next_shot);

    // An object whose components are listed steps no guns of its own, and one charging up a gun
    // recharges none. Neither is holding a trigger.
    object.flags.jumping = false;
    for (ship.guns()) |*gun| gun.firing_until = 0;
    object.gun_charge = 50;
    object.flags.components = true;
    step(world, &ship.clock, ship.index);
    try std.testing.expectEqual(50, object.gun_charge);
    object.flags.components = false;
    object.nova_charge = 0.5;
    step(world, &ship.clock, ship.index);
    try std.testing.expectEqual(50, object.gun_charge);
}

/// How many shots are in flight.
fn flying(world: gameobj.World) usize {
    var count: usize = 0;
    for (world.objects.bullets.pool) |bullet| {
        if (bullet.live) count += 1;
    }
    return count;
}

test "a group's two guns fire in turn while the ship fires out of step" {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();
    const object = ship.object();
    object.gun_mode.synchronised = false;
    ship.hold();

    // The ship's turn is the first gun's side, so only that gun fires, and the turn passes.
    step(world, &ship.clock, ship.index);
    try std.testing.expectEqual(49, object.gun_charge);
    try std.testing.expectEqual(1, object.gun_turn);

    // The other gun fires next time round.
    object.gun_charge = 50;
    ship.hold();
    ship.ready();
    step(world, &ship.clock, ship.index);
    try std.testing.expectEqual(49, object.gun_charge);
    try std.testing.expectEqual(0, object.gun_turn);
}

test "a ship aiming blind fires more slowly" {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    ship.object().blind_fire_aim = 1;
    ship.hold();
    step(ship.world(), &ship.clock, ship.index);
    for (ship.guns()) |gun| try std.testing.expectEqual(ship.clock.frame_start + 27, gun.next_shot);
}

test fires {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();
    const object = ship.object();

    // Guns in good condition always fire, and draw no number to decide it.
    const before = ship.random;
    for (0..8) |_| try std.testing.expect(fires(world, object));
    try std.testing.expectEqual(before, ship.random);

    // Half wrecked guns fire some of the time.
    object.gun_condition = 0.5;
    var shots: usize = 0;
    for (0..100) |_| {
        if (fires(world, object)) shots += 1;
    }
    try std.testing.expect(shots > 0 and shots < 100);
}

test heard {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    var gun = ship.guns()[0];
    gun.sounded = 2;
    // Every one of the player's shots is heard; another ship's only as its count comes round.
    try std.testing.expect(heard(ship.world(), ship.all.player, gun));
    try std.testing.expect(!heard(ship.world(), ship.index + 1, gun));
}

// --- Bullets -----------------------------------------------------------------------------------

/// The shots in flight (`0x00563148`): the game keeps 200 records of `0xC4` bytes and links the
/// live ones into a list, newest first; the port keeps the same 200 and walks them in order, which
/// tells only in which order two shots that land on one object in a frame are dealt with.
pub const max_bullets = 200;

/// The objects one shot is tested against (`bullet_place`).
pub const max_candidates = 20;

/// What a shot's `dies_at` becomes once it has struck something: the frame that follows frees it.
pub const spent: i32 = -1;

/// An object a shot may reach, and which of its components, as `bullet_place` leaves it.
pub const Candidate = struct {
    /// The object's slot.
    object: u16 = 0,
    /// Its component, or `no_component` for an object whose components are not listed.
    component: u16 = no_component,
};

/// What a candidate's component holds where the object has none.
pub const no_component: u16 = 0xFFFF;

/// One shot in flight, as the game keeps it in the `0xC4` bytes of a pool record.
pub const Bullet = struct {
    /// Whether the record is in use.
    live: bool = false,
    /// Its gun type less one (`+0x00`), so `Stats.types[kind + 1]` holds its figures. The game
    /// counts the types from zero here and from one in `gun_stats`.
    kind: u4 = 0,
    /// The tick it dies (`+0x04`), which is `spent` once it has struck something.
    dies_at: i32 = 0,
    /// The tick it was fired (`+0x08`).
    fired_at: i32 = 0,
    /// Where it stood at the frame before (`+0x10`), and where it stands now (`+0x1C`). The frame
    /// pass tests what lies between the two.
    last: Vector = @splat(0),
    at: Vector = @splat(0),
    /// How far it flies each simulation step (`+0x28`).
    velocity: Vector = @splat(0),
    /// The slot that fired it (`+0x34`), which the damage is charged to.
    owner: u16 = 0,
    /// That ship's side (`+0x38`).
    side: gameobj.Side(i32) = .neutral,
    /// The objects it may reach (`+0x68`), as many as `candidate_count` (`+0x64`).
    candidates: [max_candidates]Candidate = @splat(.{}),
    candidate_count: u8 = 0,

    /// Its type's figures.
    pub fn stats(bullet: Bullet, table: *const Stats) Gun {
        return table.types[@as(u8, bullet.kind) + 1];
    }
};

/// The pool of shots (`0x00563148`).
pub const Bullets = struct {
    pool: [max_bullets]Bullet = @splat(.{}),

    /// The first free record, as `bullet_fire` takes it, or null while every one is in flight.
    fn free(bullets: *Bullets) ?*Bullet {
        for (&bullets.pool) |*bullet| if (!bullet.live) return bullet;
        return null;
    }
};

/// `bullet_fire` (`0x0047C5F0`) with `bullet_place` (`0x0047BDB0`): the shot a gun takes. It
/// leaves the muzzle where the step is taking it, flying along the muzzle's nose at the type's
/// speed, and lives for the type's `lifetime` ticks. Nothing is fired while every record is in
/// flight.
///
/// The shot is given the objects it may reach on its way: any object whose radius, widened by how
/// far it could travel meanwhile, the shot's path comes within. The frame pass tests only those
/// (`bulletHit`).
///
/// Not ported: how the shot is drawn and lit ([#154](https://github.com/vdmkenny/openreliant/issues/154)),
/// its sound ([#47](https://github.com/vdmkenny/openreliant/issues/47)), the force feedback a
/// player's shot gives ([#83](https://github.com/vdmkenny/openreliant/issues/83)), the aim a ship
/// firing blind takes at its target, and the scatter of gun type 12.
pub fn shoot(world: gameobj.World, clock: *const Clock, owner: u16, gun: Fitted) void {
    const all = world.objects;
    const slot = &all.slots[owner];
    const model = if (slot.model) |*live| live else return;
    const record = world.objects.gun_stats.types[gun.type];
    const bullet = all.bullets.free() orelse return;

    // The muzzle stands where the step is taking the ship, on the part that carries it.
    model.place(gameobj.vector(slot.object.root.next_position), slot.object.root.next_orientation);
    const part = gun.part.object;
    const at = math.transform(part.orientation, gameobj.vector(gun.muzzle.position)) + part.position;
    const turn = math.product(part.orientation, gun.muzzle.orientation);

    bullet.* = .{
        .live = true,
        .kind = @intCast(gun.type - 1),
        .dies_at = clock.mission_ticks + record.lifetime,
        .fired_at = clock.mission_ticks,
        .last = at,
        .at = at,
        .velocity = math.transform(turn, .{ 0, 0, record.speed }),
        .owner = owner,
        .side = slot.object.side,
    };
    candidates(world, bullet, record);
}

/// The objects `bullet_place` gives a new shot: those its path comes near enough to over its life,
/// widened by how far each could move meanwhile. An object whose components are listed is tested
/// part by part, so each part it could reach is its own candidate.
///
/// Not ported: the parts, which `object_hit_test` picks for an object whose components are listed
/// ([#40](https://github.com/vdmkenny/openreliant/issues/40)); such an object is taken whole here.
fn candidates(world: gameobj.World, bullet: *Bullet, record: Gun) void {
    const all = world.objects;
    if (record.speed <= 0) return;
    const along = 1 / (record.speed * record.speed);
    const life: f32 = @floatFromInt(record.lifetime);
    var walk = all.walk();
    while (walk.next()) |index| {
        if (bullet.candidate_count == max_candidates) return;
        const slot = &all.slots[index];
        const object = &slot.object;
        if (object.type >= create.ship_type_count or object.flags.no_collisions) continue;
        if (index == bullet.owner) continue;
        const to = gameobj.vector(object.root.next_position) - bullet.at;
        const when = std.math.clamp(math.dot(to, bullet.velocity) * along, 0, life);
        const nearest = bullet.velocity * @as(Vector, @splat(when));
        const moving = if (slot.flight) |flight| ai.cruiseSpeed(object, flight, world.view) else 0;
        const reach = moving * when + object.radius;
        if (math.lengthSquared(nearest - to) >= reach * reach) continue;
        bullet.candidates[bullet.candidate_count] = .{ .object = index };
        bullet.candidate_count += 1;
    }
}

/// What a turret's shot does to a player's ship, over what it does to any other (`0x004DC59C`).
const turret_damage_to_players: f32 = 2.5;

/// Whether the shot came from a turret's gun, which hits a player's ship harder. A shot keeps its
/// type less one, so these are types 12 and 13, the two the turrets fire.
fn fromTurret(kind: u4) bool {
    return kind == 11 or kind == 12;
}

/// `0x0047A4E0`, which `simulation_step` runs after the objects move: every shot flies on by its
/// velocity.
pub fn moveBullets(world: gameobj.World) void {
    for (&world.objects.bullets.pool) |*bullet| {
        if (!bullet.live) continue;
        bullet.at += bullet.velocity;
    }
}

/// The work of `0x0047A510` once a frame, after the objects are framed: each shot is tested
/// against the objects it may reach, and one that is spent or out of life is let go. A shot that
/// has struck something is tested no further.
///
/// Not ported: how the shots are drawn, their colours fading with their life, and the lights they
/// carry ([#154](https://github.com/vdmkenny/openreliant/issues/154)); the sparks and sounds an
/// impact makes ([#41](https://github.com/vdmkenny/openreliant/issues/41)); what multiplayer makes
/// of a hit.
pub fn bulletsFrame(world: gameobj.World, clock: *const Clock) void {
    for (&world.objects.bullets.pool) |*bullet| {
        if (!bullet.live) continue;
        if (clock.frame_start < bullet.dies_at) {
            if (bullet.candidate_count > 0) bulletHit(world, bullet);
            // A hit marks it spent, which frees it below rather than flying on.
            if (clock.frame_start < bullet.dies_at) {
                bullet.last = bullet.at;
                continue;
            }
        }
        bullet.* = .{};
    }
}

/// `0x00479B40`: what a shot strikes between where it stood last frame and where it stands now. It
/// tests only the objects it was given when it was fired, and drops any it has already flown past.
///
/// An object is struck where the segment first crosses the sphere of its radius. With a shield up
/// in that quadrant the shot spends itself on the shield (`object_damage` with the type's first
/// damage, and its second over its first as the share that passes through); with the shield down
/// the shot reaches the hull (`hullHit`). What the player has shifted fore or aft takes the hit
/// before the quadrant does, and a turret's shot hurts a player's ship more. A ship with its
/// spectral shields on takes nothing at all: the gun type they are tuned to is handed to the check
/// and ignored, so every shot is turned.
///
/// Not ported: the parts of an object whose components are listed, which the game tests node by
/// node ([#40](https://github.com/vdmkenny/openreliant/issues/40)); the cloak a hit reveals; the
/// shield's flash.
fn bulletHit(world: gameobj.World, bullet: *Bullet) void {
    const all = world.objects;
    const span = bullet.at - bullet.last;
    const length = math.lengthSquared(span);
    if (length < 1) return;
    const along = 1 / length;
    const record = bullet.stats(&world.objects.gun_stats);

    var index: usize = 0;
    while (index < bullet.candidate_count) {
        const candidate = bullet.candidates[index];
        const slot = &all.slots[candidate.object];
        const object = &slot.object;
        if (object.type >= create.ship_type_count) {
            index += 1;
            continue;
        }
        const to = slot.drawn.position - bullet.last;
        const when = std.math.clamp(math.dot(span, to) * along, 0, 1);
        const nearest = span * @as(Vector, @splat(when));
        const reach = object.radius;
        if (math.lengthSquared(nearest - to) > reach * reach) {
            // Once the shot is past an object it is dropped from the list.
            if (when == 0) {
                var from = index;
                while (from + 1 < bullet.candidate_count) : (from += 1) bullet.candidates[from] = bullet.candidates[from + 1];
                bullet.candidate_count -= 1;
                continue;
            }
            index += 1;
            continue;
        }
        // An object whose components are listed is not tested part by part yet.
        if (object.flags.components) {
            index += 1;
            continue;
        }
        // Where the segment first crosses the object's sphere.
        const a = math.dot(span, span);
        const b = math.dot(span, to) * -2;
        const c = math.dot(to, to) - reach * reach;
        const root = @sqrt(@max(b * b - 4 * a * c, 0));
        const point = bullet.last + span * @as(Vector, @splat((-b - root) / (a + a)));
        const struck = collision.quadrant(object, math.transformTransposed(slot.drawn.orientation, point - slot.drawn.position));

        if (object.shields[@intFromEnum(struck)] <= 0 or object.invulnerable == 4 or object.invulnerable == 5) {
            hullHit(world, bullet, candidate.object, struck);
            return;
        }
        if (!object.flags.spectral_shields and record.damage[0] > 0) {
            var value = record.damage[0];
            // What the player has shifted fore or aft takes the hit before the quadrant does, and
            // a hit it swallows whole leaves the shields alone.
            const reserve: ?*f32 = if (candidate.object != all.player) null else switch (struck) {
                .fore => &world.player.shield_reserves.fore,
                .aft => &world.player.shield_reserves.aft,
                else => null,
            };
            if (reserve) |shifted| {
                if (shifted.* > 0) {
                    shifted.* -= value;
                    if (shifted.* > 0) {
                        bullet.dies_at = spent;
                        return;
                    }
                    shifted.* = 0;
                }
            }
            if (candidate.object < all.players and fromTurret(bullet.kind)) value *= turret_damage_to_players;
            collision.damage(world, candidate.object, struck, value, record.damage[1] / record.damage[0], bullet.owner, .bullet);
        }
        bullet.dies_at = spent;
        return;
    }
}

/// `0x00479940`: a shot that has passed an object's shields. It finds the first of the object's
/// parts the segment crosses, by the box each part's mesh stands in, and wears the quadrant's
/// armour by the type's second damage.
///
/// Not ported: the sparks the impact throws and its sound
/// ([#41](https://github.com/vdmkenny/openreliant/issues/41)).
fn hullHit(world: gameobj.World, bullet: *Bullet, index: u16, struck: collision.Quadrant) void {
    const all = world.objects;
    const model = if (all.slots[index].model) |*live| live else return;
    if (!crossesPart(model, bullet.last, bullet.at)) return;
    const record = bullet.stats(&world.objects.gun_stats);
    var value = record.damage[1];
    if (index < all.players and fromTurret(bullet.kind)) value *= turret_damage_to_players;
    collision.armorDamage(world, index, struck, value, bullet.owner, .bullet);
    bullet.dies_at = spent;
}

/// Whether the segment from `from` to `to` crosses the box any of the model's parts stands in,
/// which is how `0x00479940` finds what a shot has hit.
fn crossesPart(model: *const objects.Model, from: Vector, to: Vector) bool {
    for (model.parts) |*part| {
        if (part.hidden) continue;
        if (part.object.levels.len == 0) continue;
        const mesh = part.object.levels[0].mesh;
        // The segment in the part's own frame, where its mesh's box stands.
        const start = math.transformTransposed(part.object.orientation, from - part.object.position);
        const end = math.transformTransposed(part.object.orientation, to - part.object.position);
        if (crossesBox(start, end, mesh.bounds)) return true;
    }
    return false;
}

/// Whether a segment meets a box (`0x0049B6A0`), by the slab test.
fn crossesBox(from: Vector, to: Vector, bounds: [2]Vector) bool {
    var near: f32 = 0;
    var far: f32 = 1;
    const span = to - from;
    inline for (0..3) |axis| {
        if (span[axis] == 0) {
            if (from[axis] < bounds[0][axis] or from[axis] > bounds[1][axis]) return false;
        } else {
            const first = (bounds[0][axis] - from[axis]) / span[axis];
            const second = (bounds[1][axis] - from[axis]) / span[axis];
            near = @max(near, @min(first, second));
            far = @min(far, @max(first, second));
            if (near > far) return false;
        }
    }
    return true;
}

test shoot {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();

    shoot(world, &ship.clock, ship.index, ship.guns()[0]);
    try std.testing.expectEqual(1, flying(world));
    const bullet = &world.objects.bullets.pool[0];
    // It leaves the muzzle, a hundred to the left of the ship's nose, flying along that nose at
    // the type's speed, and lives for the type's ticks.
    try std.testing.expectEqual(@as(Vector, .{ -100, 0, 0 }), bullet.at);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 500 }), bullet.velocity);
    try std.testing.expectEqual(ship.clock.mission_ticks + 100, bullet.dies_at);
    try std.testing.expectEqual(ship.clock.mission_ticks, bullet.fired_at);
    try std.testing.expectEqual(ship.index, bullet.owner);
    // The record keeps the type less one, as the game does.
    try std.testing.expectEqual(testing.gun_type - 1, bullet.kind);

    // A shot flies on by its velocity each step.
    moveBullets(world);
    try std.testing.expectEqual(@as(Vector, .{ -100, 0, 500 }), bullet.at);

    // Nothing is fired once every record is in flight.
    for (&world.objects.bullets.pool) |*record| record.live = true;
    shoot(world, &ship.clock, ship.index, ship.guns()[0]);
    try std.testing.expectEqual(max_bullets, flying(world));
}

test bulletsFrame {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();

    // A ship of the same model, 500 ahead of the one that fires.
    const target = try create.createObject(ship.all, &ship.tables, ship.model.types(), null, 9, .{ 0, 0, 500 }, &ship.random);
    const slot = &ship.all.slots[target];
    slot.drawn = .{ .position = .{ 0, 0, 500 }, .orientation = math.identity };
    const struck = &slot.object;

    // A shot whose path crosses the ship: its shields take the type's first damage, and it is
    // spent.
    shoot(world, &ship.clock, ship.index, ship.guns()[0]);
    const bullet = &world.objects.bullets.pool[0];
    try std.testing.expectEqual(1, bullet.candidate_count);
    try std.testing.expectEqual(target, bullet.candidates[0].object);
    bullet.last = .{ 0, 0, 0 };
    bullet.at = .{ 0, 0, 600 };
    bulletsFrame(world, &ship.clock);
    try std.testing.expectEqual(10, struck.recent_damage);
    try std.testing.expectEqual(0, flying(world));

    // With its shields down the next shot reaches the hull, which takes the second damage.
    struck.shields = @splat(0);
    struck.recent_damage = 0;
    const armor = struck.armor;
    shoot(world, &ship.clock, ship.index, ship.guns()[0]);
    const next = &world.objects.bullets.pool[0];
    next.last = .{ 0, 0, 0 };
    next.at = .{ 0, 0, 600 };
    bulletsFrame(world, &ship.clock);
    try std.testing.expectEqual(4, struck.recent_damage);
    try std.testing.expect(@reduce(.Add, @as(@Vector(4, f32), armor)) > @reduce(.Add, @as(@Vector(4, f32), struck.armor)));
    try std.testing.expectEqual(0, flying(world));

    // A shot that reaches the end of its life is let go.
    shoot(world, &ship.clock, ship.index, ship.guns()[0]);
    try std.testing.expectEqual(1, flying(world));
    ship.clock.frame_start += 1000;
    bulletsFrame(world, &ship.clock);
    try std.testing.expectEqual(0, flying(world));
}

test "the player's shifted shields take a hit before the quadrant does" {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();
    // The ship that fires is the player's, so the target here is another slot shooting back.
    const shooter = try create.createObject(ship.all, &ship.tables, ship.model.types(), null, 9, .{ 0, 0, 500 }, &ship.random);
    const player = &ship.all.slots[ship.all.player];
    player.drawn = .{ .position = @splat(0), .orientation = math.identity };
    ship.controls.shield_reserves = .{ .fore = 25, .aft = 0 };

    // A shot into the player's fore quadrant comes off the reserve, and the shields are untouched.
    shoot(world, &ship.clock, shooter, ship.all.slots[shooter].guns[0]);
    const bullet = &world.objects.bullets.pool[0];
    bullet.last = .{ 0, 0, 500 };
    bullet.at = .{ 0, 0, -100 };
    bullet.candidates[0] = .{ .object = ship.all.player };
    bullet.candidate_count = 1;
    const shields = player.object.shields;
    bulletsFrame(world, &ship.clock);
    try std.testing.expectEqual(15, ship.controls.shield_reserves.fore);
    try std.testing.expectEqual(shields, player.object.shields);
}

test crossesBox {
    const bounds: [2]Vector = .{ .{ -10, -10, -10 }, .{ 10, 10, 10 } };
    // Through the middle, from a corner, and ending inside.
    try std.testing.expect(crossesBox(.{ 0, 0, -50 }, .{ 0, 0, 50 }, bounds));
    try std.testing.expect(crossesBox(.{ -50, -50, -50 }, .{ 50, 50, 50 }, bounds));
    try std.testing.expect(crossesBox(.{ 0, 0, -50 }, .{ 0, 0, 0 }, bounds));
    // Past it, short of it, and alongside it.
    try std.testing.expect(!crossesBox(.{ 50, 0, -50 }, .{ 50, 0, 50 }, bounds));
    try std.testing.expect(!crossesBox(.{ 0, 0, -50 }, .{ 0, 0, -20 }, bounds));
    try std.testing.expect(!crossesBox(.{ 0, 20, -50 }, .{ 0, 20, 50 }, bounds));
}

test {
    std.testing.refAllDecls(@This());
}

const Allocator = std.mem.Allocator;
const ai = @import("ai.zig");
const collision = @import("collision.zig");
const create = @import("create.zig");
const formats = @import("../../formats/stats.zig");
const gameobj = @import("gameobj.zig");
const gun_stats = @import("guns/stats.zig");
const libcmt = @import("../libcmt.zig");
const input = @import("../input.zig");
const objects = @import("objects.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const shp = @import("../../formats/shp.zig");

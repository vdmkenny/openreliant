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

/// What the guns' step works on besides the object and its guns, which the game keeps in globals.
pub const Context = struct {
    /// Every gun type's figures (`gun_stats`).
    stats: *const Stats,
    /// `frame_start`: the tick this frame began.
    frame_start: i32,
    /// The runtime's numbers, which decide whether a damaged gun misfires.
    random: *libcmt.Rand,
    /// Whether it is the player's ship, whose every shot is heard.
    player: bool = false,
};

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
/// Not ported: the shot itself (`bullet_fire`, `0x0047C5F0`,
/// [#151](https://github.com/vdmkenny/openreliant/issues/151)), so firing costs the ship its
/// charge or a round and nothing leaves the muzzle; the particles a gun of turret kind 2 puffs.
pub fn step(ctx: Context, object: *gameobj.GameObject, combat: *const create.ShipCombat, fitted: []Fitted, groups: *const [max_groups]Group) void {
    if (object.flags.components) return;
    if (object.nova_charge == 0) {
        object.gun_charge += combat.gun_energy * object.gun_factor * object.gun_condition /
            (combat.gun_recharge * recharge_steps);
    }
    if (object.gun_charge > combat.gun_energy) object.gun_charge = combat.gun_energy;

    // What the guns firing this step will draw between them.
    var needed: f32 = 0;
    for (fitted) |gun| {
        const record = ctx.stats.types[gun.type];
        if (ctx.frame_start <= gun.firing_until and gun.turret == 0 and
            record.kind == .energy and gun.next_shot <= ctx.frame_start)
        {
            needed += @floatFromInt(record.shot_energy);
        }
    }
    // The charge as the step began, which the guns are held against as they fire.
    const charge = object.gun_charge;
    if (object.flags.jumping) return;

    var alternated = false;
    for (fitted) |*gun| {
        if (ctx.frame_start >= gun.firing_until) continue;
        const record = ctx.stats.types[gun.type];
        // The sound's turn comes round before the shot that would be heard (`heard`). Every gun
        // type's period is at least one; only type 0, which no gun has, would divide by zero.
        if (gun.turret != -1 and (record.kind == .energy or record.kind == .rounds)) {
            gun.sounded = @rem(gun.sounded + 1, @max(1, gun_stats.sound_periods[gun.type]));
        }
        if (gun.turret == 0) {
            if (gun.next_shot > ctx.frame_start) continue;
            shot: {
                switch (record.kind) {
                    .energy => {
                        if (needed >= charge) break :shot;
                        if (takesTurn(object, groups, gun.*)) |takes| {
                            if (!takes) break :shot;
                            alternated = true;
                        }
                        if (!fires(ctx, object)) break :shot;
                        // Not ported: the shot.
                        object.gun_charge -= @floatFromInt(record.shot_energy);
                    },
                    .rounds => {
                        if (object.rounds <= 0) break :shot;
                        if (takesTurn(object, groups, gun.*)) |takes| {
                            if (!takes) break :shot;
                            alternated = true;
                        }
                        if (!fires(ctx, object)) break :shot;
                        // Not ported: the shot.
                        object.rounds -= 1;
                    },
                    else => {},
                }
            }
            gun.next_shot = ctx.frame_start + refire(record, object.blind_fire_aim != 0);
        } else if (gun.turret == 2 and gun.next_shot <= ctx.frame_start and object.rounds > 0) {
            gun.next_shot = ctx.frame_start + refire(record, object.blind_fire_aim != 0);
            if (takesTurn(object, groups, gun.*)) |takes| {
                if (!takes) continue;
                alternated = true;
            }
            // Not ported: the shot, and the particles the muzzle puffs (`clip_event_particles`).
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
fn fires(ctx: Context, object: *const gameobj.GameObject) bool {
    if (object.gun_condition >= steady_condition) return true;
    const draw = @as(f32, @floatFromInt(ctx.random.rand())) * (1.0 / @as(f32, libcmt.Rand.max));
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
/// Nothing asks yet: the shot that would carry the sound isn't ported
/// ([#151](https://github.com/vdmkenny/openreliant/issues/151)).
pub fn heard(ctx: Context, gun: Fitted) bool {
    return ctx.player or gun.sounded == 0;
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

/// Two guns of type 1, one either side of a ship, and a gun type that costs 2 a shot and fires
/// every 20 ticks.
const testing = struct {
    fn stats() Stats {
        var table: Stats = .initial;
        table.types[1].shot_energy = 2;
        table.types[1].refire_interval = 20;
        table.types[8].shot_energy = 0;
        table.types[8].refire_interval = 20;
        return table;
    }

    fn pair(part: *const objects.Model.Part) [2]Fitted {
        return .{
            .{ .part = part, .muzzle = std.mem.zeroes(shp.Attachment), .type = 1, .side = 0 },
            .{ .part = part, .muzzle = std.mem.zeroes(shp.Attachment), .type = 1, .side = 1 },
        };
    }

    /// A ship whose guns are charged and whole, holding the trigger for the frame at 700.
    fn ship() gameobj.GameObject {
        var object = gameobj.testing.object();
        object.gun_charge = 50;
        object.gun_factor = 1;
        object.gun_condition = 1;
        object.gun_count = 2;
        object.gun_mode = .created(1);
        return object;
    }

    const combat = std.mem.zeroInit(create.ShipCombat, .{ .gun_energy = 100, .gun_recharge = 4 });
    const frame_start: i32 = 700;
};

test step {
    var random: libcmt.Rand = .{};
    var table = testing.stats();
    const ctx: Context = .{ .stats = &table, .frame_start = testing.frame_start, .random = &random };
    var groups: [max_groups]Group = @splat(.{});
    groups[0] = .{ .first = 0, .second = 1 };
    var part: objects.Model.Part = undefined;

    // A step recharges the guns by the ship's energy over the seconds it takes, and no further
    // than full.
    var object = testing.ship();
    var fitted = testing.pair(&part);
    step(ctx, &object, &testing.combat, &fitted, &groups);
    try std.testing.expectEqual(51, object.gun_charge);
    object.gun_charge = 100;
    step(ctx, &object, &testing.combat, &fitted, &groups);
    try std.testing.expectEqual(100, object.gun_charge);

    // With the trigger held both guns fire, each drawing its shot's energy, and neither fires
    // again until its interval has passed.
    object = testing.ship();
    for (&fitted) |*gun| gun.firing_until = testing.frame_start + 1;
    step(ctx, &object, &testing.combat, &fitted, &groups);
    try std.testing.expectEqual(47, object.gun_charge);
    for (fitted) |gun| try std.testing.expectEqual(testing.frame_start + 20, gun.next_shot);

    // Held again before the interval has passed, nothing is drawn.
    step(ctx, &object, &testing.combat, &fitted, &groups);
    try std.testing.expectEqual(48, object.gun_charge);

    // A ship that cannot pay for every gun firing this step fires none of them, but their
    // intervals still begin again.
    object = testing.ship();
    object.gun_charge = 3;
    for (&fitted) |*gun| {
        gun.firing_until = testing.frame_start + 1;
        gun.next_shot = 0;
    }
    step(ctx, &object, &testing.combat, &fitted, &groups);
    try std.testing.expectEqual(4, object.gun_charge);
    for (fitted) |gun| try std.testing.expectEqual(testing.frame_start + 20, gun.next_shot);

    // A gun that fires rounds takes one instead of the charge.
    object = testing.ship();
    object.rounds = 2;
    for (&fitted) |*gun| {
        gun.type = 8;
        gun.firing_until = testing.frame_start + 1;
        gun.next_shot = 0;
    }
    step(ctx, &object, &testing.combat, &fitted, &groups);
    try std.testing.expectEqual(0, object.rounds);
    try std.testing.expectEqual(51, object.gun_charge);

    // A ship that is jumping fires nothing, though its guns still recharge.
    object = testing.ship();
    object.flags.jumping = true;
    fitted = testing.pair(&part);
    for (&fitted) |*gun| gun.firing_until = testing.frame_start + 1;
    step(ctx, &object, &testing.combat, &fitted, &groups);
    try std.testing.expectEqual(51, object.gun_charge);
    for (fitted) |gun| try std.testing.expectEqual(0, gun.next_shot);

    // An object whose components are listed steps no guns of its own, and one charging up a gun
    // recharges none. Neither is holding a trigger.
    for (&fitted) |*gun| gun.firing_until = 0;
    object = testing.ship();
    object.flags.components = true;
    step(ctx, &object, &testing.combat, &fitted, &groups);
    try std.testing.expectEqual(50, object.gun_charge);
    object.flags.components = false;
    object.nova_charge = 0.5;
    step(ctx, &object, &testing.combat, &fitted, &groups);
    try std.testing.expectEqual(50, object.gun_charge);
}

test "a group's two guns fire in turn while the ship fires out of step" {
    var random: libcmt.Rand = .{};
    var table = testing.stats();
    const ctx: Context = .{ .stats = &table, .frame_start = testing.frame_start, .random = &random };
    var groups: [max_groups]Group = @splat(.{});
    groups[0] = .{ .first = 0, .second = 1 };
    var part: objects.Model.Part = undefined;
    var fitted = testing.pair(&part);

    var object = testing.ship();
    object.gun_mode.synchronised = false;
    for (&fitted) |*gun| gun.firing_until = testing.frame_start + 1;
    // The ship's turn is the first gun's side, so only that gun fires, and the turn passes.
    step(ctx, &object, &testing.combat, &fitted, &groups);
    try std.testing.expectEqual(49, object.gun_charge);
    try std.testing.expectEqual(1, object.gun_turn);

    // The other gun fires next time round.
    for (&fitted) |*gun| {
        gun.firing_until = testing.frame_start + 1;
        gun.next_shot = 0;
    }
    object.gun_charge = 50;
    step(ctx, &object, &testing.combat, &fitted, &groups);
    try std.testing.expectEqual(49, object.gun_charge);
    try std.testing.expectEqual(0, object.gun_turn);
}

test "a ship aiming blind fires more slowly" {
    var random: libcmt.Rand = .{};
    var table = testing.stats();
    const ctx: Context = .{ .stats = &table, .frame_start = testing.frame_start, .random = &random };
    var groups: [max_groups]Group = @splat(.{});
    groups[0] = .{ .first = 0, .second = 1 };
    var part: objects.Model.Part = undefined;
    var fitted = testing.pair(&part);

    var object = testing.ship();
    object.blind_fire_aim = 1;
    for (&fitted) |*gun| gun.firing_until = testing.frame_start + 1;
    step(ctx, &object, &testing.combat, &fitted, &groups);
    for (fitted) |gun| try std.testing.expectEqual(testing.frame_start + 27, gun.next_shot);
}

test fires {
    var random: libcmt.Rand = .{};
    var table = testing.stats();
    const ctx: Context = .{ .stats = &table, .frame_start = testing.frame_start, .random = &random };
    var object = testing.ship();

    // Guns in good condition always fire, and draw no number to decide it.
    for (0..8) |_| try std.testing.expect(fires(ctx, &object));
    try std.testing.expectEqual(libcmt.Rand{}, random);

    // Half wrecked guns fire some of the time.
    object.gun_condition = 0.5;
    var shots: usize = 0;
    for (0..100) |_| {
        if (fires(ctx, &object)) shots += 1;
    }
    try std.testing.expect(shots > 0 and shots < 100);
}

test heard {
    var random: libcmt.Rand = .{};
    var table = testing.stats();
    var part: objects.Model.Part = undefined;
    const gun: Fitted = .{ .part = &part, .muzzle = std.mem.zeroes(shp.Attachment), .type = 1, .sounded = 2 };
    // Every one of the player's shots is heard; another ship's only as its count comes round.
    try std.testing.expect(heard(.{ .stats = &table, .frame_start = 0, .random = &random, .player = true }, gun));
    try std.testing.expect(!heard(.{ .stats = &table, .frame_start = 0, .random = &random }, gun));
}

test {
    std.testing.refAllDecls(@This());
}

const Allocator = std.mem.Allocator;
const create = @import("create.zig");
const formats = @import("../../formats/stats.zig");
const gameobj = @import("gameobj.zig");
const gun_stats = @import("guns/stats.zig");
const libcmt = @import("../libcmt.zig");
const objects = @import("objects.zig");
const math = @import("../surrender/math.zig");
const shp = @import("../../formats/shp.zig");

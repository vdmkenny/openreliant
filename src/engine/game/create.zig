//! `C:\lancer\game\Create.cpp`: creating live objects. `create_object` (`0x00466C10`) fills a slot
//! of `game_objects`, which the port keeps in `Objects`, with an object of a ship type, and
//! `objects_reset` (`0x00466630`) fills every slot with a stand-in as a mission starts.
//! `stats_load_ships` (`0x00466500`) fills `ship_flight_stats` and `ship_combat_stats` from
//! `shipstats.bin`, [`formats/stats.zig`](../../formats/stats.zig).
//! [`create/models.zig`](create/models.zig) names each ship type's and attachment's models, and
//! [`create/combat.zig`](create/combat.zig) holds the combat stats' words that the executable
//! keeps. **Unverified:** the loader, `objects_reset`, `ship_type_load` and the ship type table lie
//! between `collision.cpp`'s code and data and this file's, and `object_reset` and
//! `objects_update` after this file's known code, before `environfx.cpp`'s.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const engine = @import("../../engine.zig");
const shp = @import("../../formats/shp.zig");
const stats = @import("../../formats/stats.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const Pointer = engine.Pointer;
const libcmt = @import("../libcmt.zig");
const ai = @import("ai.zig");
const camera = @import("camera.zig");
const gameobj = @import("gameobj.zig");
const GameObject = gameobj.GameObject;
const main = @import("main.zig");
const motion = @import("motion.zig");
const objects = @import("objects.zig");
const pilots = @import("pilots.zig");
const srofiles = @import("srofiles.zig");
const xtrabits = @import("xtrabits.zig");

pub const models = @import("create/models.zig");
pub const combat_stats = @import("create/combat.zig");

/// Ship types: the records of `shipstats.bin`, and the entries of the tables they index. Types
/// above the last, markers and nav points among them, have no stats.
pub const ship_type_count = 256;

/// `ship_flight_stats` and `ship_combat_stats` (`0x004FC670`): each ship type's flight model and
/// combat stats, which `create_object` points each object of the type at.
pub const Stats = struct {
    flight: [ship_type_count]FlightModel,
    combat: [ship_type_count]ShipCombat,

    /// The tables as the executable holds them before `stats_load_ships` runs: every figure zero,
    /// and each combat record's own words.
    pub const initial: Stats = built: {
        var tables: Stats = .{
            .flight = @splat(std.mem.zeroes(FlightModel)),
            .combat = @splat(std.mem.zeroes(ShipCombat)),
        };
        for (&tables.combat, combat_stats.ship_types) |*record, static| {
            record.targeting = .{ .targetable = static.targetable };
            record.name = static.name;
            record.class = static.class;
            record.side = static.side;
            record._unknown_2c = static.unknown_2c;
        }
        break :built tables;
    };

    /// `stats_load_ships` (`0x00466500`): each record of `shipstats.bin` in turn fills in its
    /// type's figures, up to the last type, and then every type's `speed_per_pitch_rate` is worked
    /// out. The combat stats keep in whole numbers what the runtime's `__ftol` cuts the record's
    /// figures down to, and a `shield_recharge` of zero becomes
    /// `stats.Ship.default_shield_recharge`.
    pub fn load(tables: *Stats, ships: []align(1) const stats.Ship) void {
        const count = @min(ships.len, ship_type_count);
        for (tables.flight[0..count], tables.combat[0..count], ships[0..count]) |*flight, *record, ship| {
            flight.max_speed = ship.max_speed;
            flight.roll_rate = ship.roll_rate;
            flight.pitch_rate = ship.pitch_rate;
            flight.yaw_rate = ship.yaw_rate;
            flight.inertia = ship.inertia;
            flight.roll_inertia = ship.roll_inertia;
            flight.pitch_inertia = ship.pitch_inertia;
            flight.yaw_inertia = ship.yaw_inertia;
            record.shield_power = std.math.lossyCast(i32, ship.shield_power);
            record.armor_class = std.math.lossyCast(i32, ship.armor_class);
            record.afterburner_fuel = std.math.lossyCast(i32, ship.afterburner_fuel);
            record.shield_recharge = if (ship.shield_recharge == 0) stats.Ship.default_shield_recharge else ship.shield_recharge;
            record.gun_energy = ship.gun_energy;
            record._unknown_14 = ship._unknown_74;
            record._unknown_18 = std.math.lossyCast(i32, ship._unknown_78);
        }
        for (&tables.flight) |*flight| flight.speed_per_pitch_rate = flight.max_speed / flight.pitch_rate;
    }

    /// What `create_object` does for a type that is `from` under another number (`donor`): the
    /// type takes `from`'s flight model and its combat stats, save for its own gun groups and
    /// name.
    fn borrow(tables: *Stats, ship_type: u8, from: u8) void {
        const own = tables.combat[ship_type];
        tables.combat[ship_type] = tables.combat[from];
        tables.combat[ship_type].gun_groups = own.gun_groups;
        tables.combat[ship_type].gun_group_table = own.gun_group_table;
        tables.combat[ship_type].name = own.name;
        tables.flight[ship_type] = tables.flight[from];
    }
};

/// The ship type a type is under another number, or null for none (`create_object`): the
/// Krasnaya, the Kiev, the Mitchell, the Zakov, the Kestrel and the Mammoth are each more than one
/// type, one model under several numbers. An object of such a type takes the stats of the first
/// (`Stats.borrow`), and then its number.
pub fn donor(ship_type: u8) ?u8 {
    return switch (ship_type) {
        0x35, 0xDB, 0xDC => 0x78,
        0x36, 0x40, 0xDD, 0xDE => 0xC2,
        0xA0 => 0x13,
        0xA1, 0xA2, 0xE2 => 0xB0,
        0xDA => 0x0F,
        0xE3...0xEF => 0x21,
        else => null,
    };
}

/// How a ship or a missile flies. `ship_flight_stats` holds one per ship, `missile_flight_stats`
/// one per missile; a missile's has only its speed and rates set.
pub const FlightModel = extern struct {
    /// `Ship.max_speed`, or `Missile.speed`.
    max_speed: f32,
    /// `Ship.roll_rate`, or `Missile.turn_rate`.
    roll_rate: f32,
    /// `Ship.pitch_rate`, or `Missile.turn_rate`.
    pitch_rate: f32,
    /// `Ship.yaw_rate`, or `Missile.turn_rate`.
    yaw_rate: f32,
    /// `Ship.inertia`.
    inertia: f32,
    roll_inertia: f32,
    pitch_inertia: f32,
    yaw_inertia: f32,
    /// `max_speed / pitch_rate`, which the ship loader computes after reading the file.
    speed_per_pitch_rate: f32,
    _unknown_24: u32,

    comptime {
        assert(@offsetOf(FlightModel, "inertia") == 0x10);
        assert(@offsetOf(FlightModel, "speed_per_pitch_rate") == 0x20);
        assert(@sizeOf(FlightModel) == 0x28);
    }
};

/// A ship type's defences and what it is, one per type in `ship_combat_stats`: its figures from
/// `shipstats.bin` up to `+0x1C`, which `stats_load_ships` fills in, then the gun groups, which
/// the gun code works out at run time, then words the executable holds
/// ([`create/combat.zig`](create/combat.zig)).
pub const ShipCombat = extern struct {
    /// `Ship.shield_power`, truncated.
    shield_power: i32,
    /// `Ship.armor_class`, truncated.
    armor_class: i32,
    /// `Ship.afterburner_fuel`, truncated.
    afterburner_fuel: i32,
    /// `Ship.shield_recharge`, or 10 in place of zero.
    shield_recharge: f32,
    /// `Ship.gun_energy`: the most the guns' charge holds.
    gun_energy: f32,
    /// `Ship._unknown_74`. **Unverified:** the seconds the guns take to charge fully: the guns'
    /// step adds `gun_energy * gun_factor * gun_condition / (this * 25)` to their charge
    /// (`0x004770E0`).
    _unknown_14: f32,
    /// `Ship._unknown_78`, truncated: what `GameObject._unknown_13c` starts at.
    _unknown_18: i32,
    /// The type's guns in groups, which `0x004667F0` works out from its first object's guns,
    /// pairing each gun with its mirror image across the ship; zero until then (#131).
    gun_groups: i16,
    _unknown_1e: u16,
    /// The groups, `0x00545900 + type * 0x78`, set with `gun_groups`.
    gun_group_table: Pointer(anyopaque),
    targeting: Targeting,
    /// The language string that names the type.
    name: u16,
    class: Class,
    /// The side the type's objects start on.
    side: gameobj.Side(i16),
    /// **Unknown.** 0 or 1.
    _unknown_2c: u32,

    pub const Targeting = packed struct(u16) {
        /// The type's objects can be picked as targets: `object_set_targetable` sets an object's
        /// `targetable` flag only where this is set.
        targetable: bool = false,
        _unknown_1: u15 = 0,
    };

    /// What a ship type is, going by the models of each class.
    pub const Class = enum(u16) {
        /// The player's ships, their twins, and the Coalition's fighters.
        fighter = 1,
        /// Capital ships and their wrecks, and other large bodies such as the asteroids of types
        /// 0x79 to 0x7F.
        capital = 2,
        /// Bombers, transports, tugs, escape pods, some stations: what lies between fighters and
        /// capital ships.
        support = 3,
        /// Gates, containers, satellites, beacons, pods, rock chunks and the like.
        other = 4,
        torpedo = 5,
        /// Wreckage, floating crew, doors and plates. `create_object` gives an object of the class
        /// a tenth of its mass.
        debris = 6,
        /// The proximity mine, which `create_object` gives a radius of 2000.
        mine = 7,
        planet = 8,
        _,
    };

    comptime {
        assert(@offsetOf(ShipCombat, "shield_recharge") == 0x0C);
        assert(@offsetOf(ShipCombat, "gun_groups") == 0x1C);
        assert(@offsetOf(ShipCombat, "gun_group_table") == 0x20);
        assert(@offsetOf(ShipCombat, "targeting") == 0x24);
        assert(@offsetOf(ShipCombat, "name") == 0x26);
        assert(@offsetOf(ShipCombat, "class") == 0x28);
        assert(@offsetOf(ShipCombat, "side") == 0x2A);
        assert(@offsetOf(ShipCombat, "_unknown_2c") == 0x2C);
        assert(@sizeOf(ShipCombat) == 0x30);
    }
};

/// An entry of `ship_types`, one for each ship type; [`create/models.zig`](create/models.zig) has the names.
pub const ShipType = extern struct {
    model_name: Pointer(u8),
    schematic_name: Pointer(u8),
    /// Objects of the type, which `create_object` counts up, loading the model for the first.
    objects: u16,
    _unknown_0a: u16,
    /// The model, once loaded.
    model: Pointer(anyopaque),
    /// What its objects keep as `GameObject.type_data`: the schematic `ship_type_load` loads with
    /// the model.
    type_data: Pointer(anyopaque),

    comptime {
        assert(@offsetOf(ShipType, "model") == 0x0C);
        assert(@sizeOf(ShipType) == 0x14);
    }
};

/// An entry of `attachment_models`: what attachment points of one kind and id mount, as loaded.
/// [`create/models.zig`](create/models.zig) has the file names.
pub const MountedModel = extern struct {
    model: Pointer(anyopaque),
    /// A second model: the missile, for a missile pod.
    second_model: Pointer(anyopaque),
    /// **Unknown.** 1 unless the loader sets it.
    count: u32,
    sprite: Pointer(anyopaque),

    comptime {
        assert(@sizeOf(MountedModel) == 0x10);
    }
};

/// A ship type's model as `ship_type_load` (`0x00466740`) loads it for the type's first object.
/// It loads the type's schematic as well, which the port leaves with whoever loads the model,
/// since the display draws it.
pub const Type = struct {
    model: *const shp.Model,
    loaded: *const srofiles.Loaded,
    /// What the type's objects light themselves with and mount.
    effects: objects.Effects = .{},
};

/// Where ship types' models come from: whoever has the game's files answers, as for
/// `objects.Mounts`.
pub const Types = struct {
    context: *anyopaque,
    /// Null for a type with no model, or one the game lacks or cannot read; whoever answers says
    /// why.
    load: *const fn (context: *anyopaque, ship_type: u8) ?*const Type,
};

/// What `ship_types` keeps of a ship type while a mission runs: how many objects of it
/// `create_object` has made, and what it loaded for the first.
pub const TypeUse = struct {
    objects: u16 = 0,
    loaded: ?*const Type = null,
};

/// The slot the loops over the objects walk after those handed out (`0x0057E04E`), which the
/// mission's start sets to 399, the last. The cutaway scenes use it: in one of them only the
/// player's ship and this slot's object are drawn.
pub const cutaway_slot: u16 = gameobj.max_objects - 1;

/// A slot of `game_objects`: the object's record, and what the port keeps beside it where the
/// record holds the original's 32-bit pointers.
pub const Slot = struct {
    object: GameObject,
    /// Its type's stats in `Stats` (`GameObject.combat`, `flight`); null for a stand-in.
    combat: ?*const ShipCombat = null,
    flight: ?*const FlightModel = null,
    /// Its type's model as loaded (`GameObject.model`), and the nodes of the model's parts, which
    /// hang from its root; null for a stand-in, or a type the game has no model for.
    type: ?*const Type = null,
    model: ?objects.Model = null,
    /// What moves it each update (`GameObject.motion`); null for nothing.
    motion: ?motion.Motion = null,
    /// Where its root's frame has it drawn (`objects.frameTree`), which stays put between the
    /// steps that move it.
    drawn: objects.Model.Local = .{},
};

/// `game_objects` (`0x00587CE0`), the GO array: 400 slots, none ever empty. As a mission starts
/// every slot gets a stand-in (`reset`), and `create_object` fills them with objects
/// (`createObject`), in turn or at the slot it is given, such as a mission ship's index among the
/// ship records. The loops over the objects walk the slots handed out, then the cutaway slot
/// (`walk`).
pub const Objects = struct {
    gpa: Allocator,
    slots: [gameobj.max_objects]Slot,
    /// `game_object_count` (`0x00539AA0`): the slots `create_object` has handed out in turn.
    count: u16 = 0,
    /// `player_slots` (`0x0058832C`): the slots from the first that belong to players, one in a
    /// single-player game.
    players: u16 = 1,
    /// `player_index` (`0x005883FA`): the player's slot, the first in a single-player game.
    player: u16 = 0,
    types: [ship_type_count]TypeUse = @splat(.{}),

    /// Every slot standing in, as a mission's start leaves them (`reset`), made in `gpa`.
    pub fn create(gpa: Allocator, random: *libcmt.Rand) Allocator.Error!*Objects {
        const all = try gpa.create(Objects);
        all.* = .{ .gpa = gpa, .slots = @splat(.{ .object = undefined }) };
        all.reset(random);
        return all;
    }

    pub fn destroy(all: *Objects) void {
        for (&all.slots) |*slot| if (slot.model) |model| model.deinit(all.gpa);
        all.gpa.destroy(all);
    }

    /// `objects_reset` (`0x00466630`), as a mission starts: every slot gets a new stand-in, of
    /// `gameobj.stand_in_type` and flagged `stand_in` (`object_alloc`), no slot is handed out, and
    /// no ship type has objects or a model loaded. The port lets go of the objects' nodes as well,
    /// which the game frees as the mission before ends.
    ///
    /// Not ported: the planets' atmospheres, whose texture it loads and whose table it empties.
    pub fn reset(all: *Objects, random: *libcmt.Rand) void {
        for (&all.slots) |*slot| {
            if (slot.model) |model| model.deinit(all.gpa);
            var object = gameobj.objectAlloc(gameobj.stand_in_type, random);
            object.flags.stand_in = true;
            slot.* = .{ .object = object };
        }
        all.types = @splat(.{});
        all.count = 0;
    }

    /// `object_reset` (`0x004688B0`): replaces the object in slot `index` with a new stand-in
    /// flagged as one (`GameObject.Flags.standing_in`), and lets its nodes go. Its type's count of
    /// objects stays as it was. Not ported yet: the orders it pops first (#32).
    pub fn resetSlot(all: *Objects, index: u16, random: *libcmt.Rand) void {
        const slot = &all.slots[index];
        if (slot.model) |model| model.deinit(all.gpa);
        var object = gameobj.objectAlloc(gameobj.stand_in_type, random);
        object.flags = .standing_in;
        slot.* = .{ .object = object };
    }

    /// The slots the loops over the objects walk, in their order.
    pub fn walk(all: *const Objects) Walk {
        return .{ .all = all };
    }

    /// Each slot handed out, from the first, then the cutaway slot. The loops read the count at
    /// every slot, so an object created on the way is walked as well.
    ///
    /// **Improvement:** with every slot handed out, the cutaway slot comes round again and again in
    /// the game's loops, which never end; the port walks it once.
    pub const Walk = struct {
        all: *const Objects,
        at: u16 = 0,

        pub fn next(w: *Walk) ?u16 {
            if (w.at < w.all.count) {
                defer w.at += 1;
                return w.at;
            }
            if (w.at > cutaway_slot) return null;
            w.at = cutaway_slot + 1;
            return cutaway_slot;
        }
    };
};

/// What goes wrong in `create_object`, which stops the game with a fatal error for either.
pub const Error = error{
    /// "Overrun in GO array": the slot is past the last, or none is left to hand out.
    Overrun,
    /// "Trying to create object %s twice".
    CreatedTwice,
} || Allocator.Error;

/// The radius `create_object` gives an object of a type above the last ship type.
pub const stand_in_radius: f32 = 4000;

/// The pilot `create_object` gives the Coalition's types, record 66 of `pilotstats.bin`; every
/// other type gets record 0.
pub const coalition_pilot = 66;

/// A mine's radius (`ShipCombat.Class.mine`).
const mine_radius: f32 = 2000;

/// What a piece of debris's mass is scaled by (`ShipCombat.Class.debris`).
const debris_mass: f32 = 0.1;

/// The kind of attachment that gets an object `GameObject.Flags._unknown_25`.
const flagged_kind: shp.Attachment.Kind = @enumFromInt(6);

/// `create_object` (`0x00466C10`): fills slot `wanted`, or the next where null, with an object of
/// `ship_type` at `at`, facing along the world's Z axis, and returns the slot. Types above the
/// last ship type are stand-ins for markers and nav points: `Flags.standing_in` and a sphere of
/// `stand_in_radius`, and nothing else. Any other is set up at rest, undamaged and flying itself
/// forward (`motion.Motion.forward`), on its type's side, with its model's parts playing their
/// `startup` tracks (`startUp`) and linked (`gameobj.linkParts`). A type that is another under a
/// second number takes the other's stats (`donor`), and its number once it is made.
///
/// Not ported: the tier, which chooses the guns (#131); the guns and their groups, the loadout and
/// its pods (#131, #38, #39); the components (#40); the shield's effect (#133); what it does for
/// capital ships, planets, gates and other single types; for a player's slot, the ship the player
/// chose and its `t_` twin from the 14th mission on; and what differs in a multiplayer game.
pub fn createObject(all: *Objects, tables: *Stats, types: Types, wanted: ?u16, ship_type: u32, at: Vector, random: *libcmt.Rand) Error!u16 {
    const index = wanted orelse all.count;
    if (index >= gameobj.max_objects) return error.Overrun;
    const slot = &all.slots[index];
    const object = &slot.object;
    if (object.created) return error.CreatedTwice;
    if (wanted == null) all.count += 1;

    object.type = ship_type;
    object.index = index;
    object.flags = .{};
    object.root.flags._unknown_9 = true;
    // At rest, and steering nothing.
    object.speed = 0;
    object.roll_rate = 0;
    object.pitch_rate = 0;
    object.yaw_rate = 0;
    object.throttle = 0;
    object.roll_input = 0;
    object.pitch_input = 0;
    object.yaw_input = 0;
    object._unknown_74c = 0xFFFF;
    object.random_seed = random.rand();
    object.invulnerable = 0;
    object.visibility = 1;
    object.engines = 0;
    object._unknown_6ac = -1;
    object._unknown_6b0 = 0;
    object._unknown_70c = xtrabits.objectRandom15(object) % 100;
    objects.setPosition(object, &slot.drawn, at);
    objects.setOrientation(object, &slot.drawn, math.identity);
    // No orders, and no attacker yet.
    object.order_count = 0;
    object.orders = .null;
    object.created = true;
    object.last_attacker = -1;
    object._unknown_720 = -1;
    object._unknown_724 = -1;
    object._unknown_6a8 = 0;
    object.motion = .null;
    object.side = .neutral;
    object._unknown_65c = 0;
    // Its armour whole.
    object.shield_condition = 1;
    object.armor_speed_factor = 1;
    object.gun_condition = 1;
    object._unknown_750 = 0;
    object._unknown_b96 = 0xFFFF;
    object._unknown_14c = 0;
    object.blind_fire_aim = 0;
    object._unknown_678 = 0;
    object._unknown_710 = @splat(0);

    const stats_type = std.math.cast(u8, ship_type) orelse {
        object.type_data = .null;
        object.pilot_record = .null;
        object._unknown_628 = .{ .x = 0, .y = 0, .z = 0 };
        object.shields = @splat(0);
        object.armor = @splat(0);
        object.flags = .standing_in;
        object.radius = stand_in_radius;
        return index;
    };
    const becomes = donor(stats_type) orelse stats_type;
    if (becomes != stats_type) tables.borrow(stats_type, becomes);
    const combat = &tables.combat[stats_type];
    slot.combat = combat;
    slot.flight = &tables.flight[stats_type];
    slot.motion = .forward;
    object.side = @enumFromInt(@intFromEnum(combat.side));

    // The type's model, loaded for its first object.
    const use = &all.types[stats_type];
    if (use.objects == 0 and use.loaded == null) use.loaded = types.load(types.context, stats_type);
    use.objects += 1;
    slot.type = use.loaded;
    if (use.loaded) |loaded| {
        var model: objects.Model = try .create(all.gpa, loaded.model, loaded.loaded, loaded.effects);
        startUp(&model);
        for (loaded.model.parts) |part| {
            switch (part.part.class) {
                .shield_generator => object.flags.shield_generator = true,
                .engine => object.engines += 1,
                else => {},
            }
            for (part.attachments) |attachment| {
                if (attachment.kind == flagged_kind) object.flags._unknown_25 = true;
            }
        }
        gameobj.linkParts(&model, loaded.model);
        slot.model = model;
        // `object_recentre` puts what it works out in the record.
        object.mass = model.mass;
        object.centre = gameobj.vec3(model.centre);
        object.radius = model.radius;
        object.bounds_min = gameobj.vec3(model.bounds[0]);
        object.bounds_max = gameobj.vec3(model.bounds[1]);
        objects.setPosition(object, &slot.drawn, at);
        switch (combat.class) {
            .debris => object.mass *= debris_mass,
            .mine => object.radius = mine_radius,
            else => {},
        }
        if (!loaded.model.header.flags.components and index >= all.players) object.flags.ecm = true;
        if (loaded.model.header.flags.components) {
            object.flags.components = true;
            object.flags.attached = true;
        }
    }
    object._unknown_24 = 0;
    pilots.setPilot(object, if (combat.side == .hostile) coalition_pilot else 0);
    // Each quadrant's shields and armour full.
    object.shields = @splat(@as(f32, @floatFromInt(combat.shield_power * 6)) - 1);
    object.armor = @splat(@as(f32, @floatFromInt(combat.armor_class * 6)) - 1);
    main.armorConditions(object, combat);

    object.engines_intact = 1;
    object.passes_through = @splat(-1);
    object._unknown_620 = -1;
    object._unknown_754 = -1;
    object.afterburner_fuel = combat.afterburner_fuel * 100;
    object.countermeasures = gameobj.countermeasures_when_created;
    // The power shared evenly, at (1, 1) on the power ball.
    object.gun_factor = 1;
    object.speed_factor = 1;
    object.shield_factor = 1;
    object.power_setting = .{ .x = 1, .y = 1, .z = 1 };
    object.gun_count = 0;
    object.component_count = 0;
    // Its guns charged.
    object.gun_charge = combat.gun_energy;
    object._unknown_13c = combat._unknown_18;
    object.gun_mode = .created(combat.gun_groups);
    ai.setTargetable(object, combat, true);
    object.type = becomes;
    return index;
}

/// `objects_update` (`0x00468FA0`), once a simulation step after the objects' own updates: moves
/// each live object of a ship type (`motion.move`), in the loops' order, passing over stand-ins
/// and disabled and frozen objects. The player's shakes the camera (`shake`).
///
/// Not ported yet: the collision sweep that follows (#40), and in a multiplayer game, what places
/// the other players' ships (#55).
pub fn objectsUpdate(all: *Objects, view: camera.View, shake: *f32) void {
    var walk = all.walk();
    while (walk.next()) |index| {
        const slot = &all.slots[index];
        const object = &slot.object;
        if (object.type >= ship_type_count or object.flags.stand_in or object.flags.disabled) continue;
        if (object.flags.frozen) continue;
        const flight = slot.flight orelse continue;
        motion.move(object, flight, view, slot.motion, if (index == all.player) shake else null);
    }
}

/// How far `create_object` has a part's `startup` track move on each simulation step.
const startup_speed: f32 = 4;

/// What `create_object` starts on each part it adds: the part's `startup` track, from its start,
/// as the track says to play it, at 4 a step. The parts are linked after, so each starts from
/// where its `startup` track has it.
pub fn startUp(model: *objects.Model) void {
    for (model.parts, 0..) |part, index| {
        if (part.animation.tracks.len > 0) model.play(index, .startup, 0, null, startup_speed);
    }
}

/// Fixtures for the tests here and in the modules that use the objects.
pub const testing = struct {
    /// A model of one part, to create objects of: a mesh and a level, and a part of mass 6.
    pub const Model = struct {
        mesh: @import("../surrender/surrenderlib/srapiext.zig").Mesh,
        levels: [1]@import("../surrender/surrenderlib/srapiext.zig").Level,
        loaded_parts: [1]srofiles.LoadedPart,
        data: [1]shp.PartData,
        source: shp.Model,
        loaded: srofiles.Loaded,
        type: Type,

        pub fn init(model: *Model, gpa: Allocator) !void {
            const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
            model.mesh = try srmesh.testing.square(gpa);
            model.levels = .{.{ .mesh = &model.mesh, .until = std.math.inf(f32) }};
            model.loaded_parts = .{.{ .flags = .{}, .levels = &model.levels, .meshes = &.{} }};
            model.data = .{objects.testing.part()};
            model.data[0].part.volume = 2;
            model.data[0].part.density = 3;
            model.source = .{ .header = std.mem.zeroes(shp.Header), .parts = &model.data, .tail_count = 0, .trailing_bytes = 0 };
            model.loaded = .{ .parts = &model.loaded_parts };
            model.type = .{ .model = &model.source, .loaded = &model.loaded };
        }

        pub fn deinit(model: *Model, gpa: Allocator) void {
            model.mesh.deinit(gpa);
        }

        /// Answers every ship type with the one model.
        pub fn types(model: *Model) Types {
            return .{ .context = model, .load = load };
        }

        fn load(context: *anyopaque, ship_type: u8) ?*const Type {
            _ = ship_type;
            const model: *Model = @ptrCast(@alignCast(context));
            return &model.type;
        }
    };

    /// Types with no model at all.
    pub const no_models: Types = .{ .context = @constCast(&{}), .load = noModel };

    fn noModel(context: *anyopaque, ship_type: u8) ?*const Type {
        _ = context;
        _ = ship_type;
        return null;
    }

    /// The tables with a fighter's figures for every type.
    pub fn tables() Stats {
        var made: Stats = .initial;
        for (&made.flight) |*flight| flight.* = gameobj.testing.flight;
        for (&made.combat) |*record| {
            record.shield_power = 8;
            record.armor_class = 5;
            record.afterburner_fuel = 60;
            record.shield_recharge = 10;
            record.gun_energy = 100;
        }
        return made;
    }
};

test "a mission starts with every slot standing in" {
    var random: libcmt.Rand = .{};
    const all = try Objects.create(std.testing.allocator, &random);
    defer all.destroy();
    try std.testing.expectEqual(0, all.count);
    for (all.slots) |slot| {
        try std.testing.expect(slot.object.flags.stand_in and !slot.object.created);
        try std.testing.expectEqual(gameobj.stand_in_type, slot.object.type);
    }
    // With nothing handed out, the loops walk the cutaway slot alone.
    var walk = all.walk();
    try std.testing.expectEqual(cutaway_slot, walk.next().?);
    try std.testing.expectEqual(null, walk.next());
}

test "the loops walk the slots handed out, then the cutaway slot" {
    var random: libcmt.Rand = .{};
    const all = try Objects.create(std.testing.allocator, &random);
    defer all.destroy();
    all.count = 3;
    var walked: std.ArrayList(u16) = .empty;
    defer walked.deinit(std.testing.allocator);
    var walk = all.walk();
    while (walk.next()) |index| {
        try walked.append(std.testing.allocator, index);
        // An object created on the way is walked as well.
        if (index == 1 and all.count == 3) all.count = 4;
    }
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2, 3, cutaway_slot }, walked.items);
    // With every slot handed out, the cutaway slot is walked once, as the last.
    all.count = gameobj.max_objects;
    walk = all.walk();
    var count: usize = 0;
    var last: u16 = 0;
    while (walk.next()) |index| {
        count += 1;
        last = index;
    }
    try std.testing.expectEqual(gameobj.max_objects, count);
    try std.testing.expectEqual(cutaway_slot, last);
}

test createObject {
    const gpa = std.testing.allocator;
    var random: libcmt.Rand = .{};
    const all = try Objects.create(gpa, &random);
    defer all.destroy();
    var model: testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    var tables = testing.tables();
    tables.combat[0x2B].side = .hostile;

    // The player first, in the next slot, at rest where it is put and facing along Z.
    const player = try createObject(all, &tables, model.types(), null, 0, .{ 0, 0, 500 }, &random);
    try std.testing.expectEqual(0, player);
    try std.testing.expectEqual(1, all.count);
    const made = &all.slots[player];
    const object = &made.object;
    try std.testing.expect(object.created and !object.flags.stand_in);
    try std.testing.expectEqual(math.Vector{ 0, 0, 500 }, gameobj.vector(object.root.position));
    try std.testing.expectEqual(math.identity, object.root.orientation);
    try std.testing.expectEqual(motion.Motion.forward, made.motion.?);
    try std.testing.expectEqual(1, all.types[0].objects);
    try std.testing.expectEqual(.friendly, object.side);
    try std.testing.expectEqual(0, object.pilot);
    // Undamaged: each quadrant six times the type's figure, less one.
    try std.testing.expectEqual([4]f32{ 47, 47, 47, 47 }, object.shields);
    try std.testing.expectEqual([4]f32{ 29, 29, 29, 29 }, object.armor);
    try std.testing.expectEqual(1, object.shield_condition);
    try std.testing.expectEqual(6000, object.afterburner_fuel);
    try std.testing.expectEqual(100, object.gun_charge);
    try std.testing.expectEqual(gameobj.countermeasures_when_created, object.countermeasures);
    try std.testing.expectEqual([2]i32{ -1, -1 }, object.passes_through);
    // Its model's one part, and the mass `object_recentre` put in the record.
    try std.testing.expectEqual(1, made.model.?.parts.len);
    try std.testing.expectEqual(6, object.mass);
    // The player's slot has no ECM on; every other slot's does.
    try std.testing.expect(!object.flags.ecm);

    // A Coalition fighter: hostile, flown by the Coalition's pilot, with its ECM on.
    const enemy = try createObject(all, &tables, model.types(), null, 0x2B, .{ 0, 0, 0 }, &random);
    try std.testing.expectEqual(.hostile, all.slots[enemy].object.side);
    try std.testing.expectEqual(coalition_pilot, all.slots[enemy].object.pilot);
    try std.testing.expect(all.slots[enemy].object.flags.ecm);

    // A slot filled once is not filled again, and nothing lies past the last.
    try std.testing.expectError(error.CreatedTwice, createObject(all, &tables, model.types(), player, 0, @splat(0), &random));
    try std.testing.expectError(error.Overrun, createObject(all, &tables, model.types(), gameobj.max_objects, 0, @splat(0), &random));

    // Above the last ship type, a stand-in for a marker, at a slot of its own.
    const marker = try createObject(all, &tables, model.types(), 20, 1000, @splat(0), &random);
    try std.testing.expectEqual(20, marker);
    try std.testing.expectEqual(2, all.count);
    const stand_in = all.slots[marker];
    try std.testing.expectEqual(GameObject.Flags.standing_in, stand_in.object.flags);
    try std.testing.expectEqual(stand_in_radius, stand_in.object.radius);
    try std.testing.expectEqual(null, stand_in.model);
    try std.testing.expectEqual(null, stand_in.combat);

    // Reset, the slot stands in again, and can be filled anew.
    all.resetSlot(player, &random);
    try std.testing.expectEqual(GameObject.Flags.standing_in, all.slots[player].object.flags);
    try std.testing.expectEqual(null, all.slots[player].model);
    _ = try createObject(all, &tables, model.types(), player, 0, @splat(0), &random);
}

test "a type under another number takes its stats, then its number" {
    const gpa = std.testing.allocator;
    var random: libcmt.Rand = .{};
    const all = try Objects.create(gpa, &random);
    defer all.destroy();
    var tables = testing.tables();
    tables.flight[0x21].max_speed = 55;
    tables.combat[0x21].shield_power = 30;
    tables.combat[0xE5].name = 1123;
    tables.combat[0xE5].gun_groups = 2;
    const index = try createObject(all, &tables, testing.no_models, null, 0xE5, @splat(0), &random);
    const slot = all.slots[index];
    try std.testing.expectEqual(0x21, slot.object.type);
    try std.testing.expectEqual(55, slot.flight.?.max_speed);
    try std.testing.expectEqual(30, slot.combat.?.shield_power);
    // Its own name and guns stay.
    try std.testing.expectEqual(1123, slot.combat.?.name);
    try std.testing.expectEqual(2, slot.combat.?.gun_groups);
    // The table it points into is its own number's, which now holds the other's stats.
    try std.testing.expectEqual(&tables.combat[0xE5], slot.combat.?);
    try std.testing.expectEqual(null, donor(0x21));
}

test "a type with no model still flies" {
    var random: libcmt.Rand = .{};
    const all = try Objects.create(std.testing.allocator, &random);
    defer all.destroy();
    var tables = testing.tables();
    const index = try createObject(all, &tables, testing.no_models, null, 3, @splat(0), &random);
    try std.testing.expectEqual(null, all.slots[index].model);
    all.slots[index].object.throttle = 1;
    all.slots[index].object.rotation = math.identity;
    var shake: f32 = 0;
    objectsUpdate(all, .chase, &shake);
    try std.testing.expect(all.slots[index].object.root.flags.next_pending);
    try std.testing.expect(all.slots[index].object.velocity.z > 0);
}

test objectsUpdate {
    var random: libcmt.Rand = .{};
    const all = try Objects.create(std.testing.allocator, &random);
    defer all.destroy();
    var tables = testing.tables();
    for (0..3) |_| _ = try createObject(all, &tables, testing.no_models, null, 0, @splat(0), &random);
    all.slots[1].object.flags.disabled = true;
    all.slots[2].object.flags.frozen = true;
    // Each drifting, with no motion of its own.
    for (all.slots[0..3]) |*slot| {
        slot.object.velocity = .{ .x = 0, .y = 0, .z = 10 };
        slot.motion = null;
    }
    var shake: f32 = 0;
    objectsUpdate(all, .chase, &shake);
    // The first moves on; the disabled and the frozen ones stay where they are.
    try std.testing.expectEqual(10, all.slots[0].object.root.next_position.z);
    try std.testing.expectEqual(0, all.slots[1].object.root.next_position.z);
    try std.testing.expectEqual(0, all.slots[2].object.root.next_position.z);
}

test "the tables hold the executable's words until the file fills in the figures" {
    const initial: Stats = .initial;
    // The Reliant, a capital ship of the player's side that can be targeted.
    try std.testing.expectEqual(.capital, initial.combat[0x0C].class);
    try std.testing.expectEqual(.friendly, initial.combat[0x0C].side);
    try std.testing.expect(initial.combat[0x0C].targeting.targetable);
    // The Sabre, a Coalition fighter.
    try std.testing.expectEqual(.fighter, initial.combat[0x2B].class);
    try std.testing.expectEqual(.hostile, initial.combat[0x2B].side);
    try std.testing.expectEqual(0, initial.combat[0x2B].shield_power);

    var ship = std.mem.zeroes(stats.Ship);
    ship.max_speed = 320;
    ship.pitch_rate = 2;
    ship.shield_power = 8.9;
    var tables: Stats = .initial;
    tables.load((&ship)[0..1]);
    try std.testing.expectEqual(8, tables.combat[0].shield_power);
    try std.testing.expectEqual(stats.Ship.default_shield_recharge, tables.combat[0].shield_recharge);
    try std.testing.expectEqual(160, tables.flight[0].speed_per_pitch_rate);
    // The file's figures leave the executable's words alone.
    try std.testing.expectEqual(initial.combat[0].name, tables.combat[0].name);
}

test {
    std.testing.refAllDecls(@This());
}

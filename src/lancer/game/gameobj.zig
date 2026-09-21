//! `C:\lancer\game\gameobj.cpp`: the game's live objects, the ships, stations, gates, missiles and
//! markers of a running mission.
//!
//! `create_object` (`0x00466C10`) fills a slot of `game_objects`, which it calls the GO array: 400
//! pointers to objects, a mission ship's slot being its index among the mission's ship records.
//! Each object embeds the root of a hierarchy of nodes, one for each part of its model.

const std = @import("std");
const assert = std.debug.assert;

const shp = @import("../../formats/shp.zig");
const lancer = @import("../../lancer.zig");
const aigeneric = @import("aigeneric.zig");
const Node = @import("objects.zig").Node;
const Pointer = lancer.Pointer;
const create = @import("create.zig");

/// Code that acts for the object in a slot: its `motion`, which moves it for one update, such as
/// `motion_forward` (`0x004744C0`), which flies it forward by the flight model, and the routines
/// of its orders.
pub const Routine = lancer.Code("void __fastcall (int slot)");

/// Slots in `game_objects`. `create_object` stops the game with a fatal error past the last.
pub const max_objects = 400;

/// Components an object can list.
pub const max_components = 60;

/// A part of an object that events and scripts can name by its index in `GameObject.components`,
/// such as a capital ship's turret: a trigger's qualifier, a squad member's component.
pub const Component = extern struct {
    node: Pointer(Node),
    /// Where the node's parent lists it.
    slot: Pointer(Pointer(Node)),
    /// Nonzero while the component is invulnerable: `SetInvulnerability` on the component.
    invulnerable: u16,
    _unknown_0a: u16,

    comptime {
        assert(@sizeOf(Component) == 0x0C);
    }
};

/// A live object (`gameobj.cpp`), allocated at `0x00475DD0`.
pub const GameObject = extern struct {
    /// The ship type: its record in `shipstats.bin`, which `combat` and `flight` point into. Types
    /// above 255, markers and nav points among them, have no stats.
    type: u32,
    /// Its slot in `game_objects`.
    index: u32,
    flags: Flags,
    _unknown_0c: u32,
    combat: Pointer(create.ShipCombat),
    flight: Pointer(create.FlightModel),
    /// The type's model, as loaded.
    model: Pointer(anyopaque),
    /// Data kept for the ship type and shared by its objects.
    type_data: Pointer(anyopaque),
    /// The renderer's object for it, or null.
    render: Pointer(anyopaque),
    _unknown_24: u16,
    _unknown_26: u16,
    /// The root of its model hierarchy.
    root: Node,
    /// **Unknown.** 1.0 when created; the collision sweep multiplies `radius` by it.
    _unknown_12c: f32,
    _unknown_130: [0x22]u8,
    component_count: i16,
    _unknown_154: [0xF4]u8,
    /// The parts of its model whose flags mark them as components, in the order `0x00468760`
    /// finds them: each node's marked children, then each child's in turn.
    components: [max_components]Component,
    _unknown_518: [0x54]u8,
    /// The turn applied to its orientation each update, which `object_steer` builds from the
    /// angular rates.
    rotation: [9]f32,
    /// Added to its position each update.
    velocity: shp.Vec3,
    /// The radius of the sphere collisions test it by.
    radius: f32,
    /// **Unverified:** the corners of its model's bounding box, which `0x004769F0` accumulates.
    bounds_min: shp.Vec3,
    bounds_max: shp.Vec3,
    /// Up to 1 in flight, 2 while `afterburner` is set, and -1 while `reverse_thrust` is.
    throttle: f32,
    /// Steering inputs, each between -1 and 1.
    roll_input: f32,
    pitch_input: f32,
    yaw_input: f32,
    /// Pushes it sideways: its lateral speed follows a quarter of its cruise speed times this.
    lateral_input: f32,
    /// Set while the afterburner burns, 4 units of `afterburner_fuel` an update.
    afterburner: bool,
    /// Set while reverse thrust burns: the throttle is -1, and it uses afterburner fuel.
    reverse_thrust: bool,
    _unknown_5ce: u16,
    /// Engines in its model: parts of subsystem class 5.
    engines: u32,
    /// The share of its engines left: 1.0 when created, less `1 / engines` for each one destroyed.
    engines_intact: f32,
    /// The length of `velocity`.
    speed: f32,
    /// Angular rates, which `object_steer` moves toward the inputs.
    roll_rate: f32,
    pitch_rate: f32,
    yaw_rate: f32,
    /// In hundredths of a second: `100 * ShipCombat.afterburner_fuel` when created, or zero in one
    /// of the game's modes.
    afterburner_fuel: i32,
    _unknown_5ec: [4]u8,
    /// Four values, each `6 * ShipCombat.shield_power - 1` when created.
    shields: [4]f32,
    /// Four values, each `6 * ShipCombat.armor_class - 1` when created. `ship_damage_value` reports
    /// the lowest.
    armor: [4]f32,
    _unknown_610: [0x28]u8,
    /// The seed of its own random numbers (`object_random`): C's `rand()` when created.
    random_seed: u32,
    /// Its cloak's state, 0x2C bytes that `object_cloak` allocates; null until then.
    cloak: Pointer(anyopaque),
    /// Moves it each update; `motion_forward` when created.
    motion: Pointer(Routine),
    /// Nonzero while it is hostile: `SetHostile`. When created, a value of its combat stats'
    /// (`+0x2A`), or in one of the game's modes one worked out otherwise.
    hostile: i32,
    _unknown_648: [8]u8,
    /// The throttle of the last update.
    last_throttle: f32,
    _unknown_654: [0x2C]u8,
    /// Orders on its stack.
    order_count: i16,
    _unknown_682: u16,
    /// Its order stack, the current order first: `aigeneric.max_stack` entries, allocated with its
    /// first order.
    orders: Pointer(aigeneric.Entry),
    /// Set while the current order has yet to start: `object_orders` runs its `init` first.
    order_starting: bool,
    _unknown_689: [3]u8,
    /// What the current order keeps between updates, allocated with the stack.
    order_state: Pointer(aigeneric.State),
    /// Damage of kinds 0, 1 and 5 taken since `orders_update` last zeroed it, which it does every
    /// 500 ticks.
    recent_damage: f32,
    /// The slot of the object that last damaged it, or -1.
    last_attacker: i32,
    _unknown_698: [0xA8]u8,
    /// Its pilot: the record in `pilotstats.bin`, which `object_set_pilot` gives it.
    pilot: i32,
    /// **Unknown.** A 24-byte record for the pilot, from a table at `0x5048D8`.
    pilot_record: Pointer(anyopaque),
    pilot_stats: Pointer(@import("pilots.zig").Pilot),
    _unknown_74c: [0x440]u8,
    /// Orders from other players waiting for their frame, in a multiplayer game.
    queued_order_count: i32,
    /// Its queue of `aigeneric.max_queued` entries, allocated when the first order arrives.
    queued_orders: Pointer(aigeneric.Queued),
    /// Set once `create_object` has filled the slot; it stops with a fatal error if it is set
    /// already.
    created: bool,
    /// Nonzero while it is invulnerable: `SetInvulnerability`.
    invulnerable: u8,
    _unknown_b96: u16,

    /// The names of the script commands that set a bit are the developers' own.
    pub const Flags = packed struct(u32) {
        _unknown_0: bool,
        /// Its components are listed, as its model's header asks. The collision code treats such
        /// objects apart.
        components: bool,
        /// The collision sweep of `objects_update` leaves it out.
        no_collisions: bool,
        _unknown_3: u2,
        /// Set on objects of types above 255, such as the type-1001 stand-in an empty slot holds;
        /// the per-object loops skip them.
        stand_in: bool,
        /// Set as it starts to explode. It takes no more orders.
        exploding: bool,
        /// Reverse thrust works only while it is set: `object_orders` clears `reverse_thrust`
        /// otherwise.
        can_reverse: bool,
        /// Set by `object_cloak`, which posts the Cloaked event.
        cloaked: bool,
        /// `SetTargetable` for the whole object, which sets it only when the word at `+0x24` of its
        /// combat stats is nonzero.
        targetable: bool,
        /// Not processed: `DisableObject`, and `DisableObjectAtNextJump` at the next jump.
        disabled: bool,
        /// Set once its pilot ejects. It takes no more orders, and destroying it now makes it
        /// explode.
        ejected: bool,
        _unknown_12: bool,
        /// `DisableLights`.
        lights_disabled: bool,
        /// It has a shield generator, a part of subsystem class 6, which destroying the part clears.
        shield_generator: bool,
        /// `DisableGuns`. `orders_update` skips `0x0047C950` for it.
        guns_disabled: bool,
        /// `DisableMissiles`.
        missiles_disabled: bool,
        /// `DisableEngines`. `object_orders` holds its throttle at zero and stops both burns.
        engines_disabled: bool,
        /// `DisableEject`. The player cannot eject.
        eject_disabled: bool,
        /// `DoNotDisturb`: "dont disturb". It does not retaliate either.
        do_not_disturb: bool,
        /// `SetShipAvoidance` with "Disable Avoidance code": the avoidance code passes it over.
        no_avoidance: bool,
        /// Set during the jump orders: it cannot fire, and the avoidance code passes it over.
        jumping: bool,
        /// Set while the Dock and Ripper orders hold it to another object; their ends clear it.
        attached: bool,
        _unknown_23: u5,
        /// **Unknown.** Set by `0x00474B40` as it sends a ship off, the player's into Friendly
        /// Fire and others into Jump Out, and cleared by Friendly Fire. It takes no orders while
        /// it is set.
        _unknown_28: bool,
        /// `DisableListing`: "stop listing".
        unlisted: bool,
        _unknown_30: u2,
    };

    comptime {
        assert(@bitOffsetOf(Flags, "components") == 1);
        assert(@bitOffsetOf(Flags, "stand_in") == 5);
        assert(@bitOffsetOf(Flags, "disabled") == 10);
        assert(@bitOffsetOf(Flags, "shield_generator") == 14);
        assert(@bitOffsetOf(Flags, "engines_disabled") == 17);
        assert(@bitOffsetOf(Flags, "attached") == 22);
        assert(@bitOffsetOf(Flags, "unlisted") == 29);
        assert(@offsetOf(GameObject, "combat") == 0x10);
        assert(@offsetOf(GameObject, "root") == 0x28);
        assert(@offsetOf(GameObject, "_unknown_12c") == 0x12C);
        assert(@offsetOf(GameObject, "component_count") == 0x152);
        assert(@offsetOf(GameObject, "components") == 0x248);
        assert(@offsetOf(GameObject, "engines") == 0x5D0);
        assert(@offsetOf(GameObject, "afterburner_fuel") == 0x5E8);
        assert(@offsetOf(GameObject, "shields") == 0x5F0);
        assert(@offsetOf(GameObject, "armor") == 0x600);
        assert(@offsetOf(GameObject, "rotation") == 0x56C);
        assert(@offsetOf(GameObject, "velocity") == 0x590);
        assert(@offsetOf(GameObject, "throttle") == 0x5B8);
        assert(@offsetOf(GameObject, "afterburner") == 0x5CC);
        assert(@offsetOf(GameObject, "speed") == 0x5D8);
        assert(@offsetOf(GameObject, "random_seed") == 0x638);
        assert(@offsetOf(GameObject, "motion") == 0x640);
        assert(@offsetOf(GameObject, "hostile") == 0x644);
        assert(@offsetOf(GameObject, "last_throttle") == 0x650);
        assert(@offsetOf(GameObject, "order_count") == 0x680);
        assert(@offsetOf(GameObject, "orders") == 0x684);
        assert(@offsetOf(GameObject, "order_state") == 0x68C);
        assert(@offsetOf(GameObject, "last_attacker") == 0x694);
        assert(@offsetOf(GameObject, "queued_orders") == 0xB90);
        assert(@offsetOf(GameObject, "pilot") == 0x740);
        assert(@offsetOf(GameObject, "created") == 0xB94);
        assert(@sizeOf(GameObject) == 0xB98);
    }
};

test {
    std.testing.refAllDecls(@This());
}

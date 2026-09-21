//! `C:\lancer\game\gameobj.cpp`: the game's live objects, the ships, stations, gates, missiles and
//! markers of a running mission.
//!
//! `create_object` (`0x00466C10`) fills a slot of `game_objects`, which it calls the GO array: 400
//! pointers to objects, a mission ship's slot being its index among the mission's ship records.
//! Each object embeds the root of a hierarchy of nodes, one for each part of its model.

const std = @import("std");
const assert = std.debug.assert;

const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const camera = @import("camera.zig");
const engine = @import("../../engine.zig");
const aigeneric = @import("aigeneric.zig");
const Node = @import("objects.zig").Node;
const Pointer = engine.Pointer;
const create = @import("create.zig");

/// Code that acts for the object in a slot: its `motion`, which moves it for one update, such as
/// `motion_forward` (`0x004744C0`), which flies it forward by the flight model, and the routines
/// of its orders.
pub const Routine = engine.Code("void __fastcall (int slot)");

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
    /// How far off it stays worth drawing, over the distance its radius alone would give it
    /// (`node_draw`). `object_alloc` and `create_object` both leave it at 1, so nothing in the
    /// shipped game sees further or less far than its size says.
    visibility: f32,
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
    /// **Unverified:** the corners of its model's bounding box, which `object_recentre`
    /// (`0x004769F0`) accumulates.
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
    /// Countermeasures left, which the display shows under its coil. 29 when the object is created
    /// (`create_object`, `object_alloc`), and `object_spend_countermeasure` (`0x00462550`) takes
    /// one at a time, flashing a display element when there are none.
    ///
    /// **Unverified:** that they are countermeasures. It is a consumable the player spends one of
    /// at a keypress with a sound, that the ships' own code spends too, and the game binds a
    /// COUNTERMEASURES key; nothing names it outright.
    countermeasures: u16,
    _unknown_5ee: u16,
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
    _unknown_654: [0x14]u8,
    /// Scales the cruise speed as its armor falls, which `object_cruise_speed` applies unless the
    /// camera is in view 13 or the object is invulnerable.
    armor_speed_factor: f32,
    _unknown_66c: [0x14]u8,
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
    _unknown_698: [0xA0]u8,
    /// Scales the cruise speed; 1.0 when created.
    speed_factor: f32,
    _unknown_73c: u32,
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
        /// Not drawn: `camera_set_view` sets it on the object whose cockpit the camera is in, and the
        /// warp orders while it warps. `mission_frame` hands `node_draw` flag `0x10` for it, which
        /// adds none of its parts to the scene.
        hidden: bool,
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
        assert(@offsetOf(GameObject, "visibility") == 0x12C);
        assert(@offsetOf(GameObject, "component_count") == 0x152);
        assert(@offsetOf(GameObject, "components") == 0x248);
        assert(@offsetOf(GameObject, "engines") == 0x5D0);
        assert(@offsetOf(GameObject, "afterburner_fuel") == 0x5E8);
        assert(@offsetOf(GameObject, "countermeasures") == 0x5EC);
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
        assert(@offsetOf(GameObject, "armor_speed_factor") == 0x668);
        assert(@offsetOf(GameObject, "speed_factor") == 0x738);
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

// --- Motion ------------------------------------------------------------------------------------

/// The routine `GameObject.motion` points at, which moves it for one update. `create_object` gives
/// every object `motion_forward`.
pub const Motion = enum {
    /// `motion_forward` (`0x004744C0`): the flight model with a thrust of 1.
    forward,
    /// `motion_backward` (`0x004744D0`): the flight model with a thrust of -1.
    backward,

    pub fn thrust(motion: Motion) f32 {
        return switch (motion) {
            .forward => 1,
            .backward => -1,
        };
    }
};

/// How many countermeasures an object is created with (`0x00407AAE`, `0x0045A0A4`).
pub const countermeasures_when_created: u16 = 29;

/// The view `object_cruise_speed` leaves a ship its undamaged speed in, whatever its armor.
const full_speed_view: camera.View = @enumFromInt(13);

/// The share of the cruise speed the lateral input pushes a ship sideways at (`object_fly`).
const lateral_share: f32 = 0.25;

/// What each update of the afterburner or of reverse thrust burns of `afterburner_fuel`.
const burn_fuel: i32 = 4;

/// The rule every quantity of the flight model moves by: it gives up `inertia` of the way it was
/// going and takes the rest from where it is headed, once per update.
fn settle(current: f32, target: f32, inertia: f32) f32 {
    return current * inertia + (1 - inertia) * target;
}

/// `x` squared, keeping its sign, which is the measure the model works in along the nose.
fn signedSquare(x: f32) f32 {
    return @abs(x) * x;
}

/// The inverse of `signedSquare`.
fn signedRoot(x: f32) f32 {
    return if (x >= 0) @sqrt(x) else -@sqrt(-x);
}

fn vector(v: shp.Vec3) math.Vector {
    return .{ v.x, v.y, v.z };
}

fn vec3(v: math.Vector) shp.Vec3 {
    return .{ .x = v[0], .y = v[1], .z = v[2] };
}

/// `object_cruise_speed` (`0x00403060`): `max_speed` scaled by `speed_factor`, by the share of its
/// engines left, and, unless the camera is in view 13 or the object is invulnerable, by
/// `armor_speed_factor` as well. So losing engines or armor slows a ship.
///
/// The port takes the flight stats and the view rather than reaching them through the object and a
/// global, since `GameObject` holds the binary's own 32-bit pointers.
pub fn cruiseSpeed(object: *const GameObject, flight: *const create.FlightModel, view: camera.View) f32 {
    var speed = flight.max_speed * object.speed_factor * object.engines_intact;
    if (view != full_speed_view and object.invulnerable == 0) speed *= object.armor_speed_factor;
    return speed;
}

/// `object_steer` (`0x00474150`): each input is clamped to between -1 and 1, and each angular rate
/// settles toward the ship's rate for that axis times the input. Where `throttle_turns`, that
/// target is divided by `3 - 2 * |throttle|` while that exceeds 1, so a ship turns more slowly the
/// less throttle it carries. The three rates then make the rotation.
pub fn steer(object: *GameObject, flight: *const create.FlightModel, throttle_turns: bool) void {
    const slowed = 3 - 2 * @abs(object.throttle);
    const divisor: f32 = if (throttle_turns and slowed >= 1) slowed else 1;
    const axes = [_]struct { rate: *f32, input: *f32, full: f32, inertia: f32 }{
        .{ .rate = &object.pitch_rate, .input = &object.pitch_input, .full = flight.pitch_rate, .inertia = flight.pitch_inertia },
        .{ .rate = &object.yaw_rate, .input = &object.yaw_input, .full = flight.yaw_rate, .inertia = flight.yaw_inertia },
        .{ .rate = &object.roll_rate, .input = &object.roll_input, .full = flight.roll_rate, .inertia = flight.roll_inertia },
    };
    for (axes) |axis| {
        axis.input.* = std.math.clamp(axis.input.*, -1, 1);
        axis.rate.* = settle(axis.rate.*, axis.full * axis.input.* / divisor, axis.inertia);
    }
    object.rotation = math.fromAngles(object.pitch_rate, object.yaw_rate, object.roll_rate);
}

/// `object_fly` (`0x004742E0`): the flight model, run for one update by the motion routine. The
/// throttle settles first, then the steering, then the speed, the last in the ship's own frame.
///
/// Along the nose the model settles in speed times its own size, so that thrust tells evenly at
/// every speed: the speed is squared keeping its sign, settles toward the thrust times the
/// throttle squared the same way times the target speed squared, and is rooted again. Sideways it
/// settles toward a quarter of the target times the lateral input, and along the ship's own down
/// axis it only decays.
pub fn fly(object: *GameObject, flight: *const create.FlightModel, view: camera.View, thrust: f32) void {
    if (object.afterburner) {
        object.throttle = 2;
        object.afterburner_fuel -= burn_fuel;
    } else if (object.reverse_thrust) {
        object.throttle = -1;
        object.afterburner_fuel -= burn_fuel;
    } else {
        object.throttle = std.math.clamp(object.throttle, 0, 1);
    }
    object.afterburner_fuel = @max(object.afterburner_fuel, 0);

    steer(object, flight, true);

    // The frame the last update left behind: `object_move` sets it once the motion has run.
    const frame = object.root.next_orientation;
    const inertia = flight.inertia;
    const target = if (object.afterburner or object.reverse_thrust)
        flight.max_speed
    else
        cruiseSpeed(object, flight, view);

    var speed = math.transformTransposed(frame, vector(object.velocity));
    const push = thrust * object.throttle;
    speed = .{
        settle(speed[0], object.lateral_input * target * lateral_share, inertia),
        settle(speed[1], 0, inertia),
        signedRoot(settle(signedSquare(speed[2]), signedSquare(push) * target * target, inertia)),
    };
    object.velocity = vec3(math.transform(frame, speed));
    object.last_throttle = object.throttle;
}

/// `object_move` (`0x00473FF0`): one update of an object. Its motion routine runs first, then its
/// next orientation becomes its orientation turned by `rotation`, its next position its position
/// plus its velocity, and its speed the length of that velocity.
///
/// Not ported: the guards that hold an object still while it jumps or docks, the flags it sets for
/// a moving or turning object, and the speed readout it keeps for the player's HUD.
pub fn move(object: *GameObject, flight: *const create.FlightModel, view: camera.View, motion: ?Motion) void {
    if (motion) |routine| fly(object, flight, view, routine.thrust());
    object.root.next_orientation = math.product(object.root.orientation, object.rotation);
    object.root.next_position = vec3(vector(object.root.position) + vector(object.velocity));
    object.speed = math.length(vector(object.velocity));
}

/// A light fighter's flight stats, near the Predator's, for the tests below.
const testing_flight: create.FlightModel = .{
    .max_speed = 320,
    .roll_rate = 3,
    .pitch_rate = 2,
    .yaw_rate = 1.5,
    .inertia = 0.9,
    .roll_inertia = 0.8,
    .pitch_inertia = 0.8,
    .yaw_inertia = 0.8,
    .speed_per_pitch_rate = 160,
    ._unknown_24 = 0,
};

/// An object as `create_object` leaves one: undamaged, at rest, facing along its own nose.
fn testingObject() GameObject {
    var object: GameObject = std.mem.zeroes(GameObject);
    object.root.orientation = math.identity;
    object.root.next_orientation = math.identity;
    object.speed_factor = 1;
    object.armor_speed_factor = 1;
    object.engines_intact = 1;
    return object;
}

test cruiseSpeed {
    var object = testingObject();
    try std.testing.expectEqual(320, cruiseSpeed(&object, &testing_flight, .chase));
    // Losing half its engines and a fifth of its armor slows it.
    object.engines_intact = 0.5;
    object.armor_speed_factor = 0.8;
    try std.testing.expectEqual(128, cruiseSpeed(&object, &testing_flight, .chase));
    // The armor tells in every view but 13, and not at all while it is invulnerable.
    try std.testing.expectEqual(160, cruiseSpeed(&object, &testing_flight, @enumFromInt(13)));
    object.invulnerable = 1;
    try std.testing.expectEqual(160, cruiseSpeed(&object, &testing_flight, .chase));
}

test steer {
    var object = testingObject();
    object.throttle = 1;
    // An input past the ends is clamped, and the rate settles toward the ship's own rate.
    object.pitch_input = 5;
    steer(&object, &testing_flight, true);
    try std.testing.expectEqual(1, object.pitch_input);
    try std.testing.expectApproxEqAbs(0.4, object.pitch_rate, 1e-6);
    for (0..200) |_| steer(&object, &testing_flight, true);
    try std.testing.expectApproxEqAbs(testing_flight.pitch_rate, object.pitch_rate, 1e-4);

    // At rest the same input turns it a third as fast, the divisor being 3 - 2 * |throttle|.
    var idle = testingObject();
    idle.pitch_input = 1;
    for (0..200) |_| steer(&idle, &testing_flight, true);
    try std.testing.expectApproxEqAbs(testing_flight.pitch_rate / 3, idle.pitch_rate, 1e-4);
    // A caller that does not ask for it gets no such division.
    var full = testingObject();
    full.pitch_input = 1;
    for (0..200) |_| steer(&full, &testing_flight, false);
    try std.testing.expectApproxEqAbs(testing_flight.pitch_rate, full.pitch_rate, 1e-4);
}

test "the throttle settles between 0 and 1, and the burns take it past both ends" {
    var object = testingObject();
    object.throttle = 5;
    fly(&object, &testing_flight, .chase, 1);
    try std.testing.expectEqual(1, object.throttle);
    try std.testing.expectEqual(1, object.last_throttle);
    object.throttle = -3;
    fly(&object, &testing_flight, .chase, 1);
    try std.testing.expectEqual(0, object.throttle);

    // The afterburner runs it to 2 and burns fuel; reverse thrust to -1, and burns it as well.
    object.afterburner = true;
    object.afterburner_fuel = 10;
    fly(&object, &testing_flight, .chase, 1);
    try std.testing.expectEqual(2, object.throttle);
    try std.testing.expectEqual(6, object.afterburner_fuel);
    object.afterburner = false;
    object.reverse_thrust = true;
    fly(&object, &testing_flight, .chase, 1);
    try std.testing.expectEqual(-1, object.throttle);
    try std.testing.expectEqual(2, object.afterburner_fuel);
    // The fuel stops at zero however long it burns.
    for (0..4) |_| fly(&object, &testing_flight, .chase, 1);
    try std.testing.expectEqual(0, object.afterburner_fuel);
}

test "a ship settles at its cruise speed along its nose" {
    var object = testingObject();
    object.throttle = 1;
    for (0..400) |_| move(&object, &testing_flight, .chase, .forward);
    // The model frame has Z forward, so all of the speed is along the nose.
    try std.testing.expectApproxEqAbs(320, object.speed, 0.5);
    try std.testing.expectApproxEqAbs(320, object.velocity.z, 0.5);
    try std.testing.expectApproxEqAbs(0, object.velocity.x, 1e-3);
    try std.testing.expectApproxEqAbs(0, object.velocity.y, 1e-3);
    // It never runs past the speed it is settling toward.
    try std.testing.expect(object.speed <= 320);

    // Half its engines gone, it settles at half the speed.
    object.engines_intact = 0.5;
    for (0..400) |_| move(&object, &testing_flight, .chase, .forward);
    try std.testing.expectApproxEqAbs(160, object.speed, 0.5);

    // Backward, the same ship ends up going the other way at the same speed.
    var reversed = testingObject();
    reversed.throttle = 1;
    for (0..400) |_| move(&reversed, &testing_flight, .chase, .backward);
    try std.testing.expectApproxEqAbs(-320, reversed.velocity.z, 0.5);
}

test "the lateral input pushes a ship a quarter as fast sideways" {
    var object = testingObject();
    object.lateral_input = 1;
    for (0..400) |_| move(&object, &testing_flight, .chase, .forward);
    try std.testing.expectApproxEqAbs(320 * lateral_share, object.velocity.x, 0.5);
}

test move {
    var object = testingObject();
    object.root.position = .{ .x = 1, .y = 2, .z = 3 };
    object.velocity = .{ .x = 10, .y = 0, .z = 20 };
    // `create_object` leaves the rotation zeroed, and the steering builds one before the first
    // move uses it; a turn of nothing stands in for that here.
    object.rotation = math.identity;
    // With no motion routine, it carries on at the velocity it has.
    move(&object, &testing_flight, .chase, null);
    try std.testing.expectEqual(11, object.root.next_position.x);
    try std.testing.expectEqual(2, object.root.next_position.y);
    try std.testing.expectEqual(23, object.root.next_position.z);
    try std.testing.expectApproxEqAbs(@sqrt(500.0), object.speed, 1e-4);
    // Its next orientation is its orientation turned by the rotation the steering built.
    try std.testing.expectEqual(math.identity, object.root.next_orientation);
}

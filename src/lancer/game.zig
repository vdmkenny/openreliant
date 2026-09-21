//! The game's live objects: the ships, stations, gates, missiles and markers of a running mission.
//!
//! `create_object` (`0x00466C10`) fills a slot of `game_objects`, which it calls the GO array: 400
//! pointers to objects, a mission ship's slot being its index among the mission's ship records.
//! Each object embeds the root of a hierarchy of nodes, one for each part of its model.

const std = @import("std");
const assert = std.debug.assert;

const shp = @import("../formats/shp.zig");
const lancer = @import("../lancer.zig");
const Pointer = lancer.Pointer;
const stats = lancer.stats;

/// Slots in `game_objects`. `create_object` stops the game with a fatal error past the last.
pub const max_objects = 400;

/// Components an object can list.
pub const max_components = 60;

/// Surrender's transform (`surrenderlib`), `0xB4` bytes, which `frame_create` (`0x004C51C0`)
/// allocates: a node's place relative to its parent frame.
pub const Frame = extern struct {
    _unknown_00: u32,
    /// Such as `GOroot object` for an object's root.
    name: Pointer(u8),
    _unknown_08: [8]u8,
    parent: Pointer(Frame),
    /// **Unknown**, mostly.
    flags: u32,
    /// Row-major 3x3.
    orientation: [9]f32,
    position: shp.Vec3,
    /// **Unknown.** 1.0 when created.
    _unknown_48: f32,
    _unknown_4c: [0x68]u8,

    comptime {
        assert(@offsetOf(Frame, "orientation") == 0x18);
        assert(@offsetOf(Frame, "position") == 0x3C);
        assert(@sizeOf(Frame) == 0xB4);
    }
};

/// A node of an object's model hierarchy (`objects.cpp`), allocated at `0x004991D0`: the object's
/// root, then a node for each part of its model.
pub const Node = extern struct {
    /// **Unknown.** 1 for the node of a model part.
    kind: u32,
    /// `0x20`: hidden, as a component's damaged parts are while it is intact. `0x100`: listed among
    /// the object's components. `0x2000`: the part has flag `0x1000`.
    flags: u32,
    /// The node's transform for the renderer, which holds the same place as `position` and
    /// `orientation`.
    frame: Pointer(Frame),
    _unknown_0c: u32,
    /// **Unknown.** -1 when allocated.
    _unknown_10: i32,
    /// Relative to the node it hangs from: a part's origin in its parent part. An object's root
    /// holds the object's place in the world.
    position: shp.Vec3,
    /// Row-major 3x3, relative like `position`.
    orientation: [9]f32,
    _unknown_44: [0x18]u8,
    /// **Unknown.** Set together with `position`, to the same value, when the part's node is made
    /// or the object is placed.
    _unknown_5c: shp.Vec3,
    /// **Unknown.** Likewise for `orientation`.
    _unknown_68: [9]f32,
    _unknown_8c: [0x18]u8,
    /// The model part the node stands for, as loaded.
    part: Pointer(shp.Part),
    /// The object the node belongs to.
    owner: Pointer(GameObject),
    _unknown_ac: [0x3C]u8,
    /// A component's counterpart of `GameObject.armor`, which `ship_damage_value` reads for it.
    armor: f32,
    /// The node it hangs from; null for a root. The root's `owner` is the object's.
    parent: Pointer(Node),
    _unknown_f0: u32,
    /// Children the list at `children` can hold: 100 once allocated.
    child_capacity: i32,
    child_count: i32,
    /// **Unknown.** -1 when allocated.
    _unknown_fc: i32,
    children: Pointer(Pointer(Node)),

    comptime {
        assert(@offsetOf(Node, "position") == 0x14);
        assert(@offsetOf(Node, "orientation") == 0x20);
        assert(@offsetOf(Node, "part") == 0xA4);
        assert(@offsetOf(Node, "armor") == 0xE8);
        assert(@offsetOf(Node, "child_count") == 0xF8);
        assert(@offsetOf(Node, "children") == 0x100);
        assert(@sizeOf(Node) == 0x104);
    }
};

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
    /// **Unknown**, mostly. `0x02`: its components are listed. `0x400`: disabled, not processed:
    /// `DisableObject`, and `DisableObjectAtNextJump` at the next jump. `0x4000`: it has a shield
    /// generator, a part of subsystem class 6, which destroying the part clears.
    flags: u32,
    _unknown_0c: u32,
    combat: Pointer(stats.ShipCombat),
    flight: Pointer(stats.FlightModel),
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
    /// **Unknown.** 1.0 when created.
    _unknown_12c: f32,
    _unknown_130: [0x22]u8,
    component_count: i16,
    _unknown_154: [0xF4]u8,
    /// The parts of its model whose flags mark them as components, in the order `0x00468760`
    /// finds them: each node's marked children, then each child's in turn.
    components: [max_components]Component,
    _unknown_518: [0xB8]u8,
    /// Engines in its model: parts of subsystem class 5.
    engines: u32,
    /// The share of its engines left: 1.0 when created, less `1 / engines` for each one destroyed.
    engines_intact: f32,
    _unknown_5d8: [0x10]u8,
    /// `100 * ShipCombat.afterburner_fuel` when created, or zero in one of the game's modes.
    afterburner_fuel: i32,
    _unknown_5ec: [4]u8,
    /// Four values, each `6 * ShipCombat.shield_power - 1` when created.
    shields: [4]f32,
    /// Four values, each `6 * ShipCombat.armor_class - 1` when created. `ship_damage_value` reports
    /// the lowest.
    armor: [4]f32,
    _unknown_610: [0x34]u8,
    /// Nonzero while it is hostile: `SetHostile`. When created, a value of its combat stats'
    /// (`+0x2A`), or in one of the game's modes one worked out otherwise.
    hostile: i32,
    _unknown_648: [0xF8]u8,
    /// Its pilot: the record in `pilotstats.bin`, which `object_set_pilot` gives it.
    pilot: i32,
    /// **Unknown.** A 24-byte record for the pilot, from a table at `0x5048D8`.
    pilot_record: Pointer(anyopaque),
    pilot_stats: Pointer(stats.Pilot),
    _unknown_74c: [0x448]u8,
    /// Set once `create_object` has filled the slot; it stops with a fatal error if it is set
    /// already.
    created: bool,
    /// Nonzero while it is invulnerable: `SetInvulnerability`.
    invulnerable: u8,
    _unknown_b96: u16,

    comptime {
        assert(@offsetOf(GameObject, "combat") == 0x10);
        assert(@offsetOf(GameObject, "root") == 0x28);
        assert(@offsetOf(GameObject, "_unknown_12c") == 0x12C);
        assert(@offsetOf(GameObject, "component_count") == 0x152);
        assert(@offsetOf(GameObject, "components") == 0x248);
        assert(@offsetOf(GameObject, "engines") == 0x5D0);
        assert(@offsetOf(GameObject, "afterburner_fuel") == 0x5E8);
        assert(@offsetOf(GameObject, "shields") == 0x5F0);
        assert(@offsetOf(GameObject, "armor") == 0x600);
        assert(@offsetOf(GameObject, "hostile") == 0x644);
        assert(@offsetOf(GameObject, "pilot") == 0x740);
        assert(@offsetOf(GameObject, "created") == 0xB94);
        assert(@sizeOf(GameObject) == 0xB98);
    }
};

/// An entry of `ship_types`, one for each ship type; `src/formats/models.zig` has the names.
pub const ShipType = extern struct {
    model_name: Pointer(u8),
    schematic_name: Pointer(u8),
    /// Objects of the type, which `create_object` counts up, loading the model for the first.
    objects: u16,
    _unknown_0a: u16,
    /// The model, once loaded.
    model: Pointer(anyopaque),
    /// What its objects keep as `GameObject.type_data`.
    type_data: Pointer(anyopaque),

    comptime {
        assert(@offsetOf(ShipType, "model") == 0x0C);
        assert(@sizeOf(ShipType) == 0x14);
    }
};

/// An entry of `attachment_models`: what attachment points of one kind and id mount, as loaded.
/// `src/formats/models.zig` has the file names.
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

test {
    std.testing.refAllDecls(@This());
}

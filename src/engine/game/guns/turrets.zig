//! The turrets of `C:\lancer\game\guns.cpp`: the gun a turret part fits by its turret kind as the
//! object is created (`object_collect_guns`), and what each turret keeps in its gun's record. A
//! turret's parts are its assembly: the shown parts of its model that share its part's link id,
//! each in a slot its part names (`shp.Part.turret_slot`).

const std = @import("std");

const shp = @import("../../../formats/shp.zig");
const aigeneric = @import("../aigeneric.zig");
const guns = @import("../guns.zig");
const objects = @import("../objects.zig");

/// What a turret's fit needs of the object it is fitted to: its components, and its model's firing
/// arcs, one a component.
pub const Ship = struct {
    components: []const ?*objects.Model.Part = &.{},
    arcs: []const shp.FiringArc = &.{},
};

/// A turret that turns to aim at a target of its own and fires by its parts' `fire` tracks (kind
/// 1).
pub const Aimed = struct {
    barrel: guns.Barrel,
    /// The model whose parts it turns (`+0x34`): its object's own, or the one mounted on it that
    /// holds it.
    model: *objects.Model,
    /// Its base (slot 0, `+0x38`), which yaws.
    base: usize,
    /// Its parts in slots 1 to 4 (`+0x3C` to `+0x48`): 1, which is the base where the assembly has
    /// none, and 2 pitch; every slot's part fires.
    slots: [4]?usize,
    /// What it aims at (`+0x18`), or none.
    target: aigeneric.Target = .none,
    /// When it next looks for a target while it has none (`+0x4C`).
    looks_at: i32 = 0,
    /// The yaw and pitch it has still to turn toward its aim (`+0x50`, `+0x54`).
    turn: [2]f32 = .{ 0, 0 },
    /// The directions it may fire in (`+0x58`), where a part of its assembly is a component of the
    /// object with a firing arc.
    arc: ?*const shp.FiringArc = null,
};

/// A gun whose barrels spin up while its trigger is held (kind 2).
pub const Spin = struct {
    barrel: guns.Barrel,
    /// The model whose parts it plays (`+0x30`).
    model: *objects.Model,
    /// Its barrels (slot 0, `+0x1C`), which spin; its gun (slot 1), whose track loops at their
    /// speed; and two flaps (slots 2 and 3), which open while it fires.
    barrels: usize,
    gun: ?usize,
    flaps: [2]?usize,
};

/// A missile turret, which launches Screamers (kind 3).
pub const Launcher = struct {
    /// The model whose parts it turns (`+0x34`).
    model: *objects.Model,
    /// Its base (slot 0, `+0x38`), which yaws, and the launcher on it (slot 1), which the missiles
    /// leave from and which plays its `reload` track.
    base: usize,
    launcher: usize,
    /// What it launches at (`+0x18`), or none.
    target: aigeneric.Target = .none,
    /// When its state's wait is over (`+0x4C`).
    until: i32 = 0,
    /// The missiles it has left (`+0x58`). It starts empty, and so reloads first.
    missiles: i32 = 0,
    state: State = .searching,

    /// What it is doing (`+0x5C`).
    pub const State = enum(i32) {
        searching = 0,
        tracking = 1,
        /// Out of missiles, waiting to reload.
        empty = 2,
        /// Its launcher playing its `reload` track forward, and then back.
        loading = 3,
        closing = 4,
    };
};

/// Whether a part of a turret's class and `kind` fits a turret gun (`object_collect_guns`, which
/// reads the kind's four bytes). A turret part of any other kind is passed over with its assembly.
pub fn fits(kind: shp.Part.TurretKind) bool {
    return switch (kind) {
        .aimed, .spin, .missile => true,
        .fixed, _ => false,
    };
}

/// The turret that part `index` of `model`, a part of a turret's class, fits by its turret kind
/// (`turret_fit_aimed`, `turret_fit_spin` and `turret_fit_missile`), or null where its assembly
/// lacks a part the turret's steps need, where the game would read through a missing one. Its
/// base's part is marked `turret`.
pub fn fit(model: *objects.Model, index: usize, ship: Ship) ?guns.Turret {
    var slots: [slot_count]?usize = @splat(null);
    var muzzle: ?guns.Muzzle = null;
    var arc: ?*const shp.FiringArc = null;
    const link = model.parts[index].link_id;
    for (model.parts, 0..) |*part, member| {
        if (part.hidden or part.link_id != link) continue;
        // The last muzzle of the assembly is the gun's.
        for (part.attachments) |*attachment| {
            if (attachment.kind == .gun_muzzle) muzzle = .{ .model = model, .part = member, .attachment = attachment };
        }
        if (slotOf(part)) |slot| slots[slot] = member;
        if (part.flags.component and ship.arcs.len > 0) {
            for (ship.components, 0..) |component, number| {
                if (component == part and number < ship.arcs.len) arc = &ship.arcs[number];
            }
        }
    }
    const base = slots[0] orelse return null;
    const turret: guns.Turret = switch (model.parts[index].turret_kind) {
        .aimed => .{ .aimed = .{
            .barrel = barrelOf(muzzle orelse return null),
            .model = model,
            .base = base,
            .slots = .{ slots[1] orelse base, slots[2], slots[3], slots[4] },
            .arc = arc,
        } },
        .spin => .{ .spin = .{
            .barrel = barrelOf(muzzle orelse return null),
            .model = model,
            .barrels = base,
            .gun = slots[1],
            .flaps = .{ slots[2], slots[3] },
        } },
        .missile => .{ .missile = .{
            .model = model,
            .base = base,
            .launcher = slots[1] orelse return null,
        } },
        .fixed, _ => return null,
    };
    model.parts[base].turret = true;
    return turret;
}

/// Slots a turret's record holds its parts in.
const slot_count = 5;

/// The slot a part of a turret's assembly stands in, or null for none. The game writes a slot
/// past the record's five, or a spinning or missile turret's slot of -1, into the words beside
/// them; the port passes it over.
fn slotOf(part: *const objects.Model.Part) ?usize {
    const slot = std.math.cast(usize, part.turret_slot) orelse return null;
    return if (slot < slot_count) slot else null;
}

/// The barrel a turret fires from `muzzle`, of the type the muzzle names.
fn barrelOf(muzzle: guns.Muzzle) guns.Barrel {
    return .{ .muzzle = muzzle, .type = .fromNumber(muzzle.attachment.gun_type) };
}

/// Whether some part of `model` of a turret's class shares `link`, which makes the part with it
/// one of the turret's assembly, whose muzzles are the turret's rather than guns of their own
/// (`object_collect_guns`). A turret's class alone counts, whatever its kind.
pub fn inAssembly(model: *const objects.Model, link: u32) bool {
    for (model.parts) |part| {
        if (part.link_id == link and part.class.isTurret()) return true;
    }
    return false;
}

test {
    std.testing.refAllDecls(@This());
}

/// Fixtures for the tests here and in the modules that step turrets.
pub const testing = struct {
    const srofiles = @import("../srofiles.zig");

    /// A model of `count` parts, each standing unturned at the model's origin, with no mesh.
    pub fn Parts(comptime count: usize) type {
        return struct {
            data: [count]shp.PartData,
            loaded_parts: [count]srofiles.LoadedPart,
            source: shp.Model,
            loaded: srofiles.Loaded,

            /// The parts, each hanging from the root, for the test to fill in before `create`.
            pub fn init(parts: *@This()) void {
                for (&parts.data, &parts.loaded_parts) |*data, *loaded| {
                    data.* = objects.testing.part();
                    data.part.parent = -1;
                    data.part.turret_slot = -1;
                    loaded.* = .{ .flags = .{}, .levels = &.{}, .meshes = &.{} };
                }
                parts.source = .{ .header = std.mem.zeroes(shp.Header), .parts = &parts.data, .trailing_bytes = 0 };
                parts.loaded = .{ .parts = &parts.loaded_parts };
            }

            /// Makes part `index` the turret of `kind` of the assembly `link`, in its `slot`.
            pub fn turret(parts: *@This(), index: usize, class: shp.Part.Class, kind: shp.Part.TurretKind, link: u32, slot: i32) void {
                parts.data[index].part.class = class;
                parts.data[index].part.turret_kind = kind;
                parts.member(index, link, slot);
            }

            /// Makes part `index` one of the assembly `link`, in `slot`.
            pub fn member(parts: *@This(), index: usize, link: u32, slot: i32) void {
                parts.data[index].part.link_id = link;
                parts.data[index].part.turret_slot = slot;
            }

            pub fn create(parts: *@This(), gpa: std.mem.Allocator) !objects.Model {
                var model: objects.Model = try .create(gpa, &parts.source, &parts.loaded, .{});
                for (0..model.parts.len) |index| @import("../gameobj.zig").linkPart(&model, index);
                return model;
            }
        };
    }

    /// A muzzle of gun type `gun_type`.
    pub fn muzzle(gun_type: u32) shp.Attachment {
        var attachment = std.mem.zeroes(shp.Attachment);
        attachment.kind = .gun_muzzle;
        attachment.orientation = @import("../../surrender/math.zig").identity;
        attachment.gun_type = gun_type;
        return attachment;
    }
};

test fit {
    const gpa = std.testing.allocator;
    var parts: testing.Parts(9) = undefined;
    parts.init();
    // A hull with a muzzle of its own.
    var hull = [_]shp.Attachment{testing.muzzle(1)};
    parts.data[0].attachments = &hull;
    // An aimed turret: its base, its barrels, and a part of the assembly in no slot, whose muzzle
    // is the last and so the gun's.
    parts.turret(1, .turret, .aimed, 5, 0);
    parts.member(2, 5, 1);
    parts.member(3, 5, -1);
    var barrels = [_]shp.Attachment{testing.muzzle(12)};
    var last = [_]shp.Attachment{testing.muzzle(13)};
    parts.data[2].attachments = &barrels;
    parts.data[3].attachments = &last;
    // A missile turret: its base and its launcher.
    parts.turret(4, .missile_turret, .missile, 7, 0);
    parts.member(5, 7, 1);
    // A turret's class with no kind: it and its assembly are passed over, muzzles and all.
    parts.turret(6, .ion_cannon, .fixed, 9, -1);
    parts.member(7, 9, -1);
    var ion = [_]shp.Attachment{testing.muzzle(2)};
    parts.data[7].attachments = &ion;
    // An aimed turret with no muzzle gives no gun.
    parts.turret(8, .turret, .aimed, 11, 0);

    var model = try parts.create(gpa);
    defer model.deinit(gpa);
    const fitted = try guns.fit(gpa, &model, .{});
    defer gpa.free(fitted);
    try std.testing.expectEqual(3, fitted.len);
    try std.testing.expectEqual(0, fitted[0].turret.fixed.muzzle.part);

    const aimed = fitted[1].turret.aimed;
    try std.testing.expectEqual(1, aimed.base);
    try std.testing.expectEqual([4]?usize{ 2, null, null, null }, aimed.slots);
    try std.testing.expectEqual(3, aimed.barrel.muzzle.part);
    try std.testing.expectEqual(guns.GunType.turret_lasers, aimed.barrel.type);
    try std.testing.expect(model.parts[1].turret and !model.parts[2].turret);
    try std.testing.expectEqual(-1, aimed.target.index);
    try std.testing.expectEqual(null, aimed.arc);

    const launcher = fitted[2].turret.missile;
    try std.testing.expectEqual(4, launcher.base);
    try std.testing.expectEqual(5, launcher.launcher);
    try std.testing.expectEqual(0, launcher.missiles);
    try std.testing.expect(fitted[2].barrel() == null);
}

test "a turret on a component fires within the component's arc" {
    const gpa = std.testing.allocator;
    var parts: testing.Parts(2) = undefined;
    parts.init();
    parts.turret(0, .turret, .aimed, 3, 0);
    parts.member(1, 3, 1);
    parts.data[0].part.flags.component = true;
    var barrels = [_]shp.Attachment{testing.muzzle(12)};
    parts.data[1].attachments = &barrels;
    var model = try parts.create(gpa);
    defer model.deinit(gpa);

    // The base is the object's second component: the second arc is its.
    const components = [_]?*objects.Model.Part{ null, &model.parts[0] };
    const arcs: [2]shp.FiringArc = @splat(std.mem.zeroes(shp.FiringArc));
    const turret = fit(&model, 0, .{ .components = &components, .arcs = &arcs }).?;
    try std.testing.expectEqual(&arcs[1], turret.aimed.arc.?);
    // Without arcs in the model, it fires anywhere its limits let it.
    try std.testing.expectEqual(null, fit(&model, 0, .{ .components = &components }).?.aimed.arc);
    // Nor past the arcs the model has.
    try std.testing.expectEqual(null, fit(&model, 0, .{ .components = &components, .arcs = arcs[0..1] }).?.aimed.arc);
}

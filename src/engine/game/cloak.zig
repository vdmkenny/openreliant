//! `C:\lancer\game\cloak.cpp`: the countermeasures, the decoys a ship drops to draw away the
//! missiles homing on it. **Unverified:** that they are this file's. Their code lies after
//! `cbox.cpp`'s and before `cloak.cpp`'s asserting code, and their model's name,
//! `ships\decoy.shp`, lies just before `cloak.cpp`'s path among the strings.
//! [`missiles.md`](../../../docs/engine/missiles.md#countermeasures) describes them.
//!
//! Not ported: the cloak itself ([#89](https://github.com/vdmkenny/openreliant/issues/89)), and in
//! a network game, the host's choice of the missile a countermeasure draws away.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const explode = @import("explode.zig");
const gameobj = @import("gameobj.zig");
const hud = @import("hud.zig");
const missiles = @import("missiles.zig");
const objects = @import("objects.zig");
const particles = @import("particles.zig");

/// How many countermeasures fly at once (`countermeasures`, `0x00540610`).
pub const max_countermeasures = 100;

/// A countermeasure dropped (`0x24` bytes of `countermeasures`).
pub const Countermeasure = struct {
    /// When it ends (`+0x04`), and the ship that dropped it (`+0x08`).
    until: i32,
    owner: u16,
    /// How far it drifts a tick (`+0x0C`).
    velocity: Vector,
    /// Its model where it stands (`+0x18`), turning as it drifts.
    model: objects.Model,
    /// Its smoke, from its nose and its tail (`+0x1C`, `+0x20`).
    streams: [2]particles.Emitter,

    pub fn place(countermeasure: *const Countermeasure) math.Place {
        return .{ .position = countermeasure.model.position, .orientation = countermeasure.model.orientation };
    }
};

/// The decoys' smoke (`decoy_particles`, `0x00541424`): a puff a tick at half the chance, from 50
/// to 100 across, dark grey fading to nothing, for a second or a tenth more.
pub const smoke: particles.Template = .{
    .life = 100,
    .life_spread = 10,
    .rate = .through(50, 50, 50),
    .size = .through(50, 75, 100),
    .colour = @splat(.through(0.25, 0.15, 0)),
};

/// How long a countermeasure lasts; how fast it drops away along its dropper's Y axis and back,
/// a tick, beside a quarter of its dropper's velocity (`0x004DC56C`); how far it turns about its Y
/// axis a tick; and its end's fireball, from the sheet: how far across and for how long.
const life = 1000;
const drop: f32 = 5;
const carried: f32 = 0.25;
const spin: f32 = 0.01;
const end_size: f32 = 200;
const end_life = 50;

/// A countermeasure's smoke: how fast it leaves, a tick, and up to how much faster, and how far
/// it strays across either way; each stream lasts as long as the countermeasure.
const smoke_speed: f32 = 5;
const smoke_speed_range: f32 = 1;
const smoke_spread: Vector = .{ 0.25, 0.25, 0 };

/// How much more likely a countermeasure is to draw a missile away from a player's ship, and from
/// an AI whose pilot holds its countermeasures for 50 ticks at least (level 2 of `tier_c`), in
/// percent.
const player_bonus = 30;
const sharp_pilot_bonus = 50;
const sharp_pilot_least = 50;

/// The countermeasures in flight, and their model.
pub const Countermeasures = struct {
    gpa: Allocator,
    records: [max_countermeasures]?Countermeasure = @splat(null),
    /// `decoy_model` (`0x00541420`): `ships\decoy.shp`, where the game has it.
    model: ?objects.Mounts.Mounted,

    /// `decoys_init` (`0x00462390`), as a mission runs: none flying, and the model loaded.
    pub fn init(gpa: Allocator, mounts: ?objects.Mounts) Countermeasures {
        const loader = mounts orelse return .{ .gpa = gpa, .model = null };
        return .{ .gpa = gpa, .model = loader.load(loader.context, model_file) };
    }

    const model_file = "decoy.shp";

    /// `decoys_free` (`0x004624F0`) and the start of a mission: every countermeasure let go.
    pub fn reset(countermeasures: *Countermeasures) void {
        for (&countermeasures.records) |*record| {
            if (record.*) |*countermeasure| countermeasure.model.deinit(countermeasures.gpa);
            record.* = null;
        }
    }

    pub fn get(countermeasures: *Countermeasures, index: u8) ?*Countermeasure {
        return if (countermeasures.records[index]) |*countermeasure| countermeasure else null;
    }

    /// `object_spend_countermeasure` (`0x00462550`): the ship at `slot` drops a countermeasure,
    /// where it has one left, the player's with the display's beep; with none, the player's
    /// display refuses. It stands at the ship's tail where the step is taking it, turned as it
    /// will be, and drifts at a quarter of its velocity, dropping away 5 along its Y axis and 5
    /// back, trailing smoke from its nose and its tail, for 1000 ticks. Then each missile homing on
    /// the ship with no decoy, in the order of their records, rolls to be drawn away: its type's
    /// decoy chance, 30 more against a player's ship and 50 more against a sharp pilot's, in
    /// percent. The first drawn away takes it, and the rest keep homing: a countermeasure draws
    /// away one missile at most. With every countermeasure flying, or where memory runs out for
    /// its model, the ship's is spent for nothing.
    pub fn spend(countermeasures: *Countermeasures, world: gameobj.World, slot: u16) void {
        const all = world.objects;
        const ship = &all.slots[slot];
        const object = &ship.object;
        const player = slot == all.player;
        if (object.countermeasures < 1) {
            if (player) hud.beep(world, .refused);
            return;
        }
        object.countermeasures -= 1;
        if (player) hud.beep(world, .done);
        const at: u8 = for (countermeasures.records, 0..) |record, index| {
            if (record == null) break @intCast(index);
        } else return;
        const mounted = countermeasures.model orelse return;

        var model: objects.Model = objects.Model.create(countermeasures.gpa, mounted.model, mounted.loaded, .{}) catch return;
        gameobj.linkParts(&model, mounted.model);
        const orientation = object.root.next_orientation;
        model.place(math.transform(orientation, .{ 0, 0, object.bounds_min.z }) + object.nextPosition(), orientation);
        const velocity = gameobj.vector(object.velocity) * @as(Vector, @splat(carried)) + (math.yAxis(orientation) - math.forward(orientation)) * @as(Vector, @splat(drop));
        const bounds = if (model.parts.len > 0 and model.parts[0].object.levels.len > 0) model.parts[0].object.levels[0].mesh.bounds else [2]Vector{ @splat(0), @splat(0) };
        countermeasures.records[at] = .{
            .until = world.clock.frame_start + life,
            .owner = slot,
            .velocity = velocity,
            .model = model,
            .streams = .{ stream(world, .{ 0, 0, bounds[1][2] }, .{ 0, 0, 1 }), stream(world, .{ 0, 0, bounds[0][2] }, .{ 0, 0, -1 }) },
        };

        for (&all.missiles.records) |*record| {
            const missile = &(record.* orelse continue);
            if (missile.decoy != null or missile.target.index != slot) continue;
            var chance = missile.stats(&all.missile_stats).decoy_chance;
            if (slot < all.players) {
                chance += player_bonus;
            } else if (all.pilots.get(object.pilot).timings.countermeasures.least == sharp_pilot_least) {
                chance += sharp_pilot_bonus;
            }
            if (@mod(@as(i32, world.random.rand()), 100) < chance) {
                missile.decoy = at;
                break;
            }
        }
    }

    /// `decoys_update` (`0x00462900`), once a frame after the explosions: each countermeasure past
    /// its time ends; the rest turn about their Y axis, drift on by their velocity times the
    /// frame's ticks, and trail their smoke.
    ///
    /// **Quirk:** a countermeasure turns by one tick more than the frame's.
    pub fn frame(countermeasures: *Countermeasures, world: gameobj.World) void {
        const turn = math.fromAngles(0, spin * @as(f32, @floatFromInt(world.clock.frame_duration + 1)), 0);
        for (&countermeasures.records, 0..) |*record, index| {
            const countermeasure = &(record.* orelse continue);
            if (countermeasure.until < world.clock.frame_start) {
                countermeasures.end(world, @intCast(index));
                continue;
            }
            const drifted = countermeasure.model.position + countermeasure.velocity * @as(Vector, @splat(@floatFromInt(world.clock.frame_duration)));
            countermeasure.model.place(drifted, math.product(countermeasure.model.orientation, turn));
            const pool = world.particles orelse continue;
            const sending = world.sending() orelse continue;
            for (&countermeasure.streams) |*emitter| _ = pool.stream(emitter, countermeasure.place(), sending);
        }
    }

    /// `countermeasure_end` (`0x00462460`): every missile it drew away turns back to its target,
    /// and it ends in a fireball, 200 across over half a second, drifting as it did.
    pub fn end(countermeasures: *Countermeasures, world: gameobj.World, at: u8) void {
        const countermeasure = countermeasures.get(at) orelse return;
        for (&world.objects.missiles.records) |*record| {
            const missile = &(record.* orelse continue);
            if (missile.decoy == at) missile.decoy = null;
        }
        explode.fireballAt(world, countermeasure.model.position, .{ .kind = .sheet, .size = end_size, .life = end_life, .velocity = countermeasure.velocity });
        countermeasure.model.deinit(countermeasures.gpa);
        countermeasures.records[at] = null;
    }

    /// Adds each countermeasure's model to the world's layer.
    pub fn draw(countermeasures: *Countermeasures, gpa: Allocator, scene: *srcore.Scene, view: objects.View) Allocator.Error!void {
        for (&countermeasures.records) |*record| {
            const countermeasure = &(record.* orelse continue);
            try countermeasure.model.draw(gpa, scene, .world, view);
        }
    }
};

/// A countermeasure's stream of smoke, at `at` in its frame, leaving along `direction`.
fn stream(world: gameobj.World, at: Vector, direction: Vector) particles.Emitter {
    return .{
        .life = life,
        .born = world.clock.frame_start,
        .place = .{ .position = at },
        .direction = direction,
        .spread = smoke_spread,
        .speed = smoke_speed,
        .speed_range = smoke_speed_range,
        .template = &smoke,
    };
}

const testing = struct {
    /// Countermeasures of the fixture's own model, in an armed mission.
    const Stage = struct {
        armed: missiles.testing.Armed,
        dropped: Countermeasures,

        fn init(stage: *Stage) !void {
            try stage.armed.init(std.testing.allocator);
            stage.dropped = .init(std.testing.allocator, stage.armed.model.type.effects.mounts);
        }

        fn deinit(stage: *Stage) void {
            stage.dropped.reset();
            stage.armed.deinit();
        }

        fn world(stage: *Stage) gameobj.World {
            var reached = stage.armed.mission.world();
            reached.countermeasures = &stage.dropped;
            return reached;
        }
    };
};

test "Countermeasures.spend" {
    var stage: testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const world = stage.world();
    const all = stage.armed.mission.objects;
    const player = try stage.armed.add(.friendly, @splat(0));
    const enemy = try stage.armed.add(.hostile, .{ 0, 0, 20000 });
    all.slots[player].object.velocity = .{ .x = 0, .y = 0, .z = 40 };
    // Two Raptors at the player, sure to be drawn away.
    all.missile_stats.stats[1].decoy_chance = 100;
    const at_player: @import("aigeneric.zig").Target = .{ .kind = .ship, .index = @intCast(player), .component = -1 };
    missiles.launch(world, enemy, 0, at_player);
    missiles.launch(world, enemy, 0, at_player);

    // One drops behind the ship, drifting at a quarter of its speed, down and back, and draws one
    // missile away, the first in its records.
    const before = all.slots[player].object.countermeasures;
    stage.dropped.spend(world, player);
    try std.testing.expectEqual(before - 1, all.slots[player].object.countermeasures);
    const countermeasure = stage.dropped.get(0).?;
    try std.testing.expectEqual(math.Vector{ 0, drop, 10 - drop }, countermeasure.velocity);
    try std.testing.expectEqual(1000, countermeasure.until);
    try std.testing.expectEqual(0, stage.armed.missile(0).decoy);
    try std.testing.expectEqual(null, stage.armed.missile(1).decoy);

    // With none left, nothing is dropped.
    all.slots[player].object.countermeasures = 0;
    stage.dropped.spend(world, player);
    try std.testing.expectEqual(null, stage.dropped.get(1));
}

test "Countermeasures.frame" {
    var stage: testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const world = stage.world();
    const all = stage.armed.mission.objects;
    const clock = &stage.armed.mission.clock;
    const player = try stage.armed.add(.friendly, @splat(0));
    const enemy = try stage.armed.add(.hostile, .{ 0, 0, 20000 });
    all.missile_stats.stats[1].decoy_chance = 100;
    missiles.launch(world, enemy, 0, .{ .kind = .ship, .index = @intCast(player), .component = -1 });
    stage.dropped.spend(world, player);

    // It drifts by its velocity a tick, turning about its Y axis.
    clock.frame_duration = 2;
    const from = stage.dropped.get(0).?.model.position;
    stage.dropped.frame(world);
    const dropped = stage.dropped.get(0).?;
    try std.testing.expectEqual(from + dropped.velocity * @as(math.Vector, @splat(2)), dropped.model.position);
    // Past its time it ends, and the missile it drew away turns back to its target.
    clock.frame_start = 1001;
    stage.dropped.frame(world);
    try std.testing.expectEqual(null, stage.dropped.get(0));
    try std.testing.expectEqual(null, stage.armed.missile(0).decoy);
}

test "a missile drawn away catches its countermeasure" {
    var stage: testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const world = stage.world();
    const all = stage.armed.mission.objects;
    const clock = &stage.armed.mission.clock;
    const player = try stage.armed.add(.friendly, @splat(0));
    const enemy = try stage.armed.add(.hostile, .{ 0, 0, 20000 });
    all.missile_stats.stats[1].decoy_chance = 100;
    missiles.launch(world, enemy, 0, .{ .kind = .ship, .index = @intCast(player), .component = -1 });
    stage.dropped.spend(world, player);
    // Past its launch, it homes on the countermeasure and ends with it within 1000.
    const missile = stage.armed.missile(0);
    missile.slot.drawn.position = stage.dropped.get(0).?.model.position + math.Vector{ 0, 0, 500 };
    clock.frame_start = 50;
    missiles.frame(world, 0);
    try std.testing.expectEqual(null, stage.dropped.get(0));
    try std.testing.expectEqual(0, stage.armed.live());
}

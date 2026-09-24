//! `C:\lancer\game\explode.cpp`: an object's end, as it is seen and heard. The Explode order
//! ([`aiexplode.zig`](aiexplode.zig)) runs the ship down to it; here are the blast that ends it
//! and what the explosions leave for the frames after.
//!
//! Ported so far: the final blasts' sound, their bursts of flame and sparkle
//! ([`particles.zig`](particles.zig)), their fireballs, burning bits and shockwaves
//! ([`shockwave.zig`](shockwave.zig)), the break-up that cuts a ship's parts into pieces that fly
//! apart ([`explode/breakup.zig`](explode/breakup.zig)), and the point the camera watches a
//! break-up from. **Not ported:** the rest of the explosions' update
//! ([#41](https://github.com/vdmkenny/openreliant/issues/41)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srlight = @import("../surrender/surrenderlib/srlight.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const libcmt = @import("../libcmt.zig");
const matmanager = @import("matmanager.zig");
const objects = @import("objects.zig");
const particles = @import("particles.zig");
pub const breakup = @import("explode/breakup.zig");
const shockwave = @import("shockwave.zig");
const sound3d = @import("sound3d.zig");
const table = @import("table.zig");
const xtrabits = @import("xtrabits.zig");
const Clock = @import("main.zig").Clock;

/// What the explosions leave for the frames after them.
pub const Explosions = struct {
    images: Images,
    settings: Settings = .{},
    /// The pieces the bits are made of, which a mission loads as it starts.
    debris: Debris = .{},
    /// The bits flying (`explosion_bits`), as many as the detail holds: the next thrown
    /// (`explosion_bit_next`) takes the place of the oldest. When they last moved on
    /// (`explosion_bits_moved_at`). The game also counts them (`explosion_bit_count`), which
    /// nothing reads.
    bits: table.Ring(Bit, max_bits) = .{},
    moved_at: i32 = 0,
    /// The pieces the ships' break-ups send flying (`0x0055AE88`).
    pieces: breakup.Pieces,
    /// The fireballs going off (`explosion_fireballs`, `0x00553398`), in as many slots as the
    /// settings give them.
    fireballs: [Fireballs.fuller.slots()]?Fireball = @splat(null),
    /// The point view `0x1B` watches (`0x0055AD0C`), which the player's ship's break-up leaves where
    /// the ship blew up; null until it has.
    marker: ?Marker = null,

    pub const max_bits = Detail.high.bits();

    pub const Marker = struct {
        position: Vector,
        /// How far it drifts a tick (`0x0055AD10`): a quarter of the ship's velocity, which is a
        /// step's.
        drift: Vector,
    };

    /// The textures an explosion shows (`explosions_init`, `0x0046B240`).
    pub const Images = struct {
        /// The bang's frames, `explosion\bang_00000` to `bang_00015` (`0x00558734`).
        bang: [16]*srtexture.Image,
        /// Nine frames in a three by three sheet, `explosion\explosion sheet` (`0x00558730`).
        sheet: *srtexture.Image,

        /// The names `explosions_init` makes of `explosion\bang_000%02d`.
        const bang_names = names: {
            var names: [16][]const u8 = undefined;
            for (&names, 0..) |*name, n| name.* = std.fmt.comptimePrint("explosion\\bang_000{d:0>2}", .{n});
            break :names names;
        };

        pub fn load(textures: *srtexture.Table) (Allocator.Error || matmanager.Error)!Images {
            var images: Images = undefined;
            for (&images.bang, bang_names) |*image, name| image.* = try matmanager.textureRequire(textures, name);
            images.sheet = try matmanager.textureRequire(textures, "explosion\\explosion sheet");
            return images;
        }
    };

    pub fn init(gpa: Allocator, images: Images) Allocator.Error!Explosions {
        return .{ .images = images, .pieces = try .create(gpa) };
    }

    pub fn deinit(explosions: *Explosions) void {
        explosions.pieces.deinit();
    }

    /// As a mission starts again: nothing flying or going off, and no marker, with the same
    /// settings; the debris is loaded again (`Debris.load`).
    pub fn reset(explosions: *Explosions) void {
        explosions.pieces.reset();
        explosions.* = .{ .images = explosions.images, .settings = explosions.settings, .pieces = explosions.pieces };
    }

    /// `explosions_update` (`0x0046E480`), once a frame, as far as the port goes: the marker drifts
    /// on, the bits fly on, the pieces fly on (`breakup.Pieces.frame`), and each fireball plays on
    /// (`Fireball.frame`), until it is done.
    ///
    /// **Improvement:** the marker drifts by `drift` a tick, where the game adds it once a frame,
    /// which comes to the same at a frame a tick.
    pub fn frame(explosions: *Explosions, world: gameobj.World) void {
        const clock = world.clock;
        if (explosions.marker) |*marker| marker.position += marker.drift * @as(Vector, @splat(@floatFromInt(@max(clock.frame_duration, 0))));
        const seconds = @as(f32, @floatFromInt(clock.frame_start - explosions.moved_at)) * Bit.per_tick;
        for (&explosions.bits.slots) |*slot| {
            const bit = &(slot.* orelse continue);
            if (bit.born + bit.life < clock.frame_start) slot.* = null else bit.fly(seconds);
        }
        explosions.moved_at = clock.frame_start;
        explosions.pieces.frame(world);
        for (&explosions.fireballs) |*slot| {
            const fireball = &(slot.* orelse continue);
            if (!fireball.frame(clock)) slot.* = null;
        }
    }

    /// The rest of `explosions_update`: the bits and the pieces go into the world's layer, and
    /// each fireball showing, with its light among the lights, `ahead` of a tick past the frame's
    /// tick.
    pub fn draw(explosions: *Explosions, gpa: Allocator, scene: *srcore.Scene, ahead: f32) Allocator.Error!void {
        for (&explosions.bits.slots) |*slot| {
            const bit = &(slot.* orelse continue);
            bit.object.position = bit.at + bit.velocity * @as(Vector, @splat(ahead * Bit.per_tick));
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &bit.object }, .world);
        }
        try explosions.pieces.draw(gpa, scene, ahead);
        for (&explosions.fireballs) |*slot| {
            const fireball = &(slot.* orelse continue);
            if (!fireball.showing) continue;
            fireball.show(explosions.images, ahead);
            try xtrabits.sceneAdd(gpa, scene, .{ .sprites = &fireball.set }, .world);
            if (fireball.light) |*light| try xtrabits.sceneAdd(gpa, scene, .{ .light = light }, .background);
        }
    }

    /// `explosion_bit` (`0x004717D0`): throws a piece of debris out of `at` along `direction`, in
    /// the place of the oldest bit. It leaves at 1500 to 4500 a second times `how`'s speed, a
    /// little off its direction, turns a random way each frame, and flies for 17.5 to 22.5 seconds.
    ///
    /// The game can also throw a body, by a chance, or a chunk of rock, which no caller asks for;
    /// the port throws debris only, and draws the chance's number all the same. A piece the game
    /// has no model for is not thrown.
    pub fn throwBit(explosions: *Explosions, at: Vector, direction: Vector, how: Bit.Throw, clock: *const Clock, random: *libcmt.Rand) void {
        _ = random.rand();
        const piece = explosions.debris.pick(how.size, random) orelse return;
        const leaving = direction * @as(Vector, @splat((random.fraction() + 0.5) * Bit.speed));
        const stray = random.centredVector(@splat(Bit.stray));
        const velocity = math.transform(math.fromAngleVector(stray), leaving) * @as(Vector, @splat(how.speed));
        explosions.addBit(piece, at, velocity, Bit.flight, clock, random);
    }

    /// `0x00471B20`, a stream's spark (`particles.Emitter.spark`): a small piece of debris thrown
    /// out of `at` at `velocity` a second, in the place of the oldest bit, turning a random way each
    /// frame, for -1 to 3 seconds. One whose flight is over before it starts is let go before it is
    /// drawn, having still taken the oldest bit's place. A piece the game has no model for is not
    /// thrown.
    pub fn throwSpark(explosions: *Explosions, at: Vector, velocity: Vector, clock: *const Clock, random: *libcmt.Rand) void {
        const piece = explosions.debris.pick(Bit.spark_size, random) orelse return;
        explosions.addBit(piece, at, velocity, Bit.spark_flight, clock, random);
    }

    /// Puts `piece` in the place of the oldest bit, lit, at `at`, flying at `velocity` a second,
    /// turning a random way each frame, for `flight`'s ticks from now.
    fn addBit(explosions: *Explosions, piece: Debris.Picked, at: Vector, velocity: Vector, flight: Bit.Flight, clock: *const Clock, random: *libcmt.Rand) void {
        const spin = random.centredVector(@splat(Bit.tumble));
        explosions.bits.take(explosions.settings.detail.bits()).* = .{
            .born = clock.frame_start,
            .life = flight.draw(random),
            .object = .{
                .flags = .{ .lit = true },
                .light_mask = explosions.settings.debris_lights.mask(objects.lightMask(false)),
                .position = at,
                .scale = piece.scale,
                .radius = piece.levels[0].mesh.radius,
                .levels = piece.levels,
            },
            .at = at,
            .velocity = velocity,
            .spin = spin,
        };
    }

    /// `explosion_fireball` (`0x0046BD00`): sets a fireball off at `at`, into the first free of
    /// the slots the settings give, and not at all where there is none.
    pub fn setOff(explosions: *Explosions, at: Vector, spec: Fireball.Spec, clock: *const Clock, random: *libcmt.Rand) void {
        const style = explosions.settings.fireballs;
        const slot = table.firstFree(Fireball, explosions.fireballs[0..style.slots()]) orelse return;
        slot.* = .init(explosions.images, at, spec, style, clock, random);
    }
};

/// How the explosions are shown, which a mission's restart keeps.
pub const Settings = struct {
    /// The options' detail (`0x005D54E0`), which the port starts at high.
    detail: Detail = .high,
    debris_lights: DebrisLights = .like_ships,
    fireballs: Fireballs = .fuller,
};

/// How many fireballs go off at once, and how they light what is around them.
///
/// **Improvement:** `fuller` gives them room for 128, where the game keeps 30 and a burst takes 18,
/// so a second burst close after a first loses fireballs. A fireball's light moves with it as it
/// drifts, where the game leaves the light where the fireball went off, and starts 50% brighter, at
/// 15 where the game's starts at 10, so it also reaches 50% farther. Each frame of its animation
/// fades into the next (`Fireball.show`). `--original` restores the game's.
pub const Fireballs = enum {
    original,
    fuller,

    pub fn slots(style: Fireballs) usize {
        return switch (style) {
            .original => 30,
            .fuller => 128,
        };
    }

    /// A fireball's light as it goes off (the game's is `0x004DC520`).
    fn peak(style: Fireballs) f32 {
        return switch (style) {
            .original => 10,
            .fuller => 15,
        };
    }

    /// How long before the end of its `life` a fireball starts to fade out, still playing: over
    /// the last fifth of it, where the game's shows in full to the end and is gone at once.
    fn fadeOut(style: Fireballs, life: i32) i32 {
        return switch (style) {
            .original => 0,
            .fuller => @divTrunc(life, 5),
        };
    }
};

/// Which of the backdrop's lights reach an explosion's debris: its bits and a ship's pieces.
///
/// **Improvement:** debris takes the lights a ship's part takes, one of each pair. The game makes
/// it with a light mask of 0, so both key lights and both fill lights reach it, and it shows
/// washed out; `--original` restores that.
pub const DebrisLights = enum {
    like_ships,
    every_light,

    /// The mask for debris of a part whose own mask is `ship`.
    pub fn mask(lights: DebrisLights, ship: u32) u32 {
        return switch (lights) {
            .like_ships => ship,
            .every_light => 0,
        };
    }
};

/// The options' detail level, which sets how many bits the explosions keep flying.
pub const Detail = enum(u2) {
    low = 0,
    medium = 1,
    high = 2,

    /// `explosions_init`'s count of them.
    pub fn bits(detail: Detail) usize {
        return switch (detail) {
            .low => 100,
            .medium => 300,
            .high => 500,
        };
    }
};

/// A model's levels of detail, as a bit draws them: its first part's, their distances stretched so
/// that the bit keeps its detail further off. The game stretches the model's own.
pub const Levels = struct {
    levels: [max]srapiext.Level = undefined,
    count: u8 = 0,

    /// The levels a bit keeps: the finest, where a model has more.
    const max = 8;

    fn of(from: []const srapiext.Level, stretch: f32) Levels {
        var made: Levels = .{};
        for (from[0..@min(from.len, max)]) |level| {
            made.levels[made.count] = .{ .mesh = level.mesh, .until = level.until * stretch };
            made.count += 1;
        }
        return made;
    }

    fn slice(levels: *const Levels) []const srapiext.Level {
        return levels.levels[0..levels.count];
    }
};

/// The pieces of debris the bits are made of (`explosions_init`): the ten debris types' models,
/// their distances stretched by half again (`0x004DC4E0`).
pub const Debris = struct {
    pieces: [count]Levels = @splat(.{}),

    const count = 10;
    const stretch: f32 = 1.5;

    /// Each type's model, counted as used so that it stays loaded (`ship_type_first_levels`).
    pub fn load(all: *create.Objects, types: create.Types) Debris {
        var debris: Debris = .{};
        for (&debris.pieces, 0..) |*piece_levels, n| {
            const levels = xtrabits.firstLevels(all, types, @intCast(gameobj.Type.debris.number() + n)) orelse continue;
            piece_levels.* = .of(levels, stretch);
        }
        return debris;
    }

    /// A piece picked for a bit, and how large it is drawn.
    const Picked = struct {
        levels: []const srapiext.Level,
        scale: f32,
    };

    /// A piece for a bit, by a draw (`piece`), drawn at half to one and a half times `size` by
    /// another; null, drawing no more, where the game has no model for it.
    fn pick(debris: *const Debris, size: f32, random: *libcmt.Rand) ?Picked {
        const levels = debris.piece(random.fraction()).slice();
        if (levels.len == 0) return null;
        return .{ .levels = levels, .scale = (random.fraction() + 0.5) * size };
    }

    /// The piece for a draw of `r`: the first below a quarter, the last below a half, and one of
    /// the rest above.
    fn piece(debris: *const Debris, r: f32) *const Levels {
        if (r < 0.25) return &debris.pieces[0];
        if (r < 0.5) return &debris.pieces[count - 1];
        return &debris.pieces[1 + @as(usize, @intFromFloat((r - 0.5) * 16))];
    }
};

/// A bit an explosion throws out (0x28 bytes): a piece of debris, lit, flying off and tumbling for
/// a time.
pub const Bit = struct {
    /// When it was thrown and how long it flies, in ticks (`+0x00`, `+0x04`).
    born: i32,
    life: i32,
    object: srapiext.MeshObject,
    /// Where it is at the frame's tick, which the game keeps in its object; the object is drawn
    /// from here (`Explosions.draw`).
    at: Vector,
    /// How far it flies a second (`+0x10`), and its turn a frame, as angles (`+0x1C`).
    velocity: Vector,
    spin: Vector,

    /// How a bit is thrown: its size and its speed.
    pub const Throw = struct {
        size: f32,
        speed: f32,
    };

    /// How fast it leaves, a second, before its throw's speed: half this to half again
    /// (`0x004DC508`); and how far off its direction it may stray about each axis, and turn each
    /// frame, in radians, half of it either way (`0x004DC408`, `0x004DC420`).
    const speed: f32 = 3000;
    const stray: f32 = 0.5;
    const tumble: f32 = 0.1;
    /// How long it flies (`0x004DC83C`); and a spark's size, and how long it flies
    /// (`0x004DC844`).
    const flight: Flight = .{ .ticks = 2000, .spread = 500 };
    const spark_size: f32 = 0.1;
    const spark_flight: Flight = .{ .ticks = 100, .spread = 400 };

    /// How long a bit flies, in ticks, and how much more or less, half of `spread` either way.
    const Flight = struct {
        ticks: i32,
        spread: f32,

        fn draw(how_long: Flight, random: *libcmt.Rand) i32 {
            return how_long.ticks + @as(i32, @intFromFloat(random.centred() * how_long.spread));
        }
    };
    /// Its velocity is a second's, which is 100 ticks (`0x004DC518`).
    const per_tick: f32 = 0.01;

    /// Moves it on by `seconds` of its velocity, and turns it by its spin, once whatever the time.
    fn fly(bit: *Bit, seconds: f32) void {
        bit.at += bit.velocity * @as(Vector, @splat(seconds));
        bit.object.orientation = math.product(bit.object.orientation, math.fromAngleVector(bit.spin));
    }
};

/// A fireball going off (0x2C bytes): a sprite that plays an animation of fire where it was set
/// off, drifting, with a light that fades as it plays where it has one.
pub const Fireball = struct {
    /// Its sprite, and the set that draws it (`ExplodeParticle BMO`); its light
    /// (`ExplodeParticle Light`). A second sprite shows the next frame of its animation, which the
    /// first fades into, over the bang's next texture (`fading`).
    sprite: [2]srapiext.Sprite,
    set: srapiext.SpriteSet,
    fading: srapiext.Surface,
    light: ?srlight.Light,
    /// Where it is at the frame's tick, which the game keeps in its sprite, and how far it drifts
    /// a tick (`+0x08`). How long it had played at the frame's tick.
    at: Vector,
    velocity: Vector,
    age: i32 = 0,
    /// When it was set off, how long it plays and how long it waits first, in ticks (`+0x14`,
    /// `+0x18`, `+0x20`).
    born: i32,
    life: i32,
    delay: i32,
    look: Look,
    /// Whether it is coloured by how far it has played, from black to white (`+0x24`).
    lit: bool,
    /// Whether it showed at the last frame: past its wait, and not yet done.
    showing: bool = false,
    /// How it plays, and how its light burns and moves.
    style: Fireballs,

    /// How it plays, and whether it is mirrored (`+0x1C`): a word the game builds from its kind
    /// and two random bits.
    pub const Look = packed struct(u32) {
        /// The sheet's frames mirrored left for right, and top for bottom.
        mirror_u: bool,
        mirror_v: bool,
        /// The bang's sixteen frames, which it plays unmirrored; otherwise the sheet's nine.
        bang: bool,
        _: u29 = 0,

        /// The sheet's cell `at`, three across and three down, as a sprite's span of it,
        /// mirrored as the look says.
        fn cell(look: Look, at: u32) [4]f32 {
            const u = @as(f32, @floatFromInt(at % 3)) * sheet_step;
            const v = @as(f32, @floatFromInt(at / 3)) * sheet_step;
            const across: [2]f32 = if (look.mirror_u) .{ u + sheet_cell, u } else .{ u, u + sheet_cell };
            const down: [2]f32 = if (look.mirror_v) .{ v + sheet_cell, v } else .{ v, v + sheet_cell };
            return .{ across[0], across[1], down[0], down[1] };
        }
    };

    /// What `explosion_fireball` is given.
    pub const Spec = struct {
        kind: Kind = .bang,
        /// How far it reaches either side of its centre.
        size: f32,
        life: i32 = 150,
        /// Whether it lights what is around it.
        light: bool = false,
        delay: i32 = 0,
        lit: bool = false,
        velocity: Vector = @splat(0),
    };

    pub const Kind = enum { bang, sheet };

    /// The light's colour, and how far it reaches: its intensity times the square root of its size
    /// times `light_reach` (`0x004DC48C`). Its intensity fades from the style's peak to nothing as
    /// it plays.
    const light_colour = [3]f32{ 1, 0.5, 0.1 };
    const light_reach: f32 = 50;

    /// The sheet's frames: each `sheet_step` across and down from the last, `sheet_cell` across
    /// (`0x004DC82C`, `0x004DC828`: 82 and 81 of its 256 texels).
    const sheet_step: f32 = 82.0 / 256.0;
    const sheet_cell: f32 = 81.0 / 256.0;

    fn init(images: Explosions.Images, at: Vector, spec: Spec, style: Fireballs, clock: *const Clock, random: *libcmt.Rand) Fireball {
        var set: srapiext.SpriteSet = .{ .sprites = &.{} };
        set.surface.material.lit[0] = spec.lit;
        set.surface.material.blend[0] = .premultiplied;
        const image = switch (spec.kind) {
            .bang => images.bang[0],
            .sheet => images.sheet,
        };
        set.surface.textures = .{ .{ .image = image }, .none };
        const mirrors: u2 = @truncate(random.rand());
        const sprite: srapiext.Sprite = .{ .offset = at, .half_size = .{ spec.size, spec.size }, .bias = -spec.size };
        return .{
            .sprite = .{ sprite, sprite },
            .set = set,
            .fading = set.surface,
            .light = if (spec.light) .{
                .mask = 0,
                .intensity = style.peak(),
                .colour = light_colour,
                .kind = .{ .point = .{ .position = at, .range = @sqrt(spec.size) * light_reach } },
            } else null,
            .at = at,
            .velocity = spec.velocity,
            .born = clock.frame_start,
            .life = spec.life,
            .delay = spec.delay,
            .look = .{ .mirror_u = mirrors & 1 != 0, .mirror_v = mirrors & 2 != 0, .bang = spec.kind == .bang },
            .lit = spec.lit,
            .style = style,
        };
    }

    /// Plays on for the frame, once its wait is over: its age and its drift. Whether it is still
    /// going.
    fn frame(fireball: *Fireball, clock: *const Clock) bool {
        const age = clock.frame_start - fireball.delay - fireball.born;
        fireball.showing = false;
        if (age < 0) return true;
        if (age >= fireball.life) return false;
        fireball.age = age;
        fireball.at += fireball.velocity * @as(Vector, @splat(@floatFromInt(clock.frame_duration)));
        fireball.showing = true;
        return true;
    }

    /// How it shows, `ahead` of a tick past the frame's tick: the frame of its animation this far
    /// through its life, where it has drifted to, its colour where it is lit, and its light's fade.
    ///
    /// **Improvement:** with the `fuller` style, each frame of its animation fades into the next,
    /// where the game flips from one to the next: sixteen or nine over a second and a half. It
    /// fades out as its last frames play, where the game's vanishes after the last. It is drawn
    /// further along between the ticks as well (`particles.Pool.draw`).
    fn show(fireball: *Fireball, images: Explosions.Images, ahead: f32) void {
        const frames: u32 = if (fireball.look.bang) 16 else 9;
        const life: f32 = @floatFromInt(fireball.life);
        const played = @min((@as(f32, @floatFromInt(fireball.age)) + ahead) / life, 1);
        const step = @min((@as(f32, @floatFromInt(fireball.age * @as(i32, @intCast(frames)))) + ahead * @as(f32, @floatFromInt(frames))) / life, @as(f32, @floatFromInt(frames - 1)));
        const first: u32 = @intFromFloat(step);
        const next = @min(first + 1, frames - 1);
        const fade: f32 = if (fireball.style == .fuller and next > first) step - @as(f32, @floatFromInt(first)) else 0;
        const kept = fireball.left(ahead);
        const offset = fireball.at + fireball.velocity * @as(Vector, @splat(ahead));
        for (&fireball.sprite, [2]u32{ first, next }, [2]f32{ 1 - fade, fade }) |*sprite, cell, share| {
            sprite.offset = offset;
            sprite.fade = share * kept;
            if (fireball.lit) sprite.colour = @splat(played);
            if (!fireball.look.bang) sprite.uv = fireball.look.cell(cell);
        }
        if (fireball.look.bang) {
            fireball.set.surface.textures[0].image = images.bang[first];
            fireball.fading = fireball.set.surface;
            fireball.fading.textures[0].image = images.bang[next];
            fireball.sprite[1].surface = &fireball.fading;
        }
        fireball.set.sprites = fireball.sprite[0..if (fade > 0) 2 else 1];
        if (fireball.light) |*light| {
            light.intensity = fireball.style.peak() * (1 - played);
            if (fireball.style == .fuller) light.kind.point.position = offset;
        }
    }

    /// How much of it shows `ahead` of a tick past the frame's tick: all of it until its style
    /// fades it out, then less and less, to nothing as its life ends.
    fn left(fireball: Fireball, ahead: f32) f32 {
        const out = fireball.style.fadeOut(fireball.life);
        if (out == 0) return 1;
        const to_go = @as(f32, @floatFromInt(fireball.life - fireball.age)) - ahead;
        return std.math.clamp(to_go / @as(f32, @floatFromInt(out)), 0, 1);
    }
};

/// Within this far of the camera an explosion is sure of a voice (`0x004DC4BC`, its square).
const close: f32 = 20000;

/// The voice class an explosion at `at` is heard on: sure of a voice close to the camera, one of the
/// explosions' own further off.
pub fn soundClass(world: gameobj.World, at: Vector) ?sound3d.Class {
    const hearing = world.hearing orelse return null;
    const offset = at - hearing.camera.position;
    return if (math.dot(offset, offset) < close * close) .guaranteed else .explosions;
}

/// Plays the first explosion's sound at `at`, on `class`.
pub fn sound(world: gameobj.World, at: Vector, class: sound3d.Class) void {
    const hearing = world.hearing orelse return;
    _ = sound3d.play(hearing.sound, hearing.scene(world), at, null, -1, .explosion01, 1, class);
}

/// The flame a blast bursts into (`0x00553348`): five to six seconds of it, growing from nothing
/// to a half-size of 400 as it goes from yellowish white through orange to nothing. It thins
/// slowly with distance.
pub const flame: particles.Template = .{
    .life = 500,
    .life_spread = 100,
    .size = .through(0, 100, 400),
    .colour = .{ .through(1, 0.75, 0), .through(1, 0.25, 0), .through(0, 0, 0) },
    .distance = 0.05,
};

/// The sparkle a blast leaves (`0x0055334C`): specks of white, 25 across either way, that last one
/// to six seconds and fade out.
pub const sparkle: particles.Template = .{
    .life = 100,
    .life_spread = 500,
    .size = .through(0, 25, 25),
    .colour = .{ .through(1, 1, 0), .through(1, 1, 0), .through(1, 1, 0) },
};

/// How much of a ship's velocity, a step's, the particles of its blast carry on with, a tick's.
const Carried = union(enum) {
    /// This share of it.
    share: f32,
    /// This share and up to as much again, at random.
    share_or_more: f32,

    fn of(carried: Carried, random: *libcmt.Rand) f32 {
        return switch (carried) {
            .share => |share| share,
            .share_or_more => |share| (random.fraction() + 1) * share,
        };
    }
};

/// How a blast's flame leaves it: how fast, a tick, how much of the ship's velocity it carries, and
/// how many.
const Flames = struct {
    speed: f32,
    speed_range: f32,
    carried: Carried,
    count: i32,
};

/// Sends `count` particles out of `emitter` at once, as the camera sees them.
fn burstFrom(world: gameobj.World, emitter: *particles.Emitter, count: i32) void {
    const pool = world.particles orelse return;
    pool.burst(emitter, null, count, world.sending() orelse return);
}

/// A burst of `flame` from a ship at `at`, moving at `velocity`, spreading out mostly across the
/// view: the emitter stands turned 60 degrees back and a random way about the camera's forward
/// axis, from the camera's orientation. Returns the emitter, whose place and carried velocity a
/// blast's shockwave takes; none without a camera.
fn flames(world: gameobj.World, at: Vector, velocity: Vector, how: Flames) ?particles.Emitter {
    const view = (world.camera orelse return null).place;
    const turn = math.fromAngles(-std.math.pi / 3.0, 0, world.random.fraction() * std.math.tau);
    var emitter: particles.Emitter = .{
        .born = world.clock.frame_start,
        .template = &flame,
        .place = .{ .position = at, .orientation = math.product(turn, view.orientation) },
        .spread = .{ 1, 1, 0.2 },
        .speed = how.speed,
        .speed_range = how.speed_range,
        .inherited = velocity * @as(Vector, @splat(how.carried.of(world.random))),
    };
    burstFrom(world, &emitter, how.count);
    return emitter;
}

/// How a burst of sparkle leaves: of which template, how fast, a tick, and how many.
const Sparkles = struct {
    template: *const particles.Template = &sparkle,
    speed_range: f32 = 7,
    count: i32 = 150,
};

/// The sparkle a missile leaves (`missile_explode`), `sparkle`'s for one to three seconds: 50 of
/// it, slower than a ship's.
const missile_sparkle: particles.Template = sparkled: {
    var template = sparkle;
    template.life_spread = 200;
    break :sparkled template;
};
const missile_sparkles: Sparkles = .{ .template = &missile_sparkle, .speed_range = 4, .count = 50 };

/// A burst of sparkle from something at `at`, moving at `velocity`, carrying `carried` of it,
/// drifting every way.
fn sparkles(world: gameobj.World, at: Vector, velocity: Vector, carried: f32, how: Sparkles) void {
    var emitter: particles.Emitter = .{
        .born = world.clock.frame_start,
        .template = how.template,
        .place = .{ .position = at },
        .spread = .{ 1, 1, 1 },
        .speed_range = how.speed_range,
        .inherited = velocity * @as(Vector, @splat(carried)),
    };
    burstFrom(world, &emitter, how.count);
}

/// Sets a fireball off at `at`, where the world has explosions.
pub fn fireballAt(world: gameobj.World, at: Vector, spec: Fireball.Spec) void {
    const explosions = world.explosions orelse return;
    explosions.setOff(at, spec, world.clock, world.random);
}

/// A throw of bits every way: how many, and how.
const Scatter = struct {
    count: usize,
    throw: Bit.Throw,
};

/// Throws `how`'s bits out of `at` every way, where the world has explosions.
fn scatter(world: gameobj.World, at: Vector, how: Scatter) void {
    const explosions = world.explosions orelse return;
    for (0..how.count) |_| {
        const direction = math.normalize(world.random.centredVector(@splat(1)));
        explosions.throwBit(at, direction, how.throw, world.clock, world.random);
    }
}

/// Throws a bit out of `at`, where the world has explosions.
pub fn throwBit(world: gameobj.World, at: Vector, direction: Vector, how: Bit.Throw) void {
    const explosions = world.explosions orelse return;
    explosions.throwBit(at, direction, how, world.clock, world.random);
}

/// The fireballs a burst sets off about the ship, lit and each a little late, within
/// `burst_spread` of its radius, 0.8 of it across (`0x004DC4C0`, `0x004DC410`).
const burst_fireballs = 18;
const burst_spread: f32 = 0.3;
const burst_size: f32 = 0.8;
const burst_delay: f32 = 10;

/// The bits a blast throws, and fewer, smaller and slower for an escape pod, a mine and a ship its
/// pilot left; and a burst's.
const blast_bits: Scatter = .{ .count = 25, .throw = .{ .size = 0.4, .speed = 0.2 } };
const small_blast_bits: Scatter = .{ .count = 5, .throw = .{ .size = 0.2, .speed = 0.1 } };
const burst_bits: Scatter = .{ .count = 25, .throw = .{ .size = 0.2, .speed = 0.2 } };

/// A blast sets a shockwave off one time in `blast_shockwave_odds`: `blast_shockwave_size` times
/// the ship's radius across (`0x004DC520`), over `blast_shockwave_life` ticks and up to
/// `blast_shockwave_life_range` more.
const blast_shockwave_odds = 4;
const blast_shockwave_size: f32 = 10;
const blast_shockwave_life = 100;
const blast_shockwave_life_range = 50;

/// `0x0046C980`: a ship's blast at the end of its Explode order: the ship broken up
/// (`breakup.breakUp`), burning bits thrown every way, a burst of flame, fast and wide, now and then a shockwave standing and drifting as the flame's
/// emitter does, one of sparkle, a lit fireball of the ship's size drifting on with the sparkle,
/// and the sound, heard on a sure voice close to the camera.
///
/// Not ported: the cloak dropped.
pub fn blast(world: gameobj.World, index: u16) void {
    const slot = &world.objects.slots[index];
    const at = slot.drawn.position;
    const velocity = gameobj.vector(slot.object.velocity);
    const small = slot.object.flags.ejected or switch (slot.object.type) {
        .escape_pod, .other_escape_pod, .late_escape_pod, .other_late_escape_pod, .proximity_mine => true,
        else => false,
    };
    breakup.breakUp(world, index, .blast);
    scatter(world, at, if (small) small_blast_bits else blast_bits);
    const emitted = flames(world, at, velocity, .{ .speed = 200, .speed_range = 300, .carried = .{ .share_or_more = 0.25 }, .count = 400 });
    const random = world.random;
    if (random.rand() % blast_shockwave_odds == 0) {
        const life = @as(i32, random.rand() % blast_shockwave_life_range) + blast_shockwave_life;
        const kind = shockwave.Kind.blasts[random.rand() % shockwave.Kind.blasts.len];
        if (emitted) |emitter| shockwave.setOff(world, emitter.place, .{
            .kind = kind,
            .size = slot.object.radius * blast_shockwave_size,
            .life = life,
            .velocity = emitter.inherited,
            .owner = index,
        });
    }
    const carried = 0.25;
    sparkles(world, at, velocity, carried, .{});
    fireballAt(world, at, .{ .size = slot.object.radius, .light = true, .velocity = velocity * @as(Vector, @splat(carried)) });
    sound(world, at, soundClass(world, at) orelse return);
}

/// A missile's fireball: three times its radius across, over a second.
const missile_fireball_size: f32 = 3;
const missile_fireball_life = 100;

/// `missile_explode` (`0x0046E370`), from a missile's end at `at`: a burst of sparkle and a lit
/// fireball from the sheet, both drifting on at a quarter of its velocity, and the first
/// explosion's sound, heard among the explosions.
pub fn missileBlast(world: gameobj.World, at: Vector, velocity: Vector, radius: f32) void {
    const carried = 0.25;
    sparkles(world, at, velocity, carried, missile_sparkles);
    fireballAt(world, at, .{
        .kind = .sheet,
        .size = radius * missile_fireball_size,
        .life = missile_fireball_life,
        .light = true,
        .velocity = velocity * @as(Vector, @splat(carried)),
    });
    sound(world, at, .explosions);
}

/// `0x00471DB0`: the blast of a ship that bursts: a slower burst of flame and one of sparkle, heard
/// among the explosions. The player's leaves the marker the camera watches, drifting on at the
/// ship's speed. **Unverified:** it lies after this file's known code.
///
/// It breaks the ship up and throws small bits every way first. Its 18 fireballs, lit and each up to a tenth of a second
/// late, stand at random within 0.3 of its radius and drift on with the sparkle.
///
/// Not ported: the cloak dropped.
pub fn burst(world: gameobj.World, index: u16) void {
    const slot = &world.objects.slots[index];
    const at = slot.drawn.position;
    const velocity = gameobj.vector(slot.object.velocity);
    const radius = slot.object.radius;
    breakup.breakUp(world, index, .burst);
    scatter(world, at, burst_bits);
    if (index == world.objects.player) if (world.explosions) |explosions| {
        explosions.marker = .{ .position = at, .drift = velocity * @as(Vector, @splat(0.25)) };
    };
    _ = flames(world, at, velocity, .{ .speed = 20, .speed_range = 5, .carried = .{ .share = 0.25 }, .count = 200 });
    const carried = 0.5;
    sparkles(world, at, velocity, carried, .{});
    const random = world.random;
    for (0..burst_fireballs) |_| {
        const out: Vector = .{ random.fraction() * radius * burst_spread, 0, 0 };
        const turn = random.fractionVector(@splat(std.math.tau));
        const place = math.transform(math.fromAngleVector(turn), out) + at;
        const delay: i32 = @intFromFloat(random.fraction() * burst_delay);
        fireballAt(world, place, .{ .size = radius * burst_size, .light = true, .delay = delay, .velocity = velocity * @as(Vector, @splat(carried)) });
    }
    sound(world, at, .explosions);
}

pub const testing = struct {
    /// Textures that are never looked into, one for each frame, told apart by where they are.
    var bang: [16]srtexture.Image = undefined;
    var sheet: srtexture.Image = undefined;

    fn images() Explosions.Images {
        var found: Explosions.Images = .{ .bang = undefined, .sheet = &sheet };
        for (&found.bang, &bang) |*image, *texture| image.* = texture;
        return found;
    }

    /// Every piece of debris the one mesh, at two levels.
    fn debris(mesh: *const srapiext.Mesh) Debris {
        const levels = [_]srapiext.Level{ .{ .mesh = mesh, .until = 1000 }, .{ .mesh = mesh, .until = 5000 } };
        return .{ .pieces = @splat(.of(&levels, Debris.stretch)) };
    }

    /// How many of the pool's particles are in use.
    fn sent(pool: *const particles.Pool) usize {
        var count: usize = 0;
        for (pool.particles) |particle| count += @intFromBool(particle.template != null);
        return count;
    }

    fn flying(explosions: *const Explosions) usize {
        var count: usize = 0;
        for (explosions.bits.slots) |slot| count += @intFromBool(slot != null);
        return count;
    }

    /// A mission with explosions over it, whose world reaches them.
    pub const Stage = struct {
        mission: gameobj.testing.Mission,
        explosions: Explosions,

        pub fn init(stage: *Stage) !void {
            try stage.mission.init(std.testing.allocator);
            errdefer stage.mission.deinit();
            stage.explosions = try .init(std.testing.allocator, images());
        }

        pub fn deinit(stage: *Stage) void {
            stage.explosions.deinit();
            stage.mission.deinit();
        }

        pub fn world(stage: *Stage) gameobj.World {
            var reached = stage.mission.world();
            reached.explosions = &stage.explosions;
            return reached;
        }
    };
};

test Explosions {
    var stage: testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const explosions = &stage.explosions;
    stage.mission.clock.frame_duration = 10;
    explosions.frame(stage.world());
    try std.testing.expectEqual(null, explosions.marker);
    explosions.marker = .{ .position = .{ 0, 0, 100 }, .drift = .{ 0, 0, 5 } };
    explosions.frame(stage.world());
    try std.testing.expectEqual(Vector{ 0, 0, 150 }, explosions.marker.?.position);
}

test Fireball {
    var stage: testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const explosions = &stage.explosions;
    const clock = &stage.mission.clock;
    var random: libcmt.Rand = .{};
    explosions.setOff(.{ 0, 0, 100 }, .{ .size = 40, .light = true, .delay = 10, .velocity = .{ 1, 0, 0 } }, clock, &random);
    const bang = &explosions.fireballs[0].?;
    try std.testing.expectEqual(-40, bang.sprite[0].bias);

    // Waiting, it doesn't show.
    clock.frame_start = 5;
    explosions.frame(stage.world());
    try std.testing.expect(!bang.showing);

    // Halfway through its life, the bang's middle frame alone, drifted on, its light half faded
    // and drifting with it.
    clock.frame_start = 10 + 75;
    clock.frame_duration = 20;
    explosions.frame(stage.world());
    try std.testing.expect(bang.showing);
    bang.show(explosions.images, 0);
    try std.testing.expectEqual(&testing.bang[8], bang.set.surface.textures[0].image);
    try std.testing.expectEqual(1, bang.set.sprites.len);
    try std.testing.expectEqual(Vector{ 20, 0, 100 }, bang.sprite[0].offset);
    try std.testing.expectApproxEqAbs(Fireballs.fuller.peak() / 2, bang.light.?.intensity, 1e-6);
    try std.testing.expectEqual([3]f32{ 20, 0, 100 }, bang.light.?.kind.point.position);

    // Drawn half a tick on, it has drifted on half a tick more and begun to fade into the next.
    bang.show(explosions.images, 0.5);
    try std.testing.expectEqual(Vector{ 20.5, 0, 100 }, bang.sprite[0].offset);
    try std.testing.expectEqual(2, bang.set.sprites.len);
    try std.testing.expectEqual(&testing.bang[9], bang.sprite[1].surface.?.textures[0].image);
    const fade = 0.5 * 16.0 / 150.0;
    try std.testing.expectApproxEqAbs(fade, bang.sprite[1].fade, 1e-5);
    try std.testing.expectApproxEqAbs(1 - fade, bang.sprite[0].fade, 1e-5);

    // The original's flips from frame to frame, is dimmer, and its light stays where it went off.
    bang.style = .original;
    bang.light.?.kind.point.position = .{ 0, 0, 100 };
    bang.show(explosions.images, 0.5);
    try std.testing.expectEqual(1, bang.set.sprites.len);
    try std.testing.expectEqual(1, bang.sprite[0].fade);
    try std.testing.expectEqual([3]f32{ 0, 0, 100 }, bang.light.?.kind.point.position);
    bang.show(explosions.images, 0);
    try std.testing.expectApproxEqAbs(Fireballs.original.peak() / 2, bang.light.?.intensity, 1e-6);

    // The sheet steps through its cells, mirrored as its look says.
    explosions.setOff(@splat(0), .{ .kind = .sheet, .size = 10, .life = 90 }, clock, &random);
    const sheet = &explosions.fireballs[1].?;
    sheet.look.mirror_u = true;
    sheet.look.mirror_v = false;
    clock.frame_start += 50;
    explosions.frame(stage.world());
    sheet.show(explosions.images, 0);
    const u = 2 * Fireball.sheet_step;
    const v = 1 * Fireball.sheet_step;
    try std.testing.expectEqual([4]f32{ u + Fireball.sheet_cell, u, v, v + Fireball.sheet_cell }, sheet.sprite[0].uv);

    // Done, it is gone.
    clock.frame_start += 200;
    explosions.frame(stage.world());
    try std.testing.expectEqual(null, explosions.fireballs[0]);
    try std.testing.expectEqual(null, explosions.fireballs[1]);
}

test burst {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var explosions: Explosions = try .init(std.testing.allocator, testing.images());
    defer explosions.deinit();
    var world = mission.world();
    world.explosions = &explosions;
    const player = try mission.add(.predator, .{ 0, 0, 0 });
    const other = try mission.add(.sabre, .{ 0, 0, 1000 });
    mission.objects.slots[player].object.velocity = .{ .x = 0, .y = 0, .z = 40 };

    // Another ship's burst leaves no marker, but 18 lit fireballs, each up to a tenth of a second
    // late; the player's leaves one drifting at its speed.
    burst(world, other);
    try std.testing.expectEqual(null, explosions.marker);
    for (explosions.fireballs[0..burst_fireballs]) |slot| {
        const set = slot.?;
        try std.testing.expect(set.light != null and set.delay < 10);
    }
    try std.testing.expectEqual(null, explosions.fireballs[burst_fireballs]);
    burst(world, player);
    try std.testing.expectEqual(Vector{ 0, 0, 10 }, explosions.marker.?.drift);

    // Both bursts' fireballs have room; the original's 30 leave part of the second's out.
    for (explosions.fireballs[0 .. 2 * burst_fireballs]) |slot| try std.testing.expect(slot != null);
    explosions.fireballs = @splat(null);
    explosions.settings.fireballs = .original;
    burst(world, other);
    burst(world, player);
    for (explosions.fireballs[0..Fireballs.original.slots()]) |slot| try std.testing.expect(slot != null);
    try std.testing.expectEqual(null, explosions.fireballs[Fireballs.original.slots()]);
}

test "a fireball's fade" {
    var clock: Clock = .{};
    var random: libcmt.Rand = .{};
    const spec: Fireball.Spec = .{ .size = 100 };

    // The fuller style fades it out over the last fifth of its life as it plays on.
    var fireball: Fireball = .init(testing.images(), @splat(0), spec, .fuller, &clock, &random);
    clock.frame_start = 120;
    try std.testing.expect(fireball.frame(&clock));
    fireball.show(testing.images(), 0);
    try std.testing.expectApproxEqAbs(1, fireball.sprite[0].fade + fireball.sprite[1].fade, 1e-6);
    clock.frame_start = 135;
    try std.testing.expect(fireball.frame(&clock));
    fireball.show(testing.images(), 0);
    try std.testing.expectApproxEqAbs(0.5, fireball.sprite[0].fade + fireball.sprite[1].fade, 1e-6);
    try std.testing.expectEqual(2, fireball.set.sprites.len);
    clock.frame_start = 150;
    try std.testing.expect(!fireball.frame(&clock));

    // The game's shows in full to the end.
    fireball = .init(testing.images(), @splat(0), spec, .original, &clock, &random);
    clock.frame_start += 149;
    try std.testing.expect(fireball.frame(&clock));
    fireball.show(testing.images(), 0.5);
    try std.testing.expectEqual(1, fireball.sprite[0].fade);
}

test blast {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var image: @import("../surrender/surrenderlib/srtexture.zig").Image = undefined;
    var pool: particles.Pool = try .init(std.testing.allocator, 1000, &image, .add);
    defer pool.deinit();
    var watching: @import("camera.zig").Camera = .{};
    var explosions: Explosions = try .init(std.testing.allocator, testing.images());
    defer explosions.deinit();
    var world = mission.world();
    world.particles = &pool;
    world.camera = &watching;
    world.explosions = &explosions;
    mission.clock.frame_start = 10;
    _ = try mission.add(.predator, @splat(0));
    const ship = try mission.add(.sabre, @splat(0));
    mission.objects.slots[ship].drawn.position = .{ 0, 0, 5000 };

    // In view 5000 off, all 400 of the flame and all 150 of the sparkle.
    blast(world, ship);
    try std.testing.expectEqual(400 + 150, testing.sent(&pool));
    // And one lit fireball of the ship's size.
    try std.testing.expect(explosions.fireballs[0].?.light != null);
    try std.testing.expectEqual(null, explosions.fireballs[1]);

    // The original thins them: all 400 of the flame, which thins slowly, and three quarters of the
    // sparkle, its half-size of 25 times 150 over the distance. The rounding is even.
    pool.reset();
    pool.settings.distant = .thinned;
    blast(world, ship);
    try std.testing.expectEqual(400 + 112, testing.sent(&pool));
}

test Bit {
    const gpa = std.testing.allocator;
    const mesh = try @import("../surrender/surrenderlib/srmesh.zig").testing.square(gpa);
    defer mesh.deinit(gpa);
    var stage: testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const explosions = &stage.explosions;
    explosions.debris = testing.debris(&mesh);
    explosions.settings.detail = .low;
    const clock = &stage.mission.clock;
    var random: libcmt.Rand = .{};

    // A bit is lit, keeps its detail further off, and leaves along its direction at 1500 to 4500
    // a second times its throw's speed, for 17.5 to 22.5 seconds.
    explosions.throwBit(.{ 0, 0, 100 }, .{ 0, 0, 1 }, .{ .size = 0.4, .speed = 0.2 }, clock, &random);
    const bit = &explosions.bits.slots[0].?;
    try std.testing.expect(bit.object.flags.lit);
    try std.testing.expectEqual(objects.lightMask(false), bit.object.light_mask);
    try std.testing.expectEqual(1500, bit.object.levels[0].until);
    try std.testing.expect(bit.velocity[2] > 0);
    const speed = math.length(bit.velocity);
    try std.testing.expect(speed >= 300 and speed <= 900);
    try std.testing.expect(bit.life >= 1750 and bit.life <= 2250);

    // A second later it has flown a second's velocity, and turned.
    const from = bit.at;
    clock.frame_start = 100;
    explosions.frame(stage.world());
    try std.testing.expect(math.distance(from + bit.velocity, bit.at) < 1e-3);
    try std.testing.expect(!std.meta.eql(math.identity, bit.object.orientation));

    // Past its life, it is gone.
    clock.frame_start = bit.born + bit.life + 1;
    explosions.frame(stage.world());
    try std.testing.expectEqual(null, explosions.bits.slots[0]);

    // As the original has it, every light reaches it.
    explosions.settings.debris_lights = .every_light;
    const index = explosions.bits.next;
    explosions.throwBit(@splat(0), .{ 0, 0, 1 }, .{ .size = 1, .speed = 1 }, clock, &random);
    try std.testing.expectEqual(0, explosions.bits.slots[index].?.object.light_mask);
    explosions.reset();
    try std.testing.expectEqual(.every_light, explosions.settings.debris_lights);
    explosions.debris = testing.debris(&mesh);

    // The detail sets how many fly: at low, the 101st takes the first's place.
    for (0..Detail.low.bits() + 1) |_| explosions.throwBit(@splat(0), .{ 0, 0, 1 }, .{ .size = 1, .speed = 1 }, clock, &random);
    try std.testing.expectEqual(Detail.low.bits(), testing.flying(explosions));
    try std.testing.expectEqual(1, explosions.bits.next);
}

test "Explosions.throwSpark" {
    const gpa = std.testing.allocator;
    const mesh = try @import("../surrender/surrenderlib/srmesh.zig").testing.square(gpa);
    defer mesh.deinit(gpa);
    var stage: testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const explosions = &stage.explosions;
    explosions.debris = testing.debris(&mesh);
    const clock = &stage.mission.clock;
    clock.frame_start = 10;
    var random: libcmt.Rand = .{};

    // A spark is a small bit that flies as fast as it is thrown, for -1 to 3 seconds.
    explosions.throwSpark(.{ 0, 0, 100 }, .{ 0, 0, 500 }, clock, &random);
    const spark = &explosions.bits.slots[0].?;
    try std.testing.expectEqual(Vector{ 0, 0, 500 }, spark.velocity);
    try std.testing.expectEqual(Vector{ 0, 0, 100 }, spark.at);
    try std.testing.expect(spark.object.scale >= 0.05 and spark.object.scale <= 0.15);
    try std.testing.expect(spark.life >= -100 and spark.life <= 300);
    try std.testing.expectEqual(10, spark.born);
}

test "a stream's sparks" {
    const gpa = std.testing.allocator;
    const mesh = try @import("../surrender/surrenderlib/srmesh.zig").testing.square(gpa);
    defer mesh.deinit(gpa);
    var stage: testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const explosions = &stage.explosions;
    explosions.debris = testing.debris(&mesh);
    var image: srtexture.Image = undefined;
    var pool: particles.Pool = try .init(gpa, 8, &image, .add);
    defer pool.deinit();
    const clock = &stage.mission.clock;
    clock.frame_duration = 4;

    // A template of sparks sends no particles, and a spark for each particle of the pool it
    // passes, leaving at the emitter's speed, a second's, where the emitter stands.
    const sparking: particles.Template = .{ .kind = .sparks, .life = 100, .rate = .through(100, 100, 100), .size = .through(1, 1, 1), .colour = @splat(.through(1, 1, 1)) };
    var emitter: particles.Emitter = .{ .born = 0, .life = 100, .template = &sparking, .place = .{ .position = .{ 0, 0, 50 } }, .direction = .{ 0, 0, 1 }, .speed = 2 };
    const sending: particles.Sending = .{ .view = .{}, .clock = clock, .random = &stage.mission.random, .explosions = explosions };
    try std.testing.expect(pool.stream(&emitter, null, sending));
    try std.testing.expectEqual(0, pool.used);
    try std.testing.expectEqual(8, testing.flying(explosions));
    const spark = explosions.bits.slots[0].?;
    try std.testing.expectEqual(Vector{ 0, 0, 50 }, spark.at);
    try std.testing.expectEqual(Vector{ 0, 0, 200 }, spark.velocity);
}

test Debris {
    var debris: Debris = .{};
    try std.testing.expectEqual(&debris.pieces[0], debris.piece(0));
    try std.testing.expectEqual(&debris.pieces[9], debris.piece(0.3));
    try std.testing.expectEqual(&debris.pieces[1], debris.piece(0.5));
    try std.testing.expectEqual(&debris.pieces[8], debris.piece(0.99));
    try std.testing.expectEqual(&debris.pieces[9], debris.piece(1));

    // A model with more levels than a bit keeps gives it its finest.
    var mesh: srapiext.Mesh = undefined;
    const many: [Levels.max + 2]srapiext.Level = @splat(.{ .mesh = &mesh, .until = 2 });
    const kept: Levels = .of(&many, Debris.stretch);
    try std.testing.expectEqual(Levels.max, kept.slice().len);
    try std.testing.expectEqual(3, kept.slice()[0].until);
}

test "a blast's bits" {
    const gpa = std.testing.allocator;
    const mesh = try @import("../surrender/surrenderlib/srmesh.zig").testing.square(gpa);
    defer mesh.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var explosions: Explosions = try .init(std.testing.allocator, testing.images());
    defer explosions.deinit();
    explosions.debris = testing.debris(&mesh);
    var world = mission.world();
    world.explosions = &explosions;
    const ship = try mission.add(.sabre, @splat(0));
    const pod = try mission.add(.escape_pod, @splat(0));

    // A ship throws 25, an escape pod 5, and a burst 25.
    blast(world, ship);
    try std.testing.expectEqual(blast_bits.count, testing.flying(&explosions));
    blast(world, pod);
    try std.testing.expectEqual(blast_bits.count + small_blast_bits.count, testing.flying(&explosions));
    burst(world, ship);
    try std.testing.expectEqual(2 * blast_bits.count + small_blast_bits.count, testing.flying(&explosions));
}

test "a blast's shockwave" {
    const gpa = std.testing.allocator;
    var built: shockwave.testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var watching: @import("camera.zig").Camera = .{};
    var world = mission.world();
    world.camera = &watching;
    world.shockwaves = &built.waves;
    const ship = try mission.add(.sabre, @splat(0));
    mission.objects.slots[ship].object.velocity = .{ .x = 0, .y = 0, .z = 8 };

    // Now and then a blast sets one off, of one of its three looks, ten times the ship's radius
    // across, drifting with the flame.
    var blasts: usize = 0;
    while (built.waves.waves[0] == null and blasts < 100) : (blasts += 1) blast(world, ship);
    const wave = built.waves.waves[0].?;
    try std.testing.expect(std.mem.indexOfScalar(shockwave.Kind, &shockwave.Kind.blasts, wave.kind) != null);
    try std.testing.expectEqual(mission.objects.slots[ship].object.radius * blast_shockwave_size, wave.size);
    try std.testing.expect(wave.life >= blast_shockwave_life and wave.life < blast_shockwave_life + blast_shockwave_life_range);
    try std.testing.expect(wave.velocity[2] >= 2 and wave.velocity[2] <= 4);
}

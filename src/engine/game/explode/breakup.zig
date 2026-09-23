//! The break-up in `C:\lancer\game\explode.cpp`: a ship's parts cut into pieces along random planes
//! (`model_slice`), which fly apart tumbling and each end in a fireball
//! (`explode_break_up`, and the debris table `explosions_update` runs).

const std = @import("std");
const Allocator = std.mem.Allocator;

const shp = @import("../../../formats/shp.zig");
const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const create = @import("../create.zig");
const explode = @import("../explode.zig");
const gameobj = @import("../gameobj.zig");
const libcmt = @import("../../libcmt.zig");
const objects = @import("../objects.zig");
const particles = @import("../particles.zig");
const table = @import("../table.zig");
const xtrabits = @import("../xtrabits.zig");

/// Which blast breaks the ship up, which sets how its pieces fly: a ship's blast
/// (`explode.blast`) or a burst (`explode.burst`). The game passes 0 for the one and a pointer for
/// the other.
pub const Kind = enum {
    blast,
    burst,

    /// The smoke a first cut's piece trails.
    fn trail(kind: Kind) *const particles.Template {
        return switch (kind) {
            .blast => &blast_trail,
            .burst => &burst_trail,
        };
    }

    /// How fast a second cut's piece turns, times how many cuts made it (`0x004DC474`,
    /// `0x004DC518`).
    fn tumble(kind: Kind) f32 {
        return switch (kind) {
            .blast => 0.05,
            .burst => 0.01,
        };
    }

    /// How long a second cut's piece flies at least, before up to `flight_range` more.
    fn flight(kind: Kind) i32 {
        return switch (kind) {
            .blast => 0,
            .burst => 300,
        };
    }
};

/// A blast's pieces' smoke (`0x00553358`): a second of orange that fades to nothing as it grows.
pub const blast_trail: particles.Template = .{
    .life = 100,
    .life_spread = 10,
    .rate = .through(30, 20, 10),
    .size = .through(25, 50, 75),
    .colour = .{ .through(1, 0.25, 0), .through(0.5, 0.25, 0), .through(0, 0.25, 0) },
};

/// A burst's pieces' smoke (`0x00553354`): five seconds of pale blue that fades as it grows.
pub const burst_trail: particles.Template = .{
    .life = 500,
    .life_spread = 30,
    .rate = .through(60, 40, 20),
    .size = .through(25, 50, 75),
    .colour = .{ .through(0.75, 0.05, 0), .through(0.6, 0, 0), .through(1, 0.4, 0) },
};

/// A piece of a part (`model_slice`'s): a mesh of its own, centred on itself, shown by an object of
/// its own.
pub const Piece = struct {
    mesh: srapiext.Mesh,
    object: srapiext.MeshObject,
    level: [1]srapiext.Level = undefined,

    pub fn deinit(piece: *Piece, gpa: Allocator) void {
        piece.mesh.deinit(gpa);
    }

    /// Its object, pointed at its own mesh, which moving the piece leaves behind.
    fn shown(piece: *Piece) *srapiext.MeshObject {
        piece.level = .{.{ .mesh = &piece.mesh, .until = std.math.inf(f32) }};
        piece.object.levels = &piece.level;
        return &piece.object;
    }

    fn place(piece: *const Piece) math.Place {
        return .{ .position = piece.object.position, .orientation = piece.object.orientation };
    }
};

/// What `cut` cuts: a mesh, where it stands in the world, and how its pieces are drawn.
pub const Source = struct {
    mesh: *const srapiext.Mesh,
    place: math.Place,
    flags: srapiext.ObjectFlags,
    light_mask: u32,
};

/// How many planes a cut makes, and so up to how many pieces: two to the power of it.
pub const Cuts = enum(u2) {
    one = 1,
    two = 2,

    fn pieces(cuts: Cuts) usize {
        return @as(usize, 1) << @intFromEnum(cuts);
    }
};

pub const max_pieces = Cuts.two.pieces();

/// `model_slice` (`0x0046BF20`): cuts `source`'s mesh along `cuts` random planes through `frame`'s
/// origin. Each polygon goes to the side of each plane that the sum of its corners, in `frame`,
/// lies on, and each side that gets any becomes a piece: its polygons, a corner of its own for
/// each of theirs, in `frame`'s orientation and centred on the corners' mean, which is where the
/// piece stands. It is drawn as the source is.
///
/// **Improvement:** the game makes each polygon a plain one, which turns a strip's odd members
/// inside out, and gives it the source's plane unturned with its distance left at 0, so the
/// piece's faces show and hide by the wrong planes; and it leaves the baked colours and the second
/// pass's texture coordinates behind. The port keeps each polygon's kind, works the planes out
/// from the piece's own corners, and carries the colours and coordinates, so a piece looks as its
/// part did. It also leaves out the polygons in no surface, which draw nothing.
pub fn cut(gpa: Allocator, frame: math.Place, source: Source, cuts: Cuts, random: *libcmt.Rand) Allocator.Error![max_pieces]?Piece {
    var planes: [@intFromEnum(Cuts.two)]Vector = undefined;
    for (planes[0..@intFromEnum(cuts)]) |*plane| plane.* = random.centredVector(@splat(1));

    // The source's frame, as the frame sees it.
    const into = math.transpose(frame.orientation);
    const turn = math.product(into, source.place.orientation);
    const offset = math.transform(into, source.place.position - frame.position);

    const mesh = source.mesh;
    const sides = try gpa.alloc(u2, mesh.polygons.len);
    defer gpa.free(sides);
    for (mesh.polygons, sides) |polygon, *side| {
        var sum: Vector = @splat(0);
        for (mesh.indices[polygon.first..][0..polygon.count]) |index| sum += mesh.positions[index];
        const point = math.transform(turn, sum) + offset;
        side.* = 0;
        for (planes[0..@intFromEnum(cuts)], 0..) |plane, bit| {
            if (math.dot(point, plane) > 0) side.* |= @as(u2, 1) << @intCast(bit);
        }
    }

    var pieces: [max_pieces]?Piece = @splat(null);
    errdefer for (&pieces) |*maybe| if (maybe.*) |*piece| piece.deinit(gpa);
    for (pieces[0..cuts.pieces()], 0..) |*piece, side| {
        const made = try pieceOf(gpa, mesh, sides, @intCast(side), turn, offset) orelse continue;
        piece.* = .{
            .mesh = made.mesh,
            .object = .{
                .flags = source.flags,
                .light_mask = source.light_mask,
                .position = frame.position + math.transform(frame.orientation, made.centre),
                .orientation = frame.orientation,
                .radius = made.mesh.radius,
                .levels = &.{},
            },
        };
    }
    return pieces;
}

/// A side's mesh, and the centre it was moved back from, in the frame.
const Side = struct {
    mesh: srapiext.Mesh,
    centre: Vector,
};

/// The mesh of the polygons of `mesh` that lie on `side`, turned by `turn` and moved by `offset`.
/// Null where none lie there, or where they have more corners than a mesh holds.
fn pieceOf(gpa: Allocator, mesh: *const srapiext.Mesh, sides: []const u2, side: u2, turn: math.Matrix, offset: Vector) Allocator.Error!?Side {
    var polygon_count: usize = 0;
    var corner_count: usize = 0;
    var walk: Walk = .{ .mesh = mesh, .sides = sides, .side = side };
    while (walk.next()) |at| {
        polygon_count += 1;
        corner_count += mesh.polygons[at.polygon].count;
    }
    if (polygon_count == 0 or corner_count == 0 or corner_count > std.math.maxInt(u16)) return null;

    var built: srapiext.Mesh = try .create(gpa, .{ .polygons = polygon_count, .vertices = corner_count, .indices = corner_count, .surfaces = mesh.surfaces.len });
    errdefer built.deinit(gpa);
    const shared = sharesCoordinates(mesh);
    if (mesh.uv[0] != null) _ = try built.addCoordinates(gpa);
    if (mesh.uv[1] != null) built.uv[1] = if (shared) built.uv[0] else try gpa.alloc([2]f32, corner_count);
    const passes: usize = if (shared) 1 else 2;
    if (mesh.face_flags != null) built.face_flags = try gpa.alloc(shp.Face.Flags, polygon_count);
    if (mesh.baked != null) built.baked = try gpa.alloc([4]f32, corner_count);
    for (built.surfaces, mesh.surfaces) |*surface, from| surface.* = .{ .material = from.material, .textures = from.textures };

    var corner: u16 = 0;
    var into: usize = 0;
    var centre: Vector = @splat(0);
    walk = .{ .mesh = mesh, .sides = sides, .side = side };
    while (walk.next()) |at| : (into += 1) {
        const polygon = mesh.polygons[at.polygon];
        built.surfaces[at.surface].polygons += 1;
        built.polygons[into] = .{ .kind = polygon.kind, .continues = 0, .first = corner, .count = polygon.count };
        built.biases[into] = mesh.biases[at.polygon];
        if (mesh.face_flags) |flags| built.face_flags.?[into] = flags[at.polygon];
        for (polygon.first..polygon.first + polygon.count) |from| {
            const vertex = mesh.indices[from];
            built.indices[corner] = corner;
            for (built.uv[0..passes], mesh.uv[0..passes]) |made, source| {
                if (made) |uv| uv[corner] = source.?[from];
            }
            if (mesh.baked) |baked| built.baked.?[corner] = baked[vertex];
            built.positions[corner] = math.transform(turn, mesh.positions[vertex]) + offset;
            built.normals[corner] = math.transform(turn, mesh.normals[vertex]);
            centre += built.positions[corner];
            corner += 1;
        }
    }
    centre /= @splat(@floatFromInt(corner));
    for (built.positions) |*position| position.* -= centre;
    srapi.calcPolyNormals(&built);
    srapi.findBoundingBox(&built);
    return .{ .mesh = built, .centre = centre };
}

/// Whether a mesh's second texture coordinates are its first, as a light-mapped part's are.
fn sharesCoordinates(mesh: *const srapiext.Mesh) bool {
    const first = mesh.uv[0] orelse return false;
    const second = mesh.uv[1] orelse return false;
    return first.ptr == second.ptr;
}

/// The polygons of a mesh on one side, surface by surface.
const Walk = struct {
    mesh: *const srapiext.Mesh,
    sides: []const u2,
    side: u2,
    surface: usize = 0,
    in_surface: usize = 0,
    polygon: usize = 0,

    const At = struct { surface: usize, polygon: usize };

    fn next(walk: *Walk) ?At {
        while (walk.surface < walk.mesh.surfaces.len) {
            if (walk.in_surface == walk.mesh.surfaces[walk.surface].polygons) {
                walk.surface += 1;
                walk.in_surface = 0;
                continue;
            }
            const at: At = .{ .surface = walk.surface, .polygon = walk.polygon };
            walk.in_surface += 1;
            walk.polygon += 1;
            if (at.polygon < walk.sides.len and walk.sides[at.polygon] == walk.side) return at;
        }
        return null;
    }
};

/// A piece flying (0x40 bytes): until its time is up it tumbles away, trailing smoke where it has
/// any; then it goes up in a fireball of the sheet's, 1.2 times its radius, and is gone 12 ticks
/// later.
pub const Flight = struct {
    /// When it goes up, and then when it is gone (`+0x00`), and which of the two it waits for
    /// (`+0x04`).
    until: i32,
    stage: Stage = .flying,
    piece: Piece,
    /// Where it is and how it is turned at the frame's tick, which `Pieces.add` takes from the
    /// piece; its object is drawn from here (`Pieces.draw`).
    place: math.Place = .{},
    /// How far it moves a tick (`+0x0C`), and the angles it turns by a tick, which the game keeps
    /// as the turn they make (`+0x18`).
    velocity: Vector,
    tumble: Vector,
    /// The smoke it trails (`+0x3C`), streamed from it.
    trail: ?particles.Emitter = null,

    pub const Stage = enum { flying, gone_up };

    /// The fireball it goes up in: the sheet's, over `blow_life` ticks, `blow_size` times its
    /// radius (`0x004DC7EC`), and the ticks it is shown after.
    const blow_size: f32 = 1.2;
    const blow_life = 60;
    const lingers = 12;
};

/// The pieces flying (`0x0055AE88`): `max` of them, the next taking the place of the oldest
/// (`debris_add`, `0x00472700`; `0x0055AD1C`).
pub const Pieces = struct {
    gpa: Allocator,
    flights: *Flights,

    pub const max = 500;
    const Flights = table.Ring(Flight, max);

    pub fn create(gpa: Allocator) Allocator.Error!Pieces {
        const flights = try gpa.create(Flights);
        flights.* = .{};
        return .{ .gpa = gpa, .flights = flights };
    }

    pub fn deinit(pieces: *Pieces) void {
        pieces.reset();
        pieces.gpa.destroy(pieces.flights);
    }

    /// As a mission starts again: none flying.
    pub fn reset(pieces: *Pieces) void {
        for (&pieces.flights.slots) |*slot| pieces.drop(slot);
        pieces.flights.next = 0;
    }

    /// `0x00472740`: lets a flight go, its piece and its smoke with it.
    fn drop(pieces: *Pieces, slot: *?Flight) void {
        if (slot.*) |*flight| flight.piece.deinit(pieces.gpa);
        slot.* = null;
    }

    /// `debris_add`: sends `flight` off in the place of the oldest.
    fn add(pieces: *Pieces, flight: Flight) void {
        const slot = pieces.flights.take(max);
        pieces.drop(slot);
        slot.* = flight;
        slot.*.?.place = flight.piece.place();
    }

    /// `explosions_update`'s pass over them: each moves on by its velocity times the frame's
    /// ticks, turns by its spin once a tick, and trails its smoke; one whose time is up goes up in
    /// its fireball, and one gone up is let go once its last ticks are over.
    pub fn frame(pieces: *Pieces, world: gameobj.World) void {
        const clock = world.clock;
        for (&pieces.flights.slots) |*slot| {
            const flight = &(slot.* orelse continue);
            if (flight.until < clock.frame_start) switch (flight.stage) {
                .flying => {
                    explode.fireballAt(world, flight.place.position, .{
                        .kind = .sheet,
                        .size = flight.piece.mesh.radius * Flight.blow_size,
                        .life = Flight.blow_life,
                        .velocity = flight.velocity,
                    });
                    flight.trail = null;
                    flight.stage = .gone_up;
                    flight.until = clock.frame_start + Flight.lingers;
                },
                .gone_up => {
                    pieces.drop(slot);
                    continue;
                },
            };
            if (flight.trail) |*trail| stream(world, trail, flight.place);
            const place = &flight.place;
            place.position += flight.velocity * @as(Vector, @splat(@floatFromInt(clock.frame_duration)));
            const spin = math.fromAngleVector(flight.tumble);
            for (0..@intCast(@max(clock.frame_duration, 0))) |_| place.orientation = math.product(place.orientation, spin);
        }
    }

    /// Each piece flying, into the world's layer, `ahead` of a tick along from where it was and
    /// how it was turned at the frame's tick.
    ///
    /// **Improvement:** the game draws it as the tick left it (`particles.Pool.draw`).
    pub fn draw(pieces: *Pieces, gpa: Allocator, scene: *srcore.Scene, ahead: f32) Allocator.Error!void {
        for (&pieces.flights.slots) |*slot| {
            const flight = &(slot.* orelse continue);
            const object = flight.piece.shown();
            object.position = flight.place.position + flight.velocity * @as(Vector, @splat(ahead));
            object.orientation = math.product(flight.place.orientation, math.fromAngleVector(flight.tumble * @as(Vector, @splat(ahead))));
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = object }, .world);
        }
    }
};

/// Streams `trail`'s smoke from `from`, as the camera sees it.
fn stream(world: gameobj.World, trail: *particles.Emitter, from: math.Place) void {
    const pool = world.particles orelse return;
    const view = (world.camera orelse return).place;
    _ = pool.stream(trail, from, view, world.clock, world.random);
}

/// How the pieces of a first cut fly: every third, from the first, whole, away from the ship at
/// `first_speed` a step and up to `first_speed_range` more (`0x004DC820`, `0x004DC520`), turning up
/// to `first_tumble` either way about each axis a tick (`0x004DC610`), trailing smoke for its
/// flight, two to five seconds; the rest cut again, in two for the second and four for the third,
/// each flying away at `second_speed` a step times the cuts (`0x004DC72C`). Each carries on with the
/// ship's velocity, and moves at a quarter of that a tick.
const first_speed: f32 = 14;
const first_speed_range: f32 = 10;
const first_tumble: f32 = 0.04;
const first_flight = 200;
const flight_range = 300;
const second_speed: f32 = 20;
const step_share: f32 = 0.25;

/// The smoke a whole piece trails: out behind it along its own Z axis, straying a little, for up
/// to ten seconds.
fn trailFrom(kind: Kind, born: i32) particles.Emitter {
    return .{
        .life = 1000,
        .born = born,
        .direction = .{ 0, 0, 1 },
        .spread = .{ 0.25, 0.25, 0 },
        .speed = 5,
        .speed_range = 2,
        .template = kind.trail(),
    };
}

/// `explode_break_up` (`0x0046C550`): cuts each of the ship's parts in four and sends the pieces
/// flying, the parts in the order the model's hierarchy holds them, each before those hanging from
/// it. Its pieces show as the part does, lit as the debris setting says.
pub fn breakUp(world: gameobj.World, index: u16, kind: Kind) void {
    const explosions = world.explosions orelse return;
    const slot = &world.objects.slots[index];
    const model = &(slot.model orelse return);
    breakUpFrom(explosions, world, slot, model, null, kind);
}

fn breakUpFrom(explosions: *explode.Explosions, world: gameobj.World, slot: *const create.Slot, model: *const objects.Model, parent: ?usize, kind: Kind) void {
    for (model.parts, 0..) |*part, at| {
        if (!std.meta.eql(part.parent, parent)) continue;
        breakUpPart(explosions, world, slot, part, kind);
        breakUpFrom(explosions, world, slot, model, at, kind);
    }
}

fn breakUpPart(explosions: *explode.Explosions, world: gameobj.World, slot: *const create.Slot, part: *const objects.Model.Part, kind: Kind) void {
    const shown = part.object.levels;
    if (shown.len == 0) return;
    const gpa = explosions.pieces.gpa;
    const random = world.random;
    const now = world.clock.frame_start;
    const centre = slot.drawn.position;
    const carried = gameobj.vector(slot.object.velocity);
    const source: Source = .{
        .mesh = shown[@min(part.object.level, shown.len - 1)].mesh,
        .place = .{ .position = part.object.position, .orientation = part.object.orientation },
        .flags = part.object.flags,
        .light_mask = explosions.settings.debris_lights.mask(part.object.light_mask),
    };
    var pieces = cut(gpa, slot.drawn, source, .two, random) catch return;
    for (&pieces, 0..) |*maybe, at| {
        var piece = maybe.* orelse continue;
        const again: ?Cuts = switch (at % 3) {
            0 => null,
            1 => .one,
            else => .two,
        };
        const cuts = again orelse {
            const speed = random.fraction() * first_speed_range + first_speed;
            const tumble = random.centredVector(@splat(first_tumble));
            explosions.pieces.add(.{
                .until = @as(i32, random.rand() % flight_range) + first_flight + now,
                .velocity = away(piece.object.position, centre, speed, carried),
                .tumble = tumble,
                .trail = trailFrom(kind, now),
                .piece = piece,
            });
            continue;
        };
        defer piece.deinit(gpa);
        var smaller = cut(gpa, piece.place(), .{ .mesh = &piece.mesh, .place = piece.place(), .flags = source.flags, .light_mask = source.light_mask }, cuts, random) catch continue;
        const count: f32 = @floatFromInt(@intFromEnum(cuts));
        for (&smaller) |*small| {
            const flying = small.* orelse continue;
            const tumble = random.centredVector(@splat(count * kind.tumble()));
            explosions.pieces.add(.{
                .until = @as(i32, random.rand() % flight_range) + kind.flight() + now,
                .velocity = away(flying.object.position, centre, count * second_speed, carried),
                .tumble = tumble,
                .piece = flying,
            });
        }
    }
}

/// A piece's velocity a tick: away from the ship's centre at `speed` a step, with what it carries
/// of the ship's velocity.
fn away(at: Vector, centre: Vector, speed: f32, carried: Vector) Vector {
    return (math.normalize(at - centre) * @as(Vector, @splat(speed)) + carried) * @as(Vector, @splat(step_share));
}

const testing = struct {
    /// Eight triangles about the origin in the XY plane, a hundred out, each with corners of its
    /// own, every other one an odd strip member, with texture coordinates and baked colours.
    fn star(gpa: Allocator) !srapiext.Mesh {
        const count = 8;
        var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = count, .vertices = count * 3, .indices = count * 3 });
        errdefer mesh.deinit(gpa);
        const uv = try mesh.addCoordinates(gpa);
        mesh.baked = try gpa.alloc([4]f32, count * 3);
        mesh.surfaces[0] = .{ .polygons = count, .material = std.mem.zeroes(srapiext.Material) };
        mesh.numberPolygons(3);
        for (0..count) |n| {
            const angle = @as(f32, @floatFromInt(n)) * std.math.tau / count;
            const out: Vector = .{ @cos(angle) * 100, @sin(angle) * 100, 0 };
            const side: Vector = .{ -@sin(angle) * 20, @cos(angle) * 20, 0 };
            mesh.positions[n * 3 ..][0..3].* = .{ out * @as(Vector, @splat(0.5)), out + side, out - side };
            if (n % 2 == 1) mesh.polygons[n].kind = .strip_odd;
        }
        for (mesh.indices, uv, mesh.baked.?, mesh.normals, 0..) |*index, *corner, *colour, *normal, at| {
            index.* = @intCast(at);
            corner.* = .{ @floatFromInt(at), 0 };
            colour.* = @splat(@floatFromInt(at));
            normal.* = .{ 0, 0, 1 };
        }
        srapi.calcPolyNormals(&mesh);
        srapi.findBoundingBox(&mesh);
        return mesh;
    }
};

test cut {
    const gpa = std.testing.allocator;
    var mesh = try testing.star(gpa);
    defer mesh.deinit(gpa);
    var random: libcmt.Rand = .{};
    const source: Source = .{ .mesh = &mesh, .place = .{ .position = .{ 10, 0, 0 } }, .flags = .{ .lit = true }, .light_mask = 3 };
    var pieces = try cut(gpa, .{}, source, .two, &random);
    defer for (&pieces) |*maybe| if (maybe.*) |*piece| piece.deinit(gpa);

    // Every polygon lands in one piece, each piece centred on itself and standing where its
    // corners were, drawn as the source is, its strips kept and its planes its own.
    var polygons: usize = 0;
    for (&pieces) |*maybe| {
        const piece = &(maybe.* orelse continue);
        polygons += piece.mesh.polygons.len;
        try std.testing.expectEqual(source.flags, piece.object.flags);
        try std.testing.expectEqual(source.light_mask, piece.object.light_mask);
        var sum: Vector = @splat(0);
        for (piece.mesh.positions) |position| sum += position;
        try std.testing.expect(math.length(sum) < 1e-2);
        for (piece.mesh.polygons, piece.mesh.planes) |polygon, plane| {
            const corners = piece.mesh.indices[polygon.first..][0..3];
            const first = corners[0];
            try std.testing.expectApproxEqAbs(plane.distance, math.dot(plane.normal, piece.mesh.positions[first]), 1e-2);
            // The corner's colour names the source corner it came from.
            const from: usize = @intFromFloat(piece.mesh.baked.?[first][0]);
            const world = piece.object.position + math.transform(piece.object.orientation, piece.mesh.positions[first]);
            try std.testing.expect(math.distance(mesh.positions[from] + source.place.position, world) < 1e-2);
            try std.testing.expectEqual(mesh.polygons[from / 3].kind, polygon.kind);
            try std.testing.expectEqual(@as(f32, @floatFromInt(from)), piece.mesh.uv[0].?[first][0]);
        }
    }
    try std.testing.expectEqual(mesh.polygons.len, polygons);
}

test Pieces {
    const gpa = std.testing.allocator;
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const clock = &stage.mission.clock;
    clock.frame_duration = 2;
    const pieces = &stage.explosions.pieces;
    var mesh = try testing.star(gpa);
    defer mesh.deinit(gpa);
    var random: libcmt.Rand = .{};
    var cuts = try cut(gpa, .{}, .{ .mesh = &mesh, .place = .{}, .flags = .{}, .light_mask = 0 }, .one, &random);
    defer for (cuts[1..]) |*maybe| if (maybe.*) |*piece| piece.deinit(gpa);

    // A piece flies on by its velocity each tick, and turns by its spin each tick.
    const from = cuts[0].?.object.position;
    pieces.add(.{ .until = 10, .piece = cuts[0].?, .velocity = .{ 1, 0, 0 }, .tumble = .{ 0, 0, 0.1 } });
    cuts[0] = null;
    const flight = &pieces.flights.slots[0].?;
    pieces.frame(stage.world());
    try std.testing.expectEqual(from + Vector{ 2, 0, 0 }, flight.place.position);
    try std.testing.expect(math.distance(math.angles(flight.place.orientation), .{ 0, 0, 0.2 }) < 1e-5);

    // Drawn half a tick on, it has moved and turned half a tick more.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try pieces.draw(gpa, &scene, 0.5);
    try std.testing.expectEqual(from + Vector{ 2.5, 0, 0 }, flight.piece.object.position);
    try std.testing.expect(math.distance(math.angles(flight.piece.object.orientation), .{ 0, 0, 0.25 }) < 1e-5);

    // Its time up, it goes up in a fireball of the sheet's, and is gone a little later.
    clock.frame_start = 11;
    pieces.frame(stage.world());
    try std.testing.expectEqual(Flight.Stage.gone_up, flight.stage);
    try std.testing.expect(!stage.explosions.fireballs[0].?.look.bang);
    clock.frame_start = 11 + Flight.lingers + 1;
    pieces.frame(stage.world());
    try std.testing.expectEqual(null, pieces.flights.slots[0]);
}

test breakUp {
    const gpa = std.testing.allocator;
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    const mission = &stage.mission;
    const index = try create.createObject(mission.objects, &mission.tables, model.types(), null, .predator, @splat(0), &mission.random);
    const slot = &mission.objects.slots[index];
    slot.object.velocity = .{ .x = 0, .y = 0, .z = 8 };

    // Its part is cut in pieces that fly off, each at a quarter of a step's worth a tick, lit as
    // the part is; a burst's fly longer.
    breakUp(stage.world(), index, .burst);
    var flying: usize = 0;
    for (stage.explosions.pieces.flights.slots) |maybe| {
        const flight = maybe orelse continue;
        flying += 1;
        try std.testing.expectEqual(slot.model.?.parts[0].object.light_mask, flight.piece.object.light_mask);
        // A whole piece trails smoke; a piece cut again flies at least three seconds.
        const least: i32 = if (flight.trail != null) first_flight else Kind.burst.flight();
        try std.testing.expect(flight.until >= least and flight.until < least + flight_range);
        if (flight.trail) |trail| try std.testing.expectEqual(&burst_trail, trail.template);
    }
    try std.testing.expect(flying > 0);

    // With the original's lights, every light reaches them.
    stage.explosions.pieces.reset();
    stage.explosions.settings.debris_lights = .every_light;
    breakUp(stage.world(), index, .blast);
    for (stage.explosions.pieces.flights.slots) |maybe| {
        const flight = maybe orelse continue;
        try std.testing.expectEqual(0, flight.piece.object.light_mask);
    }
}

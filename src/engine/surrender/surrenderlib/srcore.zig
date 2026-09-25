//! `C:\lancer\surrender\surrenderlib\srCore.cpp`: drawing a frame. `sr_render` (`0x004C78A0`) runs
//! `sr_draw_layers` (`0x004C7960`): the driver begins the scene; each layer's objects go through
//! the pipeline for their kind and to the driver, which draws what is opaque and puts the blended
//! aside; `depth_sort` (`0x004C7B30`) sorts what was put aside, farthest first, and the driver
//! draws it; the driver ends the scene.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../math.zig");
const srapi = @import("srapi.zig");
const srapiext = @import("srapiext.zig");
const srbmo = @import("srbmo.zig");
const srlight = @import("srlight.zig");
const srmesh = @import("srmesh.zig");
const srshadow = @import("srshadow.zig");
const srstars = @import("srstars.zig");

/// The scene's layers, drawn in order, each with what it puts aside last.
pub const Layer = enum(u2) {
    background = 0,
    world = 1,
    overlay = 2,
};

/// A scene object, as the layers list them.
pub const Object = union(enum) {
    mesh: *srapiext.MeshObject,
    sprites: *srapiext.SpriteSet,
    stars: *srstars.Field,
};

/// What the driver put aside to draw after the layer's objects, keyed by depth: a mesh's polygon, a
/// sprite, or a whole star field.
pub const Deferred = struct {
    /// Farther is greater; drawn from the greatest down.
    key: u32,
    surface: *const srapiext.Surface,
    item: Item,

    pub const Item = union(enum) {
        polygon: struct { drawn: *const srmesh.Drawn, surface: u32, visible: srmesh.Visible },
        sprite: struct { drawn: *const srbmo.Drawn, index: u32 },
        stars: *const srstars.Drawn,
    };

    fn farther(_: void, a: Deferred, b: Deferred) bool {
        return a.key > b.key;
    }
};

/// A key from a depth, as the driver makes it: rounded to the nearest whole number, halves to
/// even, as the FPU rounds while `sr_render` draws; a negative depth is 0.
pub fn key(depth: f32) u32 {
    if (!(depth >= 0)) return 0;
    return std.math.lossyCast(u32, math.roundEven(depth));
}

/// Sorts what a layer put aside as `depth_sort` does: by key, greatest first, and otherwise in the
/// order of its list. The driver puts each thing at the head of the list, so the list runs from the
/// last put aside.
pub fn depthSort(deferred: []Deferred) void {
    std.mem.reverse(Deferred, deferred);
    std.mem.sort(Deferred, deferred, {}, Deferred.farther);
}

/// The scene, `sr`'s lists (`sr + 0x04` on): each layer's objects and the lights, in the order they
/// were added. `scene_add` puts each at the head of its list, so they are drawn from the last
/// added.
pub const Scene = struct {
    layers: std.EnumArray(Layer, std.ArrayList(Object)) = .initFill(.empty),
    lights: std.ArrayList(srlight.Light) = .empty,
    /// OpenReliant's: what casts shadows without being drawn, such as the ship the camera sits in
    /// (`srshadow`).
    casters: std.ArrayList(*srapiext.MeshObject) = .empty,
    /// The portals in the scene (list 4), which `render` puts in the camera's frame first.
    portals: std.ArrayList(*srapiext.Portal) = .empty,

    pub fn deinit(scene: *Scene, gpa: Allocator) void {
        for (&scene.layers.values) |*list| list.deinit(gpa);
        scene.lights.deinit(gpa);
        scene.casters.deinit(gpa);
        scene.portals.deinit(gpa);
    }

    /// Empties the lists, as `mission_frame` does each frame.
    pub fn clear(scene: *Scene) void {
        for (&scene.layers.values) |*list| list.clearRetainingCapacity();
        scene.lights.clearRetainingCapacity();
        scene.casters.clearRetainingCapacity();
        scene.portals.clearRetainingCapacity();
    }
};

/// A Surrender driver: the functions `SR_driver_init` puts in `sr`'s table.
pub const Driver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// `begin_scene`: clears, and sets the depth scale for the frame.
        begin: *const fn (*anyopaque, *srapi.Context) void,
        /// OpenReliant's: the frame's lights, for a device that lights each pixel. The driver marks
        /// the lights the device adds to each pixel (`srlight.Light.per_pixel`), and sets
        /// `srapi.Context.pixel_lighting` if there are any, and `shadows` for a device that draws
        /// them.
        lights: *const fn (*anyopaque, []srlight.Light) Allocator.Error!void,
        /// OpenReliant's: the frame's shadows, after the lights, for a device that draws them.
        shadows: ?*const fn (*anyopaque, *const srshadow.Frame) void = null,
        /// Draws what is opaque now and puts the rest in `blended`.
        mesh: *const fn (*anyopaque, *const srmesh.Drawn, Layer, *Blended) Allocator.Error!void,
        sprites: *const fn (*anyopaque, *const srbmo.Drawn, Layer, *Blended) Allocator.Error!void,
        stars: *const fn (*anyopaque, *const srstars.Drawn, Layer, *Blended) Allocator.Error!void,
        /// Marks where the scene ends and what is drawn over it begins, so that a driver adding
        /// anything to the frame of its own leaves out what follows.
        overlay: *const fn (*anyopaque) void,
        /// `flush_blended`: draws a layer's sorted blended things, every first pass, then the
        /// second passes.
        flush: *const fn (*anyopaque, []const Deferred, Layer) void,
        end: *const fn (*anyopaque) void,
    };
};

/// A layer's list of what the driver put aside.
pub const Blended = struct {
    arena: Allocator,
    list: std.ArrayList(Deferred) = .empty,

    pub fn add(blended: *Blended, deferred: Deferred) Allocator.Error!void {
        try blended.list.append(blended.arena, deferred);
    }
};

/// What the engine draws over the finished scene, which Surrender reaches through `sr + 0x88`:
/// `mission_run` puts `hud_draw` there and the renderer calls it after the layers, before the scene
/// ends. Nothing calls it outright.
pub const Overlay = struct {
    context: *anyopaque,
    draw: *const fn (context: *anyopaque) Allocator.Error!void,
};

/// Draws a frame (`sr_render`, `sr_draw_layers`): puts the scene's portals in the camera's frame
/// (`portal_transform`), then draws the layers, the overlay after them. Everything a frame needs is
/// taken from `arena`, which must last until the driver is done with the frame.
pub fn render(arena: Allocator, context: *srapi.Context, scene: *Scene, driver: Driver, overlay: ?Overlay) Allocator.Error!void {
    driver.vtable.begin(driver.ptr, context);
    for (scene.portals.items) |portal| portal.transform(context.camera);
    // `mesh_light` walks the lights' list, which runs from the last added.
    const lights = try arena.dupe(srlight.Light, scene.lights.items);
    std.mem.reverse(srlight.Light, lights);
    try driver.vtable.lights(driver.ptr, lights);
    try castShadows(arena, context.*, scene, lights, driver);

    var budget: srmesh.Budget = .{ .limit = context.budget };
    for (std.enums.values(Layer)) |layer| {
        var blended: Blended = .{ .arena = arena };
        const objects = scene.layers.getPtr(layer).items;
        var i = objects.len;
        while (i > 0) {
            i -= 1;
            switch (objects[i]) {
                .mesh => |mesh| {
                    if (mesh.flags.hidden or mesh.scale == 0) continue;
                    const drawn = try srmesh.pipe(arena, context, mesh, lights, &budget) orelse continue;
                    const stored = try arena.create(srmesh.Drawn);
                    stored.* = drawn;
                    try driver.vtable.mesh(driver.ptr, stored, layer, &blended);
                },
                .sprites => |sprites| {
                    if (sprites.flags.hidden or sprites.scale == 0) continue;
                    const drawn = try srbmo.project(arena, context, sprites) orelse continue;
                    try driver.vtable.sprites(driver.ptr, drawn, layer, &blended);
                },
                .stars => |field| {
                    if (field.flags.hidden) continue;
                    const drawn = try srstars.project(arena, context, field) orelse continue;
                    try driver.vtable.stars(driver.ptr, drawn, layer, &blended);
                },
            }
        }
        depthSort(blended.list.items);
        driver.vtable.flush(driver.ptr, blended.list.items, layer);
    }
    if (overlay) |over| {
        driver.vtable.overlay(driver.ptr);
        try over.draw(over.context);
    }
    driver.vtable.end(driver.ptr);
}

/// OpenReliant's: hands the driver the frame's shadows, where its device draws them (`srshadow`).
fn castShadows(arena: Allocator, context: srapi.Context, scene: *const Scene, lights: []const srlight.Light, driver: Driver) Allocator.Error!void {
    const take = driver.vtable.shadows orelse return;
    const settings = context.shadows orelse return;
    const world = scene.layers.get(.world).items;
    const overlay = scene.layers.get(.overlay).items;
    const frame = try srshadow.gather(arena, context, lights, world, overlay, scene.casters.items, settings) orelse return;
    const stored = try arena.create(srshadow.Frame);
    stored.* = frame;
    take(driver.ptr, stored);
}

test key {
    try std.testing.expectEqual(3, key(3.4));
    try std.testing.expectEqual(4, key(3.6));
    // Halves go to the even neighbour.
    try std.testing.expectEqual(2, key(2.5));
    try std.testing.expectEqual(4, key(3.5));
    try std.testing.expectEqual(0, key(-7));
}

test depthSort {
    var first: srapiext.Surface = .{ .material = std.mem.zeroes(srapiext.Material) };
    var second: srapiext.Surface = .{ .material = std.mem.zeroes(srapiext.Material) };
    const stars: srstars.Drawn = undefined;
    var list = [_]Deferred{
        .{ .key = 5, .surface = &first, .item = .{ .stars = &stars } },
        .{ .key = 9, .surface = &first, .item = .{ .stars = &stars } },
        .{ .key = 5, .surface = &second, .item = .{ .stars = &stars } },
    };
    depthSort(&list);
    try std.testing.expectEqual(9, list[0].key);
    // Equal keys come out last put aside first.
    try std.testing.expectEqual(&second, list[1].surface);
    try std.testing.expectEqual(&first, list[2].surface);
}
